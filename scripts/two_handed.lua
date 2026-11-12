-- Two-handed weapon aiming for The Outer Worlds 2 (ported from the Cronos profile's
-- two_handed_integration.lua, reduced to the weapon-aiming part and driven by uevrlib).
--
-- Only attachments flagged "Two Handed" in Attachment Configuration (attachments_parameters.json
-- "two_handed": true) can be two-handed. To grab: bring the left controller to the fore-grip point on
-- the weapon and hold the grab button (left trigger by default, or left grip; see the panel). While held:
--   * the weapon mesh is rotated every frame so its barrel points from the right hand towards the
--     left hand (libs/two_handed_aiming.lua, applied in the post-stereo callback, i.e. after
--     UObjectHook has positioned the weapon on the right controller - same timing Cronos uses),
--   * both hand copies are parented to the weapon mesh (keeping their world transform at grab
--     time) so they stay glued to the gun while it pivots, and the left hand shows the weapon's
--     left grip pose (left_grip_weapon_<animation>, from the hands wizard),
--   * the grab button is optionally hidden from the game.
-- Releasing the button (or moving the left hand too far from the grip point) restores everything.
--
-- The fore-grip point has no socket on OW2 weapons, so it is derived per weapon: a point along the
-- line from the weapon mesh origin to the MuzzleFlashSocket (fraction), plus a per-attachment
-- offset in weapon-local space (X = barrel axis, Y = right, Z = up). Tune with the sliders in the
-- "Two-Handed" panel; values are saved per attachment id into data/two_handed_parameters.json.

local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local attachments = require('libs/attachments')
local hands = require('libs/hands')
local configui = require('libs/configui')
local twoHandedAiming = require('libs/two_handed_aiming')
local animation = require('libs/animation')
local pawnModule = require('libs/pawn')

local vr = uevr.params.vr

local paramsFile = "two_handed_parameters"
local params = {}      -- { [attachmentID] = { offX, offY, offZ, fraction } }
local function loadParams()
    local p = json.load_file(paramsFile .. ".json")
    if p ~= nil then params = p end
end
local function saveParams()
    json.dump_file(paramsFile .. ".json", params, 4)
end
loadParams()

-- ---------------------------------------------------------------------------------------------
-- Config UI
-- ---------------------------------------------------------------------------------------------
-- Section of the merged "Outer Worlds 2 VR" panel (see scripts/zz_ow2_vr_panel.lua)
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 2, label = "Two-Handed Aiming", layout = {
            { widgetType = "checkbox", id = "th_enabled", label = "Enable Two-Handing", initialValue = true },
            { widgetType = "combo", id = "th_grab_button", label = "Grab button", initialValue = 2, selections = {"Left grip", "Left trigger"} },
            { widgetType = "checkbox", id = "th_suppress_left_grip", label = "Hide grab button from game while two-handing", initialValue = true },
            { widgetType = "checkbox", id = "th_ads", label = "Aim down sights (ADS) while two-handing", initialValue = true },
            { widgetType = "checkbox", id = "th_snap_left_hand", label = "Snap left hand to grip point", initialValue = true },
            { widgetType = "checkbox", id = "th_game_left_grip", label = "Left hand takes the game's own grip (hand + fingers, measured per weapon)", initialValue = true },
            { widgetType = "text", id = "th_game_left_label", label = "Game left grip: -" },
            { widgetType = "button", id = "th_game_left_remeasure", label = "Re-measure this weapon's left grip", size = {260, 24} },
            { widgetType = "slider_float", id = "th_grab_radius", label = "Grab radius (cm)", initialValue = 14.0, range = {3.0, 40.0} },
            { widgetType = "slider_float", id = "th_release_radius", label = "Release radius (cm)", initialValue = 35.0, range = {5.0, 100.0} },
            { widgetType = "spacing" },
            { widgetType = "text", id = "th_weapon_label", label = "Weapon: none" },
            { widgetType = "text", id = "th_status_label", label = "Status: idle" },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Grip point for the current weapon (saved per attachment)" },
            { widgetType = "slider_float", id = "th_fraction", label = "Along barrel (0=grip, 1=muzzle)", initialValue = 0.55, range = {0.0, 1.5} },
            { widgetType = "slider_float", id = "th_off_x", label = "Offset X (forward)", initialValue = 0.0, range = {-40.0, 40.0} },
            { widgetType = "slider_float", id = "th_off_y", label = "Offset Y (right)", initialValue = 0.0, range = {-40.0, 40.0} },
            { widgetType = "slider_float", id = "th_off_z", label = "Offset Z (up)", initialValue = 0.0, range = {-40.0, 40.0} },
            { widgetType = "checkbox", id = "th_show_marker", label = "Show grip point marker", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Left hand pose while two-handing (saved per attachment)" },
            { widgetType = "text", id = "th_pose_label", label = "Pose: none" },
            { widgetType = "checkbox", id = "th_apply_pose", label = "Apply captured pose while two-handing", initialValue = true },
            { widgetType = "button", id = "th_capture_pose", label = "Get left hand pose from current mesh", size = {260, 24} },
            { widgetType = "button", id = "th_clear_pose", label = "Clear left hand pose", size = {180, 24} },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Left hand placement while two-handing (weapon-local, saved per attachment)" },
            { widgetType = "slider_float", id = "th_lh_off_x", label = "LH Offset X", initialValue = 0.0, range = {-30.0, 30.0} },
            { widgetType = "slider_float", id = "th_lh_off_y", label = "LH Offset Y", initialValue = 0.0, range = {-30.0, 30.0} },
            { widgetType = "slider_float", id = "th_lh_off_z", label = "LH Offset Z", initialValue = 0.0, range = {-30.0, 30.0} },
            { widgetType = "slider_float", id = "th_lh_rot_pitch", label = "LH Rot Pitch", initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "th_lh_rot_yaw", label = "LH Rot Yaw", initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "th_lh_rot_roll", label = "LH Rot Roll", initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "checkbox", id = "th_force", label = "Force two-handing ON (dev)", initialValue = false },
}})

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------
local active = false
local currentWeaponID = nil
local lastLeftButtons = 0
local poseReapplyTimer = 0
local leftGripDown = false   -- state of the configured grab button (grip or trigger), raw, before the game sees it
local ranThisTick = false
local snapshots = {}          -- [hand] = { parent, socket, loc={X,Y,Z}, rot={Pitch,Yaw,Roll} }
local marker = nil
local hitResult = nil

local function getHitResult()
    if hitResult == nil then
        hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
    end
    return hitResult
end

local function status(text)
    configui.setLabel("th_status_label", "Status: " .. text)
end

local function getWeaponParams(id)
    if id == nil then return nil end
    if params[id] == nil then
        params[id] = { fraction = 0.55, offX = 0, offY = 0, offZ = 0 }
    end
    return params[id]
end

local function loadWeaponParamsToUI(id)
    local p = getWeaponParams(id)
    if p == nil then return end
    configui.setValue("th_fraction", p.fraction or 0.55)
    configui.setValue("th_off_x", p.offX or 0)
    configui.setValue("th_off_y", p.offY or 0)
    configui.setValue("th_off_z", p.offZ or 0)
    configui.setValue("th_lh_off_x", p.lhOffX or 0)
    configui.setValue("th_lh_off_y", p.lhOffY or 0)
    configui.setValue("th_lh_off_z", p.lhOffZ or 0)
    configui.setValue("th_lh_rot_pitch", p.lhRotPitch or 0)
    configui.setValue("th_lh_rot_yaw", p.lhRotYaw or 0)
    configui.setValue("th_lh_rot_roll", p.lhRotRoll or 0)
end

for _, id in ipairs({"th_fraction", "th_off_x", "th_off_y", "th_off_z"}) do
    configui.onUpdate(id, function(value)
        local p = getWeaponParams(currentWeaponID)
        if p == nil then return end
        if id == "th_fraction" then p.fraction = value
        elseif id == "th_off_x" then p.offX = value
        elseif id == "th_off_y" then p.offY = value
        elseif id == "th_off_z" then p.offZ = value end
        saveParams()
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

-- ---------------------------------------------------------------------------------------------
-- The game's own left grip (Borderlands 4 port, 2026-11-11). The flat game hangs the FPV gun on Pawn.FPVMesh at
-- socket WeaponPoint (or the visuals' OverrideAttachSocket, e.g. HvyWpn_Socket on the AR) with ZERO relative (MCP: the
-- TPV gun sits on CharacterMesh0's HvyWpn_Socket at 0/0; FPVMesh keeps animating while hidden). So l_hand_JNT relative
-- to that socket on FPVMesh = where the game holds the fore-grip, in the gun's own frame (AR: ~31 cm up the gun).
-- Measured once per attachment when the arms are settled (no montage, standing still, not aiming, steady 0.75 s) and
-- saved as params[id].gameLeft. With option th_game_left_grip the left hand's l_hand_JNT goes exactly there in both
-- hand modes, the game's finger pose is copied onto it every tick, and the grab point is that spot. A steady pose off
-- the gun (one-handed weapon) is saved as { none = true }: the grip point + offsets as before.
-- ---------------------------------------------------------------------------------------------
local GAME_LEFT_BONE = "l_hand_JNT"      -- the IK left solver's end bone too (ik_parameters.json)
local GAME_LEFT_VERSION = 1
local RTS_COMPONENT = 2
local LEFT_SETTLE_S, LEFT_STABLE_S = 1.0, 0.75
local LEFT_STABLE_CM, LEFT_STABLE_DEG = 1.0, 3.0
local LEFT_MAX_SPEED = 20.0              -- cm/s horizontal: moving / sprinting poses hold the gun differently
local LEFT_MAX_OFF_BARREL_CM, LEFT_MAX_PAST_MUZZLE_CM = 20.0, 15.0
local LEFT_MAX_NO_MUZZLE_CM = 60.0       -- no MuzzleFlashSocket: accept within this distance of the gun origin
local gameLeftActive = false             -- two-handing with the left hand on the game's grip (fingers copied)

local fnames = {}
local function fname(s)
    if fnames[s] == nil then fnames[s] = uevrUtils.fname_from_string(s) end
    return fnames[s]
end

local function logInfo(msg)
    pcall(function() uevr.params.functions.log_info("[two_handed] " .. msg) end)
end

local function unitT(component)
    return kismet_math_library:MakeTransform(component:K2_GetComponentLocation(), component:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1))
end

local function gameLeftEnabled() return configui.getValue("th_game_left_grip") ~= false end

-- the measured grip of the current attachment as a transform in the gun's frame, or nil
local function gameLeftGripT()
    if not gameLeftEnabled() or currentWeaponID == nil then return nil end
    local p = params[currentWeaponID]
    local g = p and p.gameLeft or nil
    if g == nil or g.v ~= GAME_LEFT_VERSION or g.none or g.loc == nil then return nil end
    return kismet_math_library:MakeTransform(uevrUtils.vector(g.loc.X, g.loc.Y, g.loc.Z),
        uevrUtils.rotator(g.rot.Pitch, g.rot.Yaw, g.rot.Roll), uevrUtils.vector(1, 1, 1))
end

local function updateGameLeftLabel(text)
    if text == nil then
        local p = currentWeaponID ~= nil and params[currentWeaponID] or nil
        local g = p and p.gameLeft or nil
        if not gameLeftEnabled() then text = "off"
        elseif currentWeaponID == nil then text = "-"
        elseif g == nil or g.v ~= GAME_LEFT_VERSION then text = "not measured yet (stand still, don't aim)"
        elseif g.none then text = "the game holds this weapon one-handed (grip point used)"
        else text = string.format("(%.1f %.1f %.1f) / (%.1f %.1f %.1f)", g.loc.X, g.loc.Y, g.loc.Z, g.rot.Pitch, g.rot.Yaw, g.rot.Roll) end
    end
    configui.setLabel("th_game_left_label", "Game left grip: " .. text)
end

local function isNone(name)
    if name == nil then return true end
    local ok, s = pcall(function() return name:to_string() end)
    return not ok or s == nil or s == "" or s == "None"
end

-- the FPVMesh socket the game hangs the held weapon on (same lookup as weapon_recoil.lua), cached per weapon object
local socketCache = { weapon = nil, socket = nil }
local function gunSocket(pawn, arms)
    local weapon, key = nil, nil
    pcall(function() weapon = pawn:GetCurrentWeapon() key = weapon:get_address() end)
    if key == nil then return nil end
    if key == socketCache.weapon then return socketCache.socket end
    local socket = nil
    pcall(function()
        local override = weapon.FPVCurrentVisuals.OverrideAttachSocket
        if not isNone(override) and arms:DoesSocketExist(override) then socket = override end
    end)
    if socket == nil then
        pcall(function()
            local s = pawn.PlayerEquipmentComponent.WeaponAttachSocketFPV
            if not isNone(s) then socket = s end
        end)
    end
    socketCache = { weapon = key, socket = socket }
    return socket
end

local function measureGameLeft(arms, socket, weaponMesh)
    local grip = nil
    pcall(function()
        local hand = arms:GetSocketTransform(fname(GAME_LEFT_BONE), RTS_COMPONENT)
        local sock = arms:GetSocketTransform(socket, RTS_COMPONENT)
        local rel = kismet_math_library:MakeRelativeTransform(hand, sock)
        local t, r = rel.Translation, kismet_math_library:Quat_Rotator(rel.Rotation)
        local onGun = false
        local m = nil
        if weaponMesh:DoesSocketExist(fname("MuzzleFlashSocket")) then
            m = kismet_math_library:InverseTransformLocation(unitT(weaponMesh), weaponMesh:GetSocketLocation(fname("MuzzleFlashSocket")))
        end
        local len = m ~= nil and math.sqrt(m.X * m.X + m.Y * m.Y + m.Z * m.Z) or 0
        if len >= 1.0 then
            local along = (t.X * m.X + t.Y * m.Y + t.Z * m.Z) / len
            local px, py, pz = t.X - m.X / len * along, t.Y - m.Y / len * along, t.Z - m.Z / len * along
            onGun = along >= 0 and along <= len + LEFT_MAX_PAST_MUZZLE_CM and math.sqrt(px * px + py * py + pz * pz) <= LEFT_MAX_OFF_BARREL_CM
        else
            onGun = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z) <= LEFT_MAX_NO_MUZZLE_CM
        end
        grip = { loc = { X = t.X, Y = t.Y, Z = t.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, onGun = onGun }
    end)
    return grip
end

local function angleDelta(a, b) return math.abs((a - b + 180) % 360 - 180) end
local function gripsClose(a, b)
    local dx, dy, dz = a.loc.X - b.loc.X, a.loc.Y - b.loc.Y, a.loc.Z - b.loc.Z
    return a.onGun == b.onGun and math.sqrt(dx * dx + dy * dy + dz * dz) <= LEFT_STABLE_CM
        and angleDelta(a.rot.Pitch, b.rot.Pitch) <= LEFT_STABLE_DEG and angleDelta(a.rot.Yaw, b.rot.Yaw) <= LEFT_STABLE_DEG
        and angleDelta(a.rot.Roll, b.rot.Roll) <= LEFT_STABLE_DEG
end

-- the arms are free to show the plain hold: no montage (equip / reload / melee), standing still, not aiming
local function armsSettled(pawn, arms)
    local settled = false
    pcall(function()
        local anim = arms:GetAnimInstance()
        if anim:IsAnyMontagePlaying() == true then return end
        local ads = anim.FineAimProgressNormalizedSmoothed
        if ads ~= nil and ads > 0.02 then return end
        local v = pawn:GetVelocity()
        if math.sqrt(v.X * v.X + v.Y * v.Y) > LEFT_MAX_SPEED then return end
        settled = true
    end)
    return settled
end

local leftProbe = { id = nil, since = 0, last = nil, stableSince = nil }
-- called every tick while a two-handable weapon is held and not two-handed (two-handing forces the game's ADS)
local function probeGameLeft(weaponMesh)
    if not gameLeftEnabled() or currentWeaponID == nil then return end
    local p = getWeaponParams(currentWeaponID)
    if p.gameLeft ~= nil and p.gameLeft.v == GAME_LEFT_VERSION then return end
    local now = os.clock()
    if leftProbe.id ~= currentWeaponID then leftProbe = { id = currentWeaponID, since = now, last = nil, stableSince = nil } end
    if now - leftProbe.since < LEFT_SETTLE_S then return end
    local pawn = uevr.api:get_local_pawn(0)
    local arms = nil
    pcall(function() arms = pawn.FPVMesh end)
    if not alive(arms) then return end
    local socket = gunSocket(pawn, arms)
    local grip = (socket ~= nil and armsSettled(pawn, arms)) and measureGameLeft(arms, socket, weaponMesh) or nil
    if grip == nil then leftProbe.last, leftProbe.stableSince = nil, nil return end
    if leftProbe.last ~= nil and gripsClose(grip, leftProbe.last) then
        leftProbe.stableSince = leftProbe.stableSince or now
    else
        leftProbe.stableSince = nil
    end
    leftProbe.last = grip
    if leftProbe.stableSince == nil or now - leftProbe.stableSince < LEFT_STABLE_S then return end
    if grip.onGun then
        p.gameLeft = { loc = grip.loc, rot = grip.rot, v = GAME_LEFT_VERSION }
        logInfo(string.format("game LEFT grip %s: (%.1f %.1f %.1f) / (%.1f %.1f %.1f)", tostring(currentWeaponID),
            grip.loc.X, grip.loc.Y, grip.loc.Z, grip.rot.Pitch, grip.rot.Yaw, grip.rot.Roll))
    else
        p.gameLeft = { none = true, v = GAME_LEFT_VERSION }
        logInfo(string.format("game LEFT grip %s: the game's left hand is not on the gun (%.1f %.1f %.1f) - grip point used",
            tostring(currentWeaponID), grip.loc.X, grip.loc.Y, grip.loc.Z))
    end
    leftProbe = { id = nil, since = 0, last = nil, stableSince = nil }
    saveParams()
    updateGameLeftLabel()
end

configui.onUpdate("th_game_left_remeasure", function(value)
    uevrUtils.setTimeout(1, function() -- draw thread -> game thread
        local p = currentWeaponID ~= nil and params[currentWeaponID] or nil
        if p == nil then updateGameLeftLabel("no weapon") return end
        p.gameLeft = nil
        saveParams()
        leftProbe = { id = nil, since = 0, last = nil, stableSince = nil }
        updateGameLeftLabel("re-measuring - stand still, don't aim")
    end)
end)
configui.onUpdate("th_game_left_grip", function(value) updateGameLeftLabel() end)

-- World-space fore-grip point for the current weapon mesh (the game's left grip when measured)
local function getGripPoint(weaponMesh)
    local gameT = gameLeftGripT()
    if gameT ~= nil then
        return kismet_math_library:TransformLocation(unitT(weaponMesh), gameT.Translation)
    end
    local p = getWeaponParams(currentWeaponID) or { fraction = 0.55, offX = 0, offY = 0, offZ = 0 }
    local origin = weaponMesh:K2_GetComponentLocation()
    local fwd = weaponMesh:GetForwardVector()
    local right = weaponMesh:GetRightVector()
    local up = weaponMesh:GetUpVector()
    local muzzle = weaponMesh:GetSocketLocation(uevrUtils.fname_from_string("MuzzleFlashSocket"))
    local dx, dy, dz = muzzle.X - origin.X, muzzle.Y - origin.Y, muzzle.Z - origin.Z
    local barrelLen = math.sqrt(dx * dx + dy * dy + dz * dz)
    if barrelLen < 1.0 then barrelLen = 40.0 end -- socket missing: assume a 40 cm weapon
    local along = barrelLen * (p.fraction or 0.55) + (p.offX or 0)
    local oy, oz = (p.offY or 0), (p.offZ or 0)
    return uevrUtils.vector(
        origin.X + fwd.X * along + right.X * oy + up.X * oz,
        origin.Y + fwd.Y * along + right.Y * oy + up.Y * oz,
        origin.Z + fwd.Z * along + right.Z * oy + up.Z * oz)
end

local function distance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function updateMarker(weaponMesh, point)
    local show = configui.getValue("th_show_marker") == true and weaponMesh ~= nil and point ~= nil
    if show then
        if not alive(marker) then
            marker = nil
            pcall(function()
                marker = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/EngineMeshes/Sphere.Sphere", { visible = true, collisionEnabled = false })
                if marker ~= nil then
                    uevrUtils.set_component_relative_transform(marker, nil, nil, { X = 0.02, Y = 0.02, Z = 0.02 })
                end
            end)
        end
        if alive(marker) then
            pcall(function() marker:K2_SetWorldLocation(point, false, getHitResult(), false) end)
        end
    elseif alive(marker) then
        pcall(function() uevrUtils.destroyComponent(marker, true, true) end)
        marker = nil
    end
end

local function snapshotHand(hand)
    local pmc = hands.getHandComponent(hand)
    if not alive(pmc) then return nil end
    local ok, snap = pcall(function()
        return {
            parent = pmc.AttachParent,
            socket = (pmc.AttachSocketName and pmc.AttachSocketName:to_string()) or "",
            loc = { X = pmc.RelativeLocation.X, Y = pmc.RelativeLocation.Y, Z = pmc.RelativeLocation.Z },
            rot = { Pitch = pmc.RelativeRotation.Pitch, Yaw = pmc.RelativeRotation.Yaw, Roll = pmc.RelativeRotation.Roll },
        }
    end)
    if ok then snapshots[hand] = snap end
    return pmc
end

local function restoreHand(hand)
    local pmc = hands.getHandComponent(hand)
    local snap = snapshots[hand]
    snapshots[hand] = nil
    if not alive(pmc) then return end
    pcall(function()
        if snap ~= nil and alive(snap.parent) then
            pmc:K2_AttachTo(snap.parent, uevrUtils.fname_from_string(snap.socket or ""), 0, false)
            uevrUtils.set_component_relative_transform(pmc, snap.loc, snap.rot, { X = 1, Y = 1, Z = 1 })
        else
            -- fallback: back onto the controller
            pmc:DetachFromParent(false, false)
            controllers.attachComponentToController(hand, pmc)
        end
    end)
end

local function parentHandToWeapon(hand, weaponMesh, snapToPoint)
    local pmc = snapshotHand(hand)
    if not alive(pmc) then return end
    pcall(function()
        -- 1 = KeepWorldPosition: the hand stays exactly where the controller put it at grab time
        pmc:K2_AttachTo(weaponMesh, uevrUtils.fname_from_string(""), 1, false)
        if snapToPoint ~= nil then
            pmc:K2_SetWorldLocation(snapToPoint, false, getHitResult(), false)
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Left hand pose while two-handing (captured from the game's own arm mesh, per attachment)
-- ---------------------------------------------------------------------------------------------
local leftTargetBone = nil
local function getLeftTargetBone()
    if leftTargetBone == nil then
        leftTargetBone = "l_wrist_JNT"
        pcall(function()
            local cfg = json.load_file("hands_parameters.json")
            local profiles = cfg and cfg["profiles"]
            if profiles ~= nil then
                for _, profile in pairs(profiles) do
                    for _, meshDef in pairs(profile) do
                        if type(meshDef) == "table" and meshDef["Left"] ~= nil and meshDef["Left"]["Name"] ~= nil and meshDef["Left"]["Name"] ~= "" then
                            leftTargetBone = meshDef["Left"]["Name"]
                            return
                        end
                    end
                end
            end
        end)
    end
    return leftTargetBone
end

local function getLeftPose()
    local p = currentWeaponID ~= nil and params[currentWeaponID] or nil
    return p and p.leftPose or nil
end

local function updatePoseLabel()
    local pose = getLeftPose()
    local n = 0
    if pose ~= nil then for _ in pairs(pose) do n = n + 1 end end
    configui.setLabel("th_pose_label", pose ~= nil and ("Pose: " .. n .. " bones captured") or "Pose: none (uses the weapon's left grip pose)")
end

-- The mesh that carries the left hand's finger bones: the glove copy in glove mode, the IK rig mesh in
-- IK mode (Hands Mode panel). Both are PoseableMeshComponents copied from Pawn.FPVMesh, so the captured
-- bone-space rotations apply to either.
local ik = require('libs/ik')
local function leftHandMesh()
    local pmc = hands.getHandComponent(Handed.Left)
    if alive(pmc) then return pmc end
    if _G.getHandsMode ~= nil and _G.getHandsMode() == 2 then
        local rigMesh = ik.getCurrentMesh(1)
        if alive(rigMesh) then return rigMesh end
    end
    return nil
end

-- Apply the captured pose to the left hand (bone-space rotations, like the Cronos LH_GRIP_POSE)
local function applyLeftPose()
    if not active then return end
    if configui.getValue("th_apply_pose") == false then return end
    if gameLeftActive then return end -- the game's own finger pose is copied every tick (see the finger copy below)
    local pose = getLeftPose()
    local mesh = leftHandMesh()
    if pose == nil or not alive(mesh) then return end
    pcall(function() animation.initializeBones(mesh, pose) end)
end

local function scheduleLeftPose()
    for _, delayMs in ipairs({1, 150, 400}) do
        uevrUtils.setTimeout(delayMs, applyLeftPose)
    end
end

-- Runs on the game thread. Copies the game's FPV arm mesh into a temporary poseable mesh (so we
-- read the CURRENT animated pose - e.g. the left hand on the fore-grip), records the bone-space
-- rotation of every bone below the left cut-off bone, and stores it for the current attachment.
local function captureLeftPose()
    if currentWeaponID == nil then status("capture: no weapon attached") return end
    local source = pawnModule.getArmsMesh()
    if not alive(source) then status("capture: arms mesh not found") return end
    local temp = uevrUtils.createPoseableMeshFromSkeletalMesh(source, { useDefaultPose = false, showDebug = false })
    if temp == nil then status("capture: could not copy arms mesh") return end
    local pose = {}
    local count = 0
    local ok, err = pcall(function()
        local bones = animation.getDescendantBones(temp, getLeftTargetBone(), false)
        for _, boneName in ipairs(bones or {}) do
            local rot = animation.getBoneSpaceLocalTransform(temp, uevrUtils.fname_from_string(boneName), 0)
            if rot ~= nil then
                pose[boneName] = { rotation = { rot.Pitch, rot.Yaw, rot.Roll } }
                count = count + 1
            end
        end
    end)
    pcall(function() uevrUtils.destroyComponent(temp, true, true) end)
    if not ok then status("capture failed: " .. tostring(err)) return end
    if count == 0 then status("capture: no bones found below " .. tostring(getLeftTargetBone())) return end
    getWeaponParams(currentWeaponID).leftPose = pose
    saveParams()
    updatePoseLabel()
    status("captured " .. count .. " bones for " .. tostring(currentWeaponID))
    scheduleLeftPose()
end

configui.onUpdate("th_capture_pose", function(value)
    -- button callbacks run on the draw thread; the capture spawns a temp component -> defer
    uevrUtils.setTimeout(1, captureLeftPose)
end)

configui.onUpdate("th_clear_pose", function(value)
    local p = currentWeaponID ~= nil and params[currentWeaponID] or nil
    if p ~= nil then p.leftPose = nil; saveParams() end
    updatePoseLabel()
    if active then
        -- fall back to the weapon's left grip pose from the hands wizard
        local animName = attachments.getCurrentGripAnimation(Handed.Right)
        pcall(function() hands.setHoldingAttachment(Handed.Left, (type(animName) == "string" and animName) or true) end)
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Left hand placement offsets while two-handing (relative to where the hand landed at grab time)
-- ---------------------------------------------------------------------------------------------
local leftBaseRel = nil   -- { loc={X,Y,Z}, rot={Pitch,Yaw,Roll} } captured right after parenting

-- forward declarations: the lhOff/lhRot slider handlers below re-issue the IK accessory attach, and the
-- IK helpers are defined further down (after the glove helpers they mirror)
local ikBase = nil
local applyIKAccessory = nil

-- Hands mode, game grip: the glove (a child of the gun) placed so its l_hand_JNT bone lands exactly on the game's grip:
-- relative = bone^-1 * grip, both in the gun's frame. The bone is read in the glove's component space each call (the
-- left grip pose animates l_hand_JNT against the wrist), so this runs every tick while held. Engine setter: the world
-- transform updates at once.
local function applyGameLeftHands(pmc, gripT)
    local bone = pmc:GetSocketTransform(fname(GAME_LEFT_BONE), RTS_COMPONENT)
    local rel = kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(bone), gripT)
    local t = rel.Translation
    pmc:K2_SetRelativeLocationAndRotation(uevrUtils.vector(t.X, t.Y, t.Z), kismet_math_library:Quat_Rotator(rel.Rotation),
        false, getHitResult(), true)
end

local function applyLeftOffset()
    if not active or leftBaseRel == nil then return end
    local pmc = hands.getHandComponent(Handed.Left)
    if not alive(pmc) then return end
    if leftBaseRel.gameT ~= nil then
        -- the game's grip is exact: the per-weapon LH offsets belong to the grip-point placement
        local ok, err = pcall(applyGameLeftHands, pmc, leftBaseRel.gameT)
        if not ok then print("[two_handed] game left grip: " .. tostring(err)) end
        return
    end
    local p = getWeaponParams(currentWeaponID) or {}
    pcall(function()
        uevrUtils.set_component_relative_transform(pmc,
            { X = leftBaseRel.loc.X + (p.lhOffX or 0), Y = leftBaseRel.loc.Y + (p.lhOffY or 0), Z = leftBaseRel.loc.Z + (p.lhOffZ or 0) },
            { Pitch = leftBaseRel.rot.Pitch + (p.lhRotPitch or 0), Yaw = leftBaseRel.rot.Yaw + (p.lhRotYaw or 0), Roll = leftBaseRel.rot.Roll + (p.lhRotRoll or 0) },
            { X = 1, Y = 1, Z = 1 })
    end)
end

local function captureLeftBase(gameT)
    leftBaseRel = nil
    local pmc = hands.getHandComponent(Handed.Left)
    if not alive(pmc) then return end
    pcall(function()
        leftBaseRel = {
            loc = { X = pmc.RelativeLocation.X, Y = pmc.RelativeLocation.Y, Z = pmc.RelativeLocation.Z },
            rot = { Pitch = pmc.RelativeRotation.Pitch, Yaw = pmc.RelativeRotation.Yaw, Roll = pmc.RelativeRotation.Roll },
            gameT = gameT, -- the game's left grip (gun frame), or nil
        }
    end)
end

for _, id in ipairs({"th_lh_off_x", "th_lh_off_y", "th_lh_off_z", "th_lh_rot_pitch", "th_lh_rot_yaw", "th_lh_rot_roll"}) do
    configui.onUpdate(id, function(value)
        local p = getWeaponParams(currentWeaponID)
        if p == nil then return end
        if id == "th_lh_off_x" then p.lhOffX = value
        elseif id == "th_lh_off_y" then p.lhOffY = value
        elseif id == "th_lh_off_z" then p.lhOffZ = value
        elseif id == "th_lh_rot_pitch" then p.lhRotPitch = value
        elseif id == "th_lh_rot_yaw" then p.lhRotYaw = value
        elseif id == "th_lh_rot_roll" then p.lhRotRoll = value end
        saveParams()
        uevrUtils.setTimeout(1, function()          -- draw thread -> game thread
            applyLeftOffset()                        -- glove path (no-op without a glove component)
            if ikBase ~= nil then applyIKAccessory() end -- IK path: re-issue the attach with the new offsets
        end)
    end)
end

-- ---------------------------------------------------------------------------------------------
-- IK mode (Hands Mode panel = "IK arms"): there is no glove component to parent, so the left hand's IK
-- TARGET is redirected instead. libs/ik.lua listens for "on_accessory_attach"(hand, parentComponent,
-- socketName, attachType, localOffset, localRot) and then solves that hand towards
-- parent socket + offset (rotated into the parent's frame) with rotation = parent rot composed with
-- localRot, until "on_accessory_detach"(hand). We attach to the weapon mesh root ("" socket) with the
-- grip point converted to weapon-local space, and the controller's grab-time rotation relative to the
-- weapon so the hand keeps its grip orientation while the gun pivots. The per-weapon lhOff/lhRot
-- sliders are added on top (weapon-local), same as the glove path.
-- ---------------------------------------------------------------------------------------------
local function ikMode()
    return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end
local ikAccessoryAttached = false
-- ikBase (declared above): { weaponMesh, loc = {X,Y,Z}, rot = {Pitch,Yaw,Roll} } weapon-local, captured at grab

local function weaponLocalOffset(weaponMesh, worldPoint, worldRot)
    local loc = weaponMesh:K2_GetComponentLocation()
    local rot = weaponMesh:K2_GetComponentRotation()
    local scale = weaponMesh.K2_GetComponentScale ~= nil and weaponMesh:K2_GetComponentScale() or uevrUtils.vector(1, 1, 1)
    local xf = kismet_math_library:MakeTransform(loc, rot, scale)
    local lp = kismet_math_library:InverseTransformLocation(xf, worldPoint)
    local lr = worldRot ~= nil and kismet_math_library:InverseTransformRotation(xf, worldRot) or nil
    return lp, lr
end

applyIKAccessory = function()
    if not active or ikBase == nil or not alive(ikBase.weaponMesh) then return end
    local p = getWeaponParams(currentWeaponID) or {}
    -- the game's grip is exact: the grip-point trims do not apply to it
    if ikBase.game then p = {} end
    pcall(function()
        uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Left, ikBase.weaponMesh, "", 0,
            { X = ikBase.loc.X + (p.lhOffX or 0), Y = ikBase.loc.Y + (p.lhOffY or 0), Z = ikBase.loc.Z + (p.lhOffZ or 0) },
            { Pitch = ikBase.rot.Pitch + (p.lhRotPitch or 0), Yaw = ikBase.rot.Yaw + (p.lhRotYaw or 0), Roll = ikBase.rot.Roll + (p.lhRotRoll or 0) })
        ikAccessoryAttached = true
    end)
end

-- the left IK solver's end-bone offset (data/ik_parameters.json, the solver with end_control_type 0 = left controller):
-- ik.lua puts the end bone at target * (end_bone_offset, end_bone_rotation)
local function leftSolverOffsetT()
    local offT = nil
    pcall(function()
        local cfg = json.load_file("ik_parameters.json")
        local profileName = cfg and cfg["_profileState"] and cfg["_profileState"]["currentEditingProfile"] or "default"
        local profile = cfg and (cfg[profileName] or cfg["default"])
        for _, solver in pairs(profile and profile["solvers"] or {}) do
            if solver["end_control_type"] == 0 and solver["end_bone"] == GAME_LEFT_BONE then
                local o, r = solver["end_bone_offset"] or { 0, 0, 0 }, solver["end_bone_rotation"] or { 0, 0, 0 }
                offT = kismet_math_library:MakeTransform(uevrUtils.vector(o[1], o[2], o[3]), uevrUtils.rotator(r[1], r[2], r[3]), uevrUtils.vector(1, 1, 1))
            end
        end
    end)
    return offT
end

local function attachIKLeftHand(weaponMesh, gripPoint)
    ikBase = nil
    -- the game's left grip: target on the gun = offset^-1 * grip, so the solver's end bone (l_hand_JNT) lands on it
    local gameT = gameLeftGripT()
    local offT = gameT ~= nil and leftSolverOffsetT() or nil
    if gameT ~= nil and offT ~= nil then
        local okGame = pcall(function()
            local rel = kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(offT), gameT)
            local t, r = rel.Translation, kismet_math_library:Quat_Rotator(rel.Rotation)
            ikBase = { weaponMesh = weaponMesh, game = true,
                loc = { X = t.X, Y = t.Y, Z = t.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
        end)
        if okGame and ikBase ~= nil then applyIKAccessory() return end
        ikBase = nil
    end
    local ok, err = pcall(function()
        local leftCtrl = controllers.getController(0, true)
        local ctrlLoc = alive(leftCtrl) and leftCtrl:K2_GetComponentLocation() or nil
        local ctrlRot = alive(leftCtrl) and leftCtrl:K2_GetComponentRotation() or nil
        local target = (configui.getValue("th_snap_left_hand") ~= false and gripPoint) or ctrlLoc or gripPoint
        if target == nil then return end
        local lp, lr = weaponLocalOffset(weaponMesh, target, ctrlRot)
        ikBase = {
            weaponMesh = weaponMesh,
            loc = { X = lp.X, Y = lp.Y, Z = lp.Z },
            rot = lr ~= nil and { Pitch = lr.Pitch, Yaw = lr.Yaw, Roll = lr.Roll } or { Pitch = 0, Yaw = 0, Roll = 0 },
        }
    end)
    if not ok then print("[two_handed] IK attach failed: " .. tostring(err)) return end
    applyIKAccessory()
end

local function detachIKLeftHand()
    ikBase = nil
    if not ikAccessoryAttached then return end
    ikAccessoryAttached = false
    pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end)
end

-- The right IK hand turns with the gun as well (Hellraiser's method): its IK target is attached to the gun at the right
-- controller's pose in the gun's local space at grab time (gun not pivoted yet). libs/ik.lua reads that as a virtual
-- controller - the real one swung about the grip with the gun - and applies the solver's end-bone offsets to it as
-- usual, so the hand stays on the grip. No feedback loop: UObjectHook places the gun from the real controller.
-- The target follows the gun's pose at solve time, which includes the weapon kick (weapon_recoil.lua then leaves the
-- right solver alone while two-handing).
local ikRightAttached = false

local function attachIKRightHand(weaponMesh)
    local ok, err = pcall(function()
        local rightCtrl = controllers.getController(1, true)
        if not alive(rightCtrl) then return end
        local one = uevrUtils.vector(1, 1, 1)
        local ctrlT = kismet_math_library:MakeTransform(rightCtrl:K2_GetComponentLocation(), rightCtrl:K2_GetComponentRotation(), one)
        local gunT = kismet_math_library:MakeTransform(weaponMesh:K2_GetComponentLocation(), weaponMesh:K2_GetComponentRotation(), one)
        local rel = kismet_math_library:MakeRelativeTransform(ctrlT, gunT)
        local t, r = rel.Translation, kismet_math_library:Quat_Rotator(rel.Rotation)
        uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Right, weaponMesh, "", 0,
            { X = t.X, Y = t.Y, Z = t.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll })
        ikRightAttached = true
    end)
    if not ok then print("[two_handed] IK right attach failed: " .. tostring(err)) end
end

local function detachIKRightHand()
    if not ikRightAttached then return end
    ikRightAttached = false
    pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Right) end)
end
_G.isTwoHandingIKRightLocked = function() return ikRightAttached end

-- ---------------------------------------------------------------------------------------------
-- Game finger pose while on the game's grip (BL4 port): every bone BELOW l_hand_JNT (fingers + l_hand_Att / shield
-- attach bones) is copied from the game's FPVMesh onto the left hand - the glove in Hands mode, the IK rig in IK mode -
-- relative to l_hand_JNT (animation.copyDescendantTransforms), in the post-engine tick after the hands lib's own finger
-- animation. Poseable meshes keep bone-local transforms, so the IK solve moving l_hand_JNT carries the fingers along.
-- On release the target's bones below l_hand_JNT get back the local transforms they had before the first copy (the
-- copy also writes bone locations, which the hand-pose lerps never reset), then the hands lib re-poses the hand.
-- ---------------------------------------------------------------------------------------------
local fingerCopy = { active = false, target = nil, snapshot = nil }

local function snapshotLeftFingers(target)
    local saved = {}
    for _, name in ipairs(animation.getDescendantBones(target, GAME_LEFT_BONE, false) or {}) do
        local f = fname(name)
        local rot, loc, scale = animation.getBoneSpaceLocalTransform(target, f)
        if rot ~= nil and loc ~= nil and scale ~= nil then
            table.insert(saved, { fname = f, rot = uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll),
                loc = uevrUtils.vector(loc.X, loc.Y, loc.Z), scale = uevrUtils.vector(scale.X, scale.Y, scale.Z) })
        end
    end
    return saved
end

local function releaseFingerCopy()
    if not fingerCopy.active then fingerCopy.target, fingerCopy.snapshot = nil, nil return end
    local target, saved = fingerCopy.target, fingerCopy.snapshot
    fingerCopy = { active = false, target = nil, snapshot = nil }
    local ok, err = pcall(function()
        if not alive(target) then return end
        for _, b in ipairs(saved or {}) do
            animation.setBoneSpaceLocalTransform(target, b.fname, kismet_math_library:MakeTransform(b.loc, b.rot, b.scale))
        end
    end)
    if not ok then print("[two_handed] finger restore: " .. tostring(err)) end
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    if not (active and gameLeftActive) then
        if fingerCopy.active then releaseFingerCopy() end
        return
    end
    local ok, err = pcall(function()
        local target = leftHandMesh()
        if fingerCopy.active and fingerCopy.target ~= target then releaseFingerCopy() end -- hand mode switched / rebuilt
        local pawn = uevr.api:get_local_pawn(0)
        local arms = pawn ~= nil and pawn.FPVMesh or nil
        if not alive(target) or not alive(arms) then return end
        if not fingerCopy.active then
            fingerCopy.snapshot = snapshotLeftFingers(target)
            fingerCopy.target = target
        end
        if animation.copyDescendantTransforms(arms, target, GAME_LEFT_BONE, false) then fingerCopy.active = true end
    end)
    if not ok then print("[two_handed] finger copy: " .. tostring(err)) fingerCopy.active = false end
end)

-- ---------------------------------------------------------------------------------------------
-- Activation
-- ---------------------------------------------------------------------------------------------
local function activate(weaponMesh, gripPoint)
    if active then return end
    -- the right glove's rest is snapshotted below: never a kicked one (weapon_recoil.lua)
    if _G.ow2RecoilRestoreHand ~= nil then pcall(_G.ow2RecoilRestoreHand) end
    active = true
    local animName = attachments.getCurrentGripAnimation(Handed.Right)
    local gameT = gameLeftGripT()
    if ikMode() then
        attachIKRightHand(weaponMesh) -- first: the gun is still un-pivoted this view
        attachIKLeftHand(weaponMesh, gripPoint)
        gameLeftActive = ikBase ~= nil and ikBase.game == true
    else
        parentHandToWeapon(Handed.Right, weaponMesh, nil)
        parentHandToWeapon(Handed.Left, weaponMesh, gameT == nil and configui.getValue("th_snap_left_hand") ~= false and gripPoint or nil)
        captureLeftBase(gameT)
        applyLeftOffset()
        gameLeftActive = leftBaseRel ~= nil and leftBaseRel.gameT ~= nil
    end
    -- left hand takes the weapon's left grip pose (left_grip_weapon_<animation>) and stays in it: the left
    -- trigger is the grab button, so the input-driven trigger lerp for that hand is locked while held
    pcall(function() hands.setHoldingAttachment(Handed.Left, (type(animName) == "string" and animName) or true) end)
    pcall(function() if hands.setInputLocked then hands.setInputLocked(Handed.Left, true) end end)
    _G.isTwoHandingActive = true
    status(gameLeftActive and "two-handing (game's left grip)" or "two-handing")
    scheduleLeftPose()
end

-- ---------------------------------------------------------------------------------------------
-- Pivot application (every view)
-- ---------------------------------------------------------------------------------------------
-- UObjectHook re-places the gun from the right controller for EACH stereo view (found on Hellraiser 2026-10-09 with a
-- probe: the pivot written after view 0 was already undone when view 1 was calculated), so a pivot applied once per
-- frame never reached the renderer. The pivot is re-applied after every view's post-stereo; the last write before the
-- frame is rendered is ours. The turret rotation starts from the gun's freshly reset pose each time (idempotent).
local pivotArgs = nil -- { weaponMesh, rightHand, leftHand } while two-handing

local function applyPivot()
    local a = pivotArgs
    if a == nil or not alive(a.weaponMesh) then return end
    twoHandedAiming.applyTwoHandedRotation(a.weaponMesh, a.rightHand, a.leftHand)
end

local function deactivate(reason)
    if not active then return end
    active = false
    gameLeftActive = false
    releaseFingerCopy() -- before the hands lib re-poses the left hand below
    pivotArgs = nil
    leftBaseRel = nil
    detachIKLeftHand()
    detachIKRightHand()
    restoreHand(Handed.Left)
    restoreHand(Handed.Right)
    pcall(function() if hands.setInputLocked then hands.setInputLocked(Handed.Left, false) end end)
    pcall(function() hands.setHoldingAttachment(Handed.Left, nil) end)
    _G.isTwoHandingActive = false
    status("idle (" .. tostring(reason) .. ")")
end

-- suppress the left hand's mesh-driven animation while we own it
hands.registerIsAnimatingFromMeshCallback(function(hand)
    if hand == Handed.Left and active then return false end
    return nil
end)

-- weapon (attachment) changed on the right hand -> release before the mesh goes away
uevrUtils.registerUEVRCallback("attachment_grip_changed", function(id, gripHand, attachment)
    if gripHand == Handed.Right then
        deactivate("weapon changed")
        currentWeaponID = (id ~= nil and id ~= "") and id or nil
        configui.setLabel("th_weapon_label", "Weapon: " .. tostring(currentWeaponID or "none"))
        loadWeaponParamsToUI(currentWeaponID)
        updatePoseLabel()
        updateGameLeftLabel()
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    active = false
    gameLeftActive = false
    fingerCopy = { active = false, target = nil, snapshot = nil } -- the hand / rig goes with the old world
    socketCache = { weapon = nil, socket = nil }
    leftProbe = { id = nil, since = 0, last = nil, stableSince = nil }
    -- the IK accessory table in libs/ik.lua survives the rig rebuild: release the left hand or the new
    -- rig would keep targeting the old world's weapon mesh
    if ikAccessoryAttached then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end) end
    ikAccessoryAttached = false
    if ikRightAttached then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Right) end) end
    ikRightAttached = false
    ikBase = nil
    pivotArgs = nil
    snapshots = {}
    pcall(function() if hands.setInputLocked then hands.setInputLocked(Handed.Left, false) end end)
    marker = nil
    currentWeaponID = nil
    _G.isTwoHandingActive = false
end)

-- ---------------------------------------------------------------------------------------------
-- Input: track the raw left grip, optionally hide it from the game while two-handing
-- ---------------------------------------------------------------------------------------------
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 then return end
    local useTrigger = configui.getValue("th_grab_button") == 2
    if useTrigger then
        leftGripDown = (state.Gamepad.bLeftTrigger or 0) > 100
    else
        leftGripDown = uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
    end
    -- any left button edge while two-handing triggers hand-animation lerps: re-assert our pose after them
    local leftButtons = (leftGripDown and 1 or 0) + (uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_LEFT_SHOULDER) and 2 or 0) + (((state.Gamepad.bLeftTrigger or 0) > 100) and 4 or 0)
    if active and leftButtons ~= lastLeftButtons then scheduleLeftPose() end
    lastLeftButtons = leftButtons
    if active and configui.getValue("th_suppress_left_grip") ~= false then
        if useTrigger then
            state.Gamepad.bLeftTrigger = 0
        else
            uevrUtils.unpressButton(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
        end
    end
end, 5) -- after hands_animation (10) so the left hand still animates as "grip held"; before remap (0) and the game

-- ADS while two-handing: the game's aim ("fine aim") is the left trigger. Held for the game while the gun is two-handed
-- (tighter spread, ADS pose; the zoom is removed by controls.lua "Disable ADS zoom"). Priority 0.5: after controls.lua's
-- grip/trigger swap (1) so this is what the game finally sees as LT, before remap (0).
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    if active and configui.getValue("th_ads") ~= false then
        state.Gamepad.bLeftTrigger = 255
    end
end, 0.5)

-- ---------------------------------------------------------------------------------------------
-- Per-tick body (runs once per tick from the post-stereo callback, where controller and
-- weapon transforms are valid regardless of render mode)
-- ---------------------------------------------------------------------------------------------
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    ranThisTick = false
end)

local function tick()
    if configui.getValue("th_enabled") == false then
        if active then deactivate("disabled") end
        updateMarker(nil, nil)
        return
    end

    local weaponMesh = attachments.getCurrentGrippedAttachment(Handed.Right)
    local twoHanded = alive(weaponMesh) and attachments.isActiveAttachmentTwoHanded(Handed.Right) == true
    if currentWeaponID == nil and alive(weaponMesh) then
        -- script loaded with a weapon already attached: no grip-changed event yet
        local id = attachments.getActiveAttachmentID(Handed.Right)
        if id ~= nil and id ~= "" then
            currentWeaponID = id
            configui.setLabel("th_weapon_label", "Weapon: " .. tostring(id))
            loadWeaponParamsToUI(id)
            updatePoseLabel()
            updateGameLeftLabel()
        end
    end
    if not twoHanded then
        if active then deactivate("not two-handed") end
        updateMarker(nil, nil)
        return
    end

    local rightHand = controllers.getController(1, true)
    local leftHand = controllers.getController(0, true)
    if not alive(rightHand) or not alive(leftHand) then return end

    local ok, gripPoint = pcall(getGripPoint, weaponMesh)
    if not ok or gripPoint == nil then return end
    updateMarker(weaponMesh, gripPoint)

    local leftPos = leftHand:K2_GetComponentLocation()
    local dist = distance(leftPos, gripPoint)
    local force = configui.getValue("th_force") == true

    if not active then
        -- learn the game's left grip for this weapon while it is held one-handed (two-handing forces the game's ADS)
        local okProbe, errProbe = pcall(probeGameLeft, weaponMesh)
        if not okProbe then print("[two_handed] left grip probe: " .. tostring(errProbe)) end
        if force or (leftGripDown and dist <= (configui.getValue("th_grab_radius") or 14)) then
            activate(weaponMesh, gripPoint)
        else
            status(string.format("ready (%.0f cm from grip)", dist))
        end
    else
        local release = false
        if not force then
            if not leftGripDown then release = true end
            if dist > (configui.getValue("th_release_radius") or 35) then release = true end
        end
        if release then
            deactivate(leftGripDown and "too far" or "grip released")
        else
            pivotArgs = { weaponMesh = weaponMesh, rightHand = rightHand, leftHand = leftHand }
            applyPivot()
            -- Hands mode on the game's grip: keep l_hand_JNT on it as the left grip pose animates the hand bone
            if leftBaseRel ~= nil and leftBaseRel.gameT ~= nil then applyLeftOffset() end
            -- safety net: re-assert the captured pose once a second (hand animation lerps can overwrite it)
            poseReapplyTimer = (poseReapplyTimer or 0) + 1
            if poseReapplyTimer >= 60 then poseReapplyTimer = 0; applyLeftPose() end
        end
    end
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not vr.is_hmd_active() then return end
    if ranThisTick then
        -- later views this frame: UObjectHook has re-placed the gun again, re-apply the pivot (see applyPivot)
        if active and pivotArgs ~= nil then
            local ok, err = pcall(applyPivot)
            if not ok then print("[two_handed] pivot: " .. tostring(err)) end
        end
        return
    end
    ranThisTick = true
    local ok, err = pcall(tick)
    if not ok then print("[two_handed] " .. tostring(err)) end
end)

print("[two_handed] loaded")
