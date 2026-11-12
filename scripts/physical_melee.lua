-- Physical melee for The Outer Worlds 2 (2026-09-26, contact mode 2026-09-28).
--
-- While the right hand holds an attachment flagged "Melee" in Attachment Configuration
-- (attachments_parameters.json "melee": true), a physical swing of the right controller is turned
-- into a short Right Trigger tap, which is the game's melee attack, and the player's first-person
-- melee montages are fast-forwarded through GlobalAnimRateScale on the arms mesh (Pawn.FPVMesh)
-- and the weapon mesh so the game's swing resolves close to the physical one.
--
-- HOW THE GAME DECIDES A HIT (live-traced 2026-09-28): the Hit montage carries an
-- AnimNotifyState_MeleeDamage window (0.12 s of animation) during which the game overlaps a capsule
-- taken from Weapon.PrimaryMode.DefaultMeleeCollision - for the baton: socket "MeleeCollisionSocket"
-- on the weapon mesh (bWeaponMesh = true), capsule radius 10, half-height 97.5, offset +51.5 along the
-- socket's Z (the shaft). In VR the FPV weapon mesh is on the controller and the game thread does
-- see it there (probe: FPV socket == controller position, pre-tick and post-stereo alike), so the
-- capsule is wherever the physical baton is - it never follows the arms montage.
-- NOTE: the window only produces a hit while Pawn.FPVMesh passes IsVisible(); hiding the arms through
-- bVisible / bHiddenInGame silently disables all melee damage (see weaponhook.lua, pawn_parameters).
--
-- CONTACT MODE (default, ported from the Silent Hill f profile): every tick while the weapon moves
-- faster than a small threshold, the game's own capsule (sampled along the shaft from the same socket
-- and dimensions the game uses) is tested against the collision capsules of nearby hostile
-- IndianaAiCharacters. The RT tap fires when the moving weapon ENTERS an enemy capsule (edge
-- triggered); while it stays inside, a re-fire needs the re-fire interval AND a fast weapon, so a
-- baton resting in the target does not machine-gun attacks. The old peak-of-swing mode is kept
-- behind a checkbox.
--
-- What the game does on a trigger tap with the baton (MeleeAnimEventEffect.CurrentAnimMontage):
--   MeleeAction 2  AS_P1P_ME1H_ShockBaton_PWR_Attack_Windup_Montage1   (power-attack windup, while RT is held)
--   MeleeAction 4  AS_P1P_ME1H_ShockBaton_R2L_Hit_Montage -> _R2L_End_Montage (light attack on release)
-- so the injected tap must be SHORT (a held RT becomes a power attack windup). The montages play on
-- Pawn.FPVMesh (ARK_P1P_AnimBP_C); the weapon mesh plays matching *_MESB_* montages. They are started
-- natively (no Montage_Play UFunction call), so the arms anim instance is polled with
-- GetCurrentActiveMontage().
--
-- Swing detection (peak mode) is the Stalker 2 knife_melee detector: hand delta minus head delta in
-- the HMD yaw frame, peak speed tracked, classified by dominant axis on the first decelerating sample.
-- Sampling happens once per tick in the post-stereo callback (valid controller poses, same as
-- two_handed.lua).

local uevrUtils   = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local attachments = require('libs/attachments')
local configui    = require('libs/configui')

local vr = uevr.params.vr

local TRIGGER_MAX_HOLD   = 0.25  -- s: hard cap on the injected RT hold (a long hold = power attack windup)
local RATE_MAX_SECONDS   = 1.0   -- s: unconditional restore deadline for the anim rate
local RATE_ARM_SECONDS   = 0.35  -- s: give up waiting for a montage to appear after the tap

local ENEMY_CLASS        = "Class /Script/Arkansas.IndianaAiCharacter"
local ENEMY_REFRESH_TICKS = 10   -- re-scan enemy positions every N ticks
local CAPSULE_SAMPLES    = 6     -- points tested along the game's melee capsule axis
local CONTACT_REARM_SECONDS = 0.12 -- s out of contact before the entry edge can fire again

-- ---------------------------------------------------------------------------------------------
-- Config UI
-- ---------------------------------------------------------------------------------------------
-- Section of the merged "Outer Worlds 2 VR" panel (see scripts/zz_ow2_vr_panel.lua)
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 3, label = "Physical Melee", layout = {
            { widgetType = "checkbox",     id = "pm_enabled",       label = "Enable physical melee (swing = attack)", initialValue = true },
            { widgetType = "slider_float", id = "pm_cooldown",      label = "Cooldown between swings (s)", initialValue = 0.35, range = {0.1, 1.5} },
            { widgetType = "slider_float", id = "pm_anim_rate",     label = "Melee anim rate scale", initialValue = 10.0, range = {1.0, 30.0} },
            { widgetType = "slider_int",   id = "pm_trigger_polls", label = "RT tap length (xinput polls)", initialValue = 3, range = {1, 6} },
            { widgetType = "checkbox",     id = "pm_log",           label = "Log to console", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", label = "Contact mode: the attack fires when the moving weapon enters an enemy" },
            -- was the checkbox pm_contact_mode (true = contact); zz_ow2_vr_panel.lua migrates a saved false to 2
            { widgetType = "combo",        id = "pm_melee_type",    label = "Melee type", initialValue = 1, selections = {"Contact mode", "Fire on swing peak"} },
            { widgetType = "slider_float", id = "pm_contact_speed", label = "Contact: min weapon speed (cm/s)", initialValue = 120.0, range = {0.0, 600.0} },
            { widgetType = "slider_float", id = "pm_contact_refire", label = "Contact: re-fire interval while still inside (s)", initialValue = 0.6, range = {0.2, 2.0} },
            { widgetType = "slider_float", id = "pm_hit_buffer",    label = "Contact: hit forgiveness (cm)", initialValue = 15.0, range = {0.0, 80.0} },
            { widgetType = "slider_float", id = "pm_lead",          label = "Contact: look-ahead (s, fires before the weapon arrives)", initialValue = 0.05, range = {0.0, 0.2} },
            { widgetType = "slider_float", id = "pm_window_rate",   label = "Anim rate while the damage window is open", initialValue = 1.5, range = {1.0, 30.0} },
            { widgetType = "slider_float", id = "pm_window_time",   label = "Damage window hold at that rate (s)", initialValue = 0.2, range = {0.0, 0.6} },
            { widgetType = "slider_float", id = "pm_enemy_range",   label = "Contact: enemy scan range (cm)", initialValue = 400.0, range = {150.0, 1500.0} },
            { widgetType = "checkbox",     id = "pm_hit_friendly",  label = "Contact: also trigger on non-hostile characters", initialValue = false },
            { widgetType = "checkbox",     id = "pm_debug_capsule", label = "Debug: show the game's melee capsule (spheres along the shaft, bigger while touching)", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", label = "Peak mode (old)" },
            { widgetType = "slider_float", id = "pm_min_speed",     label = "Peak: min swing speed (cm/s)", initialValue = 180.0, range = {50.0, 600.0} },
            { widgetType = "checkbox",     id = "pm_accept_stab",   label = "Peak: also accept forward stab", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", id = "pm_weapon_label",  label = "Weapon: none" },
            { widgetType = "text", id = "pm_swing_label",   label = "Last swing: -" },
            { widgetType = "text", id = "pm_rate_label",    label = "Anim rate: 1.0" },
            { widgetType = "text", id = "pm_contact_label", label = "Contact: -" },
            { widgetType = "text", id = "pm_timing_label",  label = "Timing: -" },
}})

local function cfgNum(id, default)
    local v = configui.getValue(id)
    if type(v) ~= "number" then return default end
    return v
end

local function log(text)
    if configui.getValue("pm_log") == true then
        print("[physical_melee] " .. tostring(text))
    end
end

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

-- ---------------------------------------------------------------------------------------------
-- Melee attachment tracking
-- ---------------------------------------------------------------------------------------------
local meleeHeld      = false
local weaponMesh     = nil
local currentWeaponID = nil

local function updateMeleeState()
    local mesh = attachments.getCurrentGrippedAttachment(Handed.Right)
    local held = alive(mesh) and attachments.isActiveAttachmentMelee(Handed.Right) == true
    weaponMesh = held and mesh or nil
    if held ~= meleeHeld then
        meleeHeld = held
        local id = held and attachments.getActiveAttachmentID(Handed.Right) or nil
        currentWeaponID = (id ~= nil and id ~= "") and id or nil
        configui.setLabel("pm_weapon_label", held and ("Weapon: " .. tostring(currentWeaponID or "?") .. " (melee)") or "Weapon: not melee")
        log(held and ("melee weapon held: " .. tostring(currentWeaponID)) or "melee weapon released")
    end
    return held
end

-- ---------------------------------------------------------------------------------------------
-- Anim rate control
-- ---------------------------------------------------------------------------------------------
local rateActive     = false
local rateSeenMontage = false
local rateStartedAt  = 0
local rateValue      = 1.0
local rateMontageAt  = 0        -- os.clock() when the montage was first seen after the tap
local rateApplied    = nil      -- rate currently written to the meshes

local function getArmsMesh()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return nil end
    local ok, mesh = pcall(function() return pawn.FPVMesh end)
    if ok and alive(mesh) then return mesh end
    return nil
end

local function setRates(rate)
    rateApplied = rate
    pcall(function()
        local arms = getArmsMesh()
        if arms ~= nil and arms.GlobalAnimRateScale ~= rate then arms.GlobalAnimRateScale = rate end
        if alive(weaponMesh) and weaponMesh.GlobalAnimRateScale ~= rate then weaponMesh.GlobalAnimRateScale = rate end
    end)
end

local function restoreRate(reason)
    if not rateActive then return end
    rateActive = false
    setRates(1.0)
    rateApplied = nil
    configui.setLabel("pm_rate_label", "Anim rate: 1.0")
    log("anim rate restored (" .. tostring(reason) .. ")")
end

-- The montage's MeleeDamage notify is 0.12 s of ANIMATION time, so at a high GlobalAnimRateScale the
-- hit test is open for only a frame or two of wall time - a fast physical swing has already left the
-- enemy. Once the montage is seen, hold a lower rate (pm_window_rate) for pm_window_time so the window
-- stays open while the baton passes through, then go back to the full rate to finish the swing quickly.
local function currentTargetRate(now)
    if not rateSeenMontage then return rateValue end
    local holdTime = cfgNum("pm_window_time", 0.2)
    if holdTime > 0 and (now - rateMontageAt) < holdTime then
        local r = cfgNum("pm_window_rate", 1.5)
        if r < 1.0 then r = 1.0 end
        if r > rateValue then r = rateValue end
        return r
    end
    return rateValue
end

local function armsMontageName()
    local name = nil
    pcall(function()
        local arms = getArmsMesh()
        local ai = arms and arms.AnimScriptInstance
        if ai == nil or ai.GetCurrentActiveMontage == nil then return end
        local m = ai:GetCurrentActiveMontage()
        if m ~= nil then name = uevrUtils.getShortName(m) end
    end)
    return name
end

local function startRate()
    rateValue = cfgNum("pm_anim_rate", 10.0)
    if rateValue <= 1.0 then return end
    rateActive = true
    rateSeenMontage = false
    rateStartedAt = os.clock()
    rateMontageAt = 0
    rateApplied = nil
    setRates(rateValue)
    configui.setLabel("pm_rate_label", string.format("Anim rate: %.1f", rateValue))
end

-- Per tick while active: hold the rate on both meshes until the arms montage started by the tap
-- has finished (or the safety deadlines hit).
local function updateRate()
    if not rateActive then return end
    local now = os.clock()
    local elapsed = now - rateStartedAt
    if elapsed > RATE_MAX_SECONDS then restoreRate("deadline") return end
    local name = armsMontageName()
    if name ~= nil then
        if not rateSeenMontage then
            rateSeenMontage = true
            rateMontageAt = now
            log(string.format("montage: %s (%.0f ms after tap)", name, elapsed * 1000))
        end
        local target = currentTargetRate(now)
        if rateApplied ~= target then
            setRates(target)
            configui.setLabel("pm_rate_label", string.format("Anim rate: %.1f", target))
        end
    elseif rateSeenMontage then
        configui.setLabel("pm_timing_label", string.format("Timing: tap->montage %.0f ms, montage %.0f ms",
            (rateMontageAt - rateStartedAt) * 1000, (now - rateMontageAt) * 1000))
        restoreRate("montage ended")
    elseif elapsed > RATE_ARM_SECONDS then
        restoreRate("no montage started")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Trigger injection
-- ---------------------------------------------------------------------------------------------
local triggerPollsLeft = 0
local triggerDeadline  = 0

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    if triggerPollsLeft <= 0 then return end
    if os.clock() > triggerDeadline then
        triggerPollsLeft = 0
        return
    end
    state.Gamepad.bRightTrigger = 255
    triggerPollsLeft = triggerPollsLeft - 1
end, 20) -- before hands_animation (10) so the trigger pose plays too, before two_handed (5) and remap (0)

local function fireAttack(kind, speed)
    triggerPollsLeft = math.floor(cfgNum("pm_trigger_polls", 3) + 0.5)
    if triggerPollsLeft < 1 then triggerPollsLeft = 1 end
    triggerDeadline = os.clock() + TRIGGER_MAX_HOLD
    startRate()
    configui.setLabel("pm_swing_label", string.format("Last swing: %s %.0f cm/s", kind, speed))
    log(string.format("%s swing %.0f cm/s -> RT tap", kind, speed))
end

-- ---------------------------------------------------------------------------------------------
-- Game melee capsule (from the weapon's MeleeMode), sampled along its axis
-- ---------------------------------------------------------------------------------------------
local capsuleSocketName = nil      -- FName
local capsuleSocketStr  = "MeleeCollisionSocket"
local capsuleHalfHeight = 97.5
local capsuleRadius     = 10.0
local capsuleOffsetZ    = 51.5
local capsuleWeaponPtr  = nil      -- weapon actor the values were read from

local function readGameCapsule()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil or pawn.GetCurrentWeapon == nil then return end
    local weapon = pawn:GetCurrentWeapon()
    if weapon == nil or weapon == capsuleWeaponPtr then return end
    capsuleWeaponPtr = weapon
    -- defaults (baton values) unless the weapon says otherwise
    capsuleSocketStr, capsuleHalfHeight, capsuleRadius, capsuleOffsetZ = "MeleeCollisionSocket", 97.5, 10.0, 51.5
    pcall(function()
        local mode = weapon.PrimaryMode
        local col = mode and mode.DefaultMeleeCollision
        if col == nil then return end
        local sock = col.CollisionSocket
        if sock ~= nil then
            local s = tostring(sock)
            if sock.to_string ~= nil then s = sock:to_string() end
            if s ~= nil and s ~= "" and s ~= "None" then capsuleSocketStr = s end
        end
        local shape = col.CollisionShapeInfo
        if shape ~= nil then
            local cap = shape.Shape and shape.Shape.CapsuleData
            if cap ~= nil then
                if type(cap.CapsuleHalfHeight) == "number" and cap.CapsuleHalfHeight > 0 then capsuleHalfHeight = cap.CapsuleHalfHeight end
                if type(cap.CapsuleRadius) == "number" and cap.CapsuleRadius > 0 then capsuleRadius = cap.CapsuleRadius end
            end
            local tr = shape.ShapeTransform and shape.ShapeTransform.Translation
            if tr ~= nil and type(tr.Z) == "number" then capsuleOffsetZ = tr.Z end
        end
    end)
    capsuleSocketName = uevrUtils.fname_from_string(capsuleSocketStr)
    log(string.format("game melee capsule: socket %s hh %.1f r %.1f offZ %.1f", capsuleSocketStr, capsuleHalfHeight, capsuleRadius, capsuleOffsetZ))
end

-- UE rotator -> unit up (Z) vector
local function upVector(rot)
    local p, y, r = math.rad(rot.Pitch), math.rad(rot.Yaw), math.rad(rot.Roll)
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    return { X = -(cr * sp * cy + sr * sy), Y = cy * sr - cr * sp * sy, Z = cr * cp }
end

-- Returns a list of world points along the game's melee capsule axis (socket + offset +/- half height)
local function capsulePoints()
    if not alive(weaponMesh) then return nil end
    if capsuleSocketName == nil then capsuleSocketName = uevrUtils.fname_from_string(capsuleSocketStr) end
    local base, rot = nil, nil
    pcall(function()
        base = weaponMesh:GetSocketLocation(capsuleSocketName)
        rot  = weaponMesh:GetSocketRotation(capsuleSocketName)
    end)
    if base == nil then return nil end
    if rot == nil then
        local ok, r = pcall(function() return weaponMesh:K2_GetComponentRotation() end)
        if not ok or r == nil then return nil end
        rot = r
    end
    local up = upVector(rot)
    local pts = {}
    for i = 0, CAPSULE_SAMPLES - 1 do
        local t = capsuleOffsetZ - capsuleHalfHeight + (2 * capsuleHalfHeight) * (i / (CAPSULE_SAMPLES - 1))
        pts[#pts + 1] = { X = base.X + up.X * t, Y = base.Y + up.Y * t, Z = base.Z + up.Z * t }
    end
    return pts
end

-- ---------------------------------------------------------------------------------------------
-- Debug: sphere markers along the game's melee capsule (one per sample point)
-- ---------------------------------------------------------------------------------------------
local SPHERE_MESH_PATH = "StaticMesh /Engine/BasicShapes/Sphere.Sphere"   -- 100 UU diameter
local SPHERE_MAT_PATH  = "Material /Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"
local SMC_CLASS_PATH   = "Class /Script/Engine.StaticMeshComponent"
local debugSpheres = {}
local debugTouching = false

local function destroyDebugSpheres()
    for i, comp in ipairs(debugSpheres) do
        pcall(function() if alive(comp) then comp:K2_DestroyComponent(comp) end end)
    end
    debugSpheres = {}
end

local function hideDebugSpheres()
    for _, comp in ipairs(debugSpheres) do
        pcall(function() if alive(comp) then comp:SetHiddenInGame(true, false) end end)
    end
end

local function getDebugSphere(index)
    local comp = debugSpheres[index]
    if comp ~= nil and not alive(comp) then comp = nil debugSpheres[index] = nil end
    if comp ~= nil then return comp end
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return nil end
    local smcClass = uevr.api:find_uobject(SMC_CLASS_PATH)
    if smcClass == nil then return nil end
    local identityT = { Rotation = {X=0,Y=0,Z=0,W=1}, Translation = {X=0,Y=0,Z=0}, Scale3D = {X=1,Y=1,Z=1} }
    local ok, created = pcall(function() return pawn:AddComponentByClass(smcClass, true, identityT, false) end) -- manual attachment: free in world space
    if not ok or created == nil or created == false then return nil end
    comp = created
    pcall(function() comp:SetMobility(2) end) -- Movable, before any transform write
    local mesh = uevr.api:find_uobject(SPHERE_MESH_PATH)
    if mesh ~= nil then pcall(function() comp:SetStaticMesh(mesh) end) end
    local mat = uevr.api:find_uobject(SPHERE_MAT_PATH)
    if mat ~= nil then pcall(function() comp:SetMaterial(0, mat) end) end
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() if comp.SetForeground ~= nil then comp:SetForeground(false) end end)
    pcall(function() comp:SetRenderInMainPass(true) end)
    debugSpheres[index] = comp
    return comp
end

-- Called once per tick after the contact test. `pts` = capsulePoints() result (may be nil).
local function updateDebugSpheres(pts)
    if configui.getValue("pm_debug_capsule") ~= true then
        if #debugSpheres > 0 then hideDebugSpheres() end
        return
    end
    if pts == nil then hideDebugSpheres() return end
    -- sphere diameter = the game's capsule diameter + forgiveness; the touching state doubles it
    local radius = capsuleRadius + cfgNum("pm_hit_buffer", 15.0)
    if debugTouching then radius = radius * 2 end
    local scale = (radius * 2) / 100.0
    for i, pt in ipairs(pts) do
        local comp = getDebugSphere(i)
        if comp ~= nil then
            pcall(function()
                comp:SetHiddenInGame(false, false)
                comp:K2_SetWorldLocation({ X = pt.X, Y = pt.Y, Z = pt.Z }, false, {}, false)
                comp:SetWorldScale3D({ X = scale, Y = scale, Z = scale })
            end)
        end
    end
    for i = #pts + 1, #debugSpheres do
        pcall(function() if alive(debugSpheres[i]) then debugSpheres[i]:SetHiddenInGame(true, false) end end)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Enemy cache (positions + capsule sizes of hostile AI characters within range)
-- ---------------------------------------------------------------------------------------------
local enemies = {}          -- { X, Y, Z, r, hh }
local enemyRefreshTick = 0

local function isHostile(actor, pawn)
    local hostile = nil
    pcall(function()
        local ctrl = actor:GetController()
        if ctrl == nil or ctrl.K2_GetTeamAttitudeTowards == nil then return end
        local att = ctrl:K2_GetTeamAttitudeTowards(pawn)
        -- ETeamAttitude: 0 Friendly, 1 Neutral, 2 Hostile
        if type(att) == "number" then hostile = (att == 2) end
    end)
    if hostile == nil then return true end   -- unknown -> treat as a valid target
    return hostile
end

local function refreshEnemies()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then enemies = {} return end
    local okp, ploc = pcall(function() return pawn:K2_GetActorLocation() end)
    if not okp or ploc == nil then enemies = {} return end
    local range = cfgNum("pm_enemy_range", 400.0)
    local range2 = range * range
    local wantFriendly = configui.getValue("pm_hit_friendly") == true
    local list = uevrUtils.find_all_of(ENEMY_CLASS, false) or {}
    local count = 0
    for _, actor in ipairs(list) do
        if actor ~= pawn then
            local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
            if ok and loc ~= nil then
                local dx, dy, dz = loc.X - ploc.X, loc.Y - ploc.Y, loc.Z - ploc.Z
                if dx * dx + dy * dy + dz * dz <= range2 then
                    if wantFriendly or isHostile(actor, pawn) then
                        local r, hh = 40.0, 90.0
                        pcall(function()
                            local cap = actor.CapsuleComponent
                            if cap ~= nil then
                                if type(cap.CapsuleRadius) == "number" and cap.CapsuleRadius > 0 then r = cap.CapsuleRadius end
                                if type(cap.CapsuleHalfHeight) == "number" and cap.CapsuleHalfHeight > 0 then hh = cap.CapsuleHalfHeight end
                            end
                        end)
                        count = count + 1
                        local e = enemies[count]
                        if e == nil then e = {} enemies[count] = e end
                        e.X, e.Y, e.Z, e.r, e.hh, e.actor = loc.X, loc.Y, loc.Z, r, hh, actor
                    end
                end
            end
        end
    end
    for i = count + 1, #enemies do enemies[i] = nil end
end

-- cheap per-tick refresh of the cached enemies' positions (the class scan itself stays every N ticks)
local function refreshEnemyPositions()
    for _, e in ipairs(enemies) do
        pcall(function()
            if e.actor ~= nil then
                local loc = e.actor:K2_GetActorLocation()
                if loc ~= nil then e.X, e.Y, e.Z = loc.X, loc.Y, loc.Z end
            end
        end)
    end
end

-- world-space hand velocity (cm/s) from the last detect() sample, used for the contact look-ahead
local handVelocity = { X = 0, Y = 0, Z = 0 }

-- point inside an enemy capsule (plus the game's own capsule radius and the forgiveness buffer)
local function pointHitsEnemy(pt, e, buffer)
    local dx, dy, dz = pt.X - e.X, pt.Y - e.Y, pt.Z - e.Z
    local r = e.r + capsuleRadius + buffer
    if dx * dx + dy * dy > r * r then return false end
    return math.abs(dz) < (e.hh + capsuleRadius + buffer)
end

local function weaponTouchesEnemy()
    local pts = capsulePoints()
    local touching = false
    if pts ~= nil and #enemies > 0 then
        local buffer = cfgNum("pm_hit_buffer", 15.0)
        -- look-ahead: test where the capsule will be in pm_lead seconds so the tap lands before the
        -- fast-moving baton is already through the target (the debug spheres show the real points)
        local lead = cfgNum("pm_lead", 0.05)
        local lx, ly, lz = handVelocity.X * lead, handVelocity.Y * lead, handVelocity.Z * lead
        local probe = pts
        if lead > 0 and (lx ~= 0 or ly ~= 0 or lz ~= 0) then
            probe = {}
            for i, pt in ipairs(pts) do probe[i] = { X = pt.X + lx, Y = pt.Y + ly, Z = pt.Z + lz } end
        end
        for _, e in ipairs(enemies) do
            for i, pt in ipairs(pts) do
                if pointHitsEnemy(pt, e, buffer) or pointHitsEnemy(probe[i], e, buffer) then touching = true break end
            end
            if touching then break end
        end
    end
    debugTouching = touching
    updateDebugSpheres(pts)
    return touching
end

local function haptic()
    pcall(function()
        vr.trigger_haptic_vibration(0, 0.12, 0.8, 1.0, vr.get_right_joystick_source())
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Swing detection
-- ---------------------------------------------------------------------------------------------
local prevHandPos, prevHeadPos, prevHeadYaw = nil, nil, nil
local prevSampleTime = nil
local peakSpeed, peakDir = 0, nil
local cooldownUntil = 0
local contactLabelTick = 0

-- contact-mode edge state
local inContact       = false   -- weapon capsule overlapped an enemy on the last sample
local contactLostAt   = nil     -- os.clock() when contact was last lost (re-arm timer)
local lastContactFire = 0       -- os.clock() of the last contact-mode attack

local function clearMotion()
    prevHandPos, prevHeadPos, prevHeadYaw = nil, nil, nil
    prevSampleTime = nil
    peakSpeed, peakDir = 0, nil
end

local function clearContact()
    inContact = false
    contactLostAt = nil
end

local function rotateInverseYaw(v, yawDeg)
    local r = -math.rad(yawDeg)
    local c, s = math.cos(r), math.sin(r)
    return { X = v.X * c - v.Y * s, Y = v.X * s + v.Y * c, Z = v.Z }
end

-- "down" | "left" | "right" | "stab" for an accepted swing, nil for up / pull-back / disabled stab.
local function classify(dir)
    local ax, ay, az = math.abs(dir.X), math.abs(dir.Y), math.abs(dir.Z)
    if az >= ax and az >= ay then
        if dir.Z > 0 then return nil end
        return "down"
    elseif ay >= ax then
        return dir.Y < 0 and "left" or "right"
    else
        if dir.X < 0 then return nil end
        if configui.getValue("pm_accept_stab") ~= true then return nil end
        return "stab"
    end
end

-- Contact mode decision for this sample. `speed` is the hand speed (cm/s) this tick.
-- Fires on the entry edge (not in contact -> in contact) while the weapon is moving; while the weapon
-- stays inside, only after the re-fire interval and only if it is moving again.
local function contactStep(now, speed)
    local touching = weaponTouchesEnemy()
    local minSpeed = cfgNum("pm_contact_speed", 120.0)
    local fire = false

    if touching then
        if not inContact then
            -- entry edge; ignore a re-entry that follows a loss shorter than the re-arm time (jitter)
            local reArmed = contactLostAt == nil or (now - contactLostAt) >= CONTACT_REARM_SECONDS
            inContact = true
            contactLostAt = nil
            if reArmed and speed >= minSpeed then fire = true end
        else
            local refire = cfgNum("pm_contact_refire", 0.6)
            if speed >= minSpeed and (now - lastContactFire) >= refire then fire = true end
        end
    else
        if inContact then
            inContact = false
            contactLostAt = now
        end
    end

    if fire and now >= cooldownUntil then
        lastContactFire = now
        fireAttack("contact", speed)
        haptic()
        cooldownUntil = now + cfgNum("pm_cooldown", 0.35)
        configui.setLabel("pm_contact_label", string.format("Contact: HIT %.0f cm/s (%d enemies in range)", speed, #enemies))
        return
    end

    contactLabelTick = contactLabelTick + 1
    if contactLabelTick % 15 == 0 then
        configui.setLabel("pm_contact_label", string.format("Contact: %s, %d enemies in range, weapon %.0f cm/s",
            touching and "touching" or "clear", #enemies, speed))
    end
end

local function detect()
    local now = os.clock()
    local contactMode = configui.getValue("pm_melee_type") ~= 2 -- 1 = contact (default), 2 = fire on swing peak

    local hand = controllers.getController(1, true)   -- right controller
    local head = controllers.getHMDController()
    if not alive(hand) or not alive(head) then clearMotion() clearContact() return end

    local handPos = hand:K2_GetComponentLocation()
    local headPos = head:K2_GetComponentLocation()
    local headRot = head:K2_GetComponentRotation()
    if handPos == nil or headPos == nil or headRot == nil then clearMotion() clearContact() return end

    local hp = { X = handPos.X, Y = handPos.Y, Z = handPos.Z }
    local hd = { X = headPos.X, Y = headPos.Y, Z = headPos.Z }
    local yaw = headRot.Yaw

    if prevHandPos == nil or prevSampleTime == nil then
        prevHandPos, prevHeadPos, prevHeadYaw, prevSampleTime = hp, hd, yaw, now
        return
    end

    local dt = now - prevSampleTime
    prevSampleTime = now
    if dt <= 0.0005 then return end
    if dt > 0.1 then
        -- frame stall / pause: this sample is meaningless
        prevHandPos, prevHeadPos, prevHeadYaw = hp, hd, yaw
        peakSpeed, peakDir = 0, nil
        return
    end

    -- snap turn / large head yaw jump: throw the sample away
    local dYaw = math.abs(yaw - prevHeadYaw)
    if dYaw > 180 then dYaw = 360 - dYaw end
    if dYaw > 45 then
        prevHandPos, prevHeadPos, prevHeadYaw = hp, hd, yaw
        peakSpeed, peakDir = 0, nil
        return
    end

    -- hand motion with the head's (pawn's) own motion removed, in the head yaw frame
    local dw = { X = (hp.X - prevHandPos.X) - (hd.X - prevHeadPos.X),
                 Y = (hp.Y - prevHandPos.Y) - (hd.Y - prevHeadPos.Y),
                 Z = (hp.Z - prevHandPos.Z) - (hd.Z - prevHeadPos.Z) }
    local dl = rotateInverseYaw(dw, yaw)
    local dist = math.sqrt(dl.X * dl.X + dl.Y * dl.Y + dl.Z * dl.Z)
    local speed = dist / dt
    prevHandPos, prevHeadPos, prevHeadYaw = hp, hd, yaw
    handVelocity.X, handVelocity.Y, handVelocity.Z = dw.X / dt, dw.Y / dt, dw.Z / dt

    -- -------- contact mode: moving weapon enters an enemy -> attack now --------
    if contactMode then
        contactStep(now, speed)
        return
    end
    if #debugSpheres > 0 then hideDebugSpheres() end

    -- -------- peak mode (old): classify on the first decelerating sample --------
    if now < cooldownUntil then
        peakSpeed, peakDir = 0, nil
        return
    end
    local minSpeed = cfgNum("pm_min_speed", 180.0)
    if speed > minSpeed and speed > peakSpeed and dist > 0 then
        peakSpeed = speed
        peakDir = { X = dl.X / dist, Y = dl.Y / dist, Z = dl.Z / dist }
        return
    end

    if peakSpeed > 0 and peakDir ~= nil then
        local kind = classify(peakDir)
        local pk, pd = peakSpeed, peakDir
        peakSpeed, peakDir = 0, nil
        if kind ~= nil then
            fireAttack(kind, pk)
            cooldownUntil = now + cfgNum("pm_cooldown", 0.35)
        else
            log(string.format("ignored swing %.0f cm/s dir(%.2f %.2f %.2f)", pk, pd.X, pd.Y, pd.Z))
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Per-tick body: once per tick from the post-stereo callback (valid controller poses)
-- ---------------------------------------------------------------------------------------------
local ranThisTick = false

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    ranThisTick = false
end)

local function tick()
    if configui.getValue("pm_enabled") == false then
        restoreRate("disabled")
        clearMotion()
        clearContact()
        return
    end
    local held = updateMeleeState()
    updateRate()
    if not held then
        clearMotion()
        clearContact()
        if #debugSpheres > 0 then hideDebugSpheres() end
        return
    end
    if configui.getValue("pm_melee_type") ~= 2 then
        readGameCapsule()
        enemyRefreshTick = enemyRefreshTick + 1
        if enemyRefreshTick >= ENEMY_REFRESH_TICKS then
            enemyRefreshTick = 0
            local ok, err = pcall(refreshEnemies)
            if not ok then log("enemy refresh failed: " .. tostring(err)) end
        else
            refreshEnemyPositions()
        end
    end
    detect()
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not vr.is_hmd_active() then return end
    if ranThisTick then return end
    ranThisTick = true
    local ok, err = pcall(tick)
    if not ok then print("[physical_melee] " .. tostring(err)) end
end)

-- weapon change on the right hand: never carry a raised rate over to the next weapon (the game
-- reuses one FPV weapon mesh component across weapons)
uevrUtils.registerUEVRCallback("attachment_grip_changed", function(id, gripHand, attachment)
    if gripHand == Handed.Right then
        restoreRate("weapon changed")
        triggerPollsLeft = 0
        clearMotion()
        clearContact()
        meleeHeld = false
        weaponMesh = nil
        capsuleWeaponPtr = nil
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    rateActive = false
    triggerPollsLeft = 0
    clearMotion()
    clearContact()
    meleeHeld = false
    weaponMesh = nil
    capsuleWeaponPtr = nil
    enemies = {}
    debugSpheres = {}   -- owned by the old pawn, gone with it
end)

configui.onUpdate("pm_debug_capsule", function(value)
    if value ~= true then hideDebugSpheres() end
end)

print("[physical_melee] loaded")
