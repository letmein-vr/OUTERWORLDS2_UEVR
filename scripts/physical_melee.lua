-- Physical melee for The Outer Worlds 2 (2026-09-26).
--
-- While the right hand holds an attachment flagged "Melee" in Attachment Configuration
-- (attachments_parameters.json "melee": true), a fast swing of the right controller - left, right
-- or down (optionally a forward stab) - is turned into a short Right Trigger tap, which is the
-- game's melee attack, and the player's first-person melee montages are fast-forwarded through
-- GlobalAnimRateScale on the arms mesh (Pawn.FPVMesh) and the weapon mesh so the game's swing
-- resolves close to the physical one instead of playing out over half a second.
--
-- What the game does on a trigger tap with the baton (live trace, MeleeAnimEventEffect.CurrentAnimMontage):
--   MeleeAction 2  AS_P1P_ME1H_ShockBaton_PWR_Attack_Windup_Montage1   (power-attack windup, while RT is held)
--   MeleeAction 4  AS_P1P_ME1H_ShockBaton_R2L_Hit_Montage -> _R2L_End_Montage (light attack on release)
-- so the injected tap must be SHORT (a held RT becomes a power attack windup). The montages play on
-- Pawn.FPVMesh (ARK_P1P_AnimBP_C); the weapon mesh (Weapon.FPVWeaponMesh, AnimBp_ME1H_ShockBaton_C)
-- plays matching *_MESB_* montages. They are started natively (no Montage_Play UFunction call), so
-- there is nothing to hook - the arms anim instance is polled with GetCurrentActiveMontage().
--
-- Swing detection is the Stalker 2 knife_melee detector: hand delta minus head delta in the HMD
-- yaw frame, peak speed tracked, classified by dominant axis on the first decelerating sample
-- (early fire, keeps the attack close to the physical hit). Dominant UP (raising the arm) and
-- pull-BACK are never attacks. NOTE: on this game the MotionControllerComponents only hold real
-- poses in the post-stereo callback (on the game thread they read as the pawn root - see
-- two_handed.lua), so sampling happens there, once per tick.

local uevrUtils   = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local attachments = require('libs/attachments')
local configui    = require('libs/configui')

local vr = uevr.params.vr

local TRIGGER_MAX_HOLD   = 0.25  -- s: hard cap on the injected RT hold (a long hold = power attack windup)
local RATE_MAX_SECONDS   = 1.0   -- s: unconditional restore deadline for the anim rate
local RATE_ARM_SECONDS   = 0.35  -- s: give up waiting for a montage to appear after the tap

-- ---------------------------------------------------------------------------------------------
-- Config UI
-- ---------------------------------------------------------------------------------------------
-- Section of the merged "Outer Worlds 2 VR" panel (see scripts/zz_ow2_vr_panel.lua)
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 3, label = "Physical Melee", layout = {
            { widgetType = "checkbox",     id = "pm_enabled",       label = "Enable physical melee (swing = attack)", initialValue = true },
            { widgetType = "slider_float", id = "pm_min_speed",     label = "Min swing speed (cm/s)", initialValue = 180.0, range = {50.0, 600.0} },
            { widgetType = "slider_float", id = "pm_cooldown",      label = "Cooldown between swings (s)", initialValue = 0.35, range = {0.1, 1.5} },
            { widgetType = "slider_float", id = "pm_anim_rate",     label = "Melee anim rate scale", initialValue = 10.0, range = {1.0, 30.0} },
            { widgetType = "slider_int",   id = "pm_trigger_polls", label = "RT tap length (xinput polls)", initialValue = 3, range = {1, 6} },
            { widgetType = "checkbox",     id = "pm_accept_stab",   label = "Also accept forward stab", initialValue = false },
            { widgetType = "checkbox",     id = "pm_log",           label = "Log to console", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", id = "pm_weapon_label", label = "Weapon: none" },
            { widgetType = "text", id = "pm_swing_label",  label = "Last swing: -" },
            { widgetType = "text", id = "pm_rate_label",   label = "Anim rate: 1.0" },
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

local function getArmsMesh()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return nil end
    local ok, mesh = pcall(function() return pawn.FPVMesh end)
    if ok and alive(mesh) then return mesh end
    return nil
end

local function setRates(rate)
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
    configui.setLabel("pm_rate_label", "Anim rate: 1.0")
    log("anim rate restored (" .. tostring(reason) .. ")")
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
    setRates(rateValue)
    configui.setLabel("pm_rate_label", string.format("Anim rate: %.1f", rateValue))
end

-- Per tick while active: hold the rate on both meshes until the arms montage started by the tap
-- has finished (or the safety deadlines hit).
local function updateRate()
    if not rateActive then return end
    local elapsed = os.clock() - rateStartedAt
    if elapsed > RATE_MAX_SECONDS then restoreRate("deadline") return end
    local name = armsMontageName()
    if name ~= nil then
        if not rateSeenMontage then log("montage: " .. name) end
        rateSeenMontage = true
        setRates(rateValue)
    elseif rateSeenMontage then
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

-- ---------------------------------------------------------------------------------------------
-- Swing detection
-- ---------------------------------------------------------------------------------------------
local prevHandPos, prevHeadPos, prevHeadYaw = nil, nil, nil
local prevSampleTime = nil
local peakSpeed, peakDir = 0, nil
local cooldownUntil = 0

local function clearMotion()
    prevHandPos, prevHeadPos, prevHeadYaw = nil, nil, nil
    prevSampleTime = nil
    peakSpeed, peakDir = 0, nil
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

local function fireAttack(kind, speed)
    triggerPollsLeft = math.floor(cfgNum("pm_trigger_polls", 3) + 0.5)
    if triggerPollsLeft < 1 then triggerPollsLeft = 1 end
    triggerDeadline = os.clock() + TRIGGER_MAX_HOLD
    startRate()
    configui.setLabel("pm_swing_label", string.format("Last swing: %s %.0f cm/s", kind, speed))
    log(string.format("%s swing %.0f cm/s -> RT tap", kind, speed))
end

local function detect()
    local now = os.clock()
    if now < cooldownUntil then
        clearMotion()
        return
    end

    local hand = controllers.getController(1, true)   -- right controller
    local head = controllers.getHMDController()
    if not alive(hand) or not alive(head) then clearMotion() return end

    local handPos = hand:K2_GetComponentLocation()
    local headPos = head:K2_GetComponentLocation()
    local headRot = head:K2_GetComponentRotation()
    if handPos == nil or headPos == nil or headRot == nil then clearMotion() return end

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

    local minSpeed = cfgNum("pm_min_speed", 180.0)
    if speed > minSpeed and speed > peakSpeed and dist > 0 then
        peakSpeed = speed
        peakDir = { X = dl.X / dist, Y = dl.Y / dist, Z = dl.Z / dist }
        return
    end

    -- first sample slower than the peak: the swing has peaked, classify now
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
        return
    end
    local held = updateMeleeState()
    updateRate()
    if not held then
        clearMotion()
        return
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
        meleeHeld = false
        weaponMesh = nil
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    rateActive = false
    triggerPollsLeft = 0
    clearMotion()
    meleeHeld = false
    weaponMesh = nil
end)

print("[physical_melee] loaded")
