-- Weapon kick for The Outer Worlds 2, driven by the game's own animation (2026-11-01, port of Hellraiser's
-- weapon_recoil.lua / Borderlands 4's bl4_vr_recoil.lua).
--
-- The game hangs the FPV weapon mesh on the first-person arms (Pawn.FPVMesh socket PlayerEquipment.WeaponAttachSocketFPV
-- = "WeaponPoint", or the weapon visuals' OverrideAttachSocket when the arms have that socket) and the shot kick lives in
-- that mesh's animation; the VR gun no longer hangs there (weaponhook.lua moved it onto the controller hook). FPVMesh keeps
-- animating while hidden (render-pass flags + hidden arm bones only, VisibilityBasedAnimTickOption 0 = always tick pose -
-- MCP 2026-11-01), so:
--
--   * every frame the socket is read in FPVMesh COMPONENT space (immune to the mesh's own movement / view pitch);
--   * while the fire button is held, plus a short tail for the recovery, the socket's change since the last frame
--     before firing (baseline frozen at the trigger press) is taken in the socket's own frame = the gun's frame;
--   * that kick is applied to the VR gun. Unlike Hellraiser the gun rides UObjectHook on the raw controller in EVERY mode
--     and is re-placed for every stereo view, so the gun part is the same everywhere: after each view's post-stereo
--     (priority below two_handed.lua's pivot, above ik_weapon_sync.lua's rig-relative draw) gun' = kick * gun.
--     The hand holding it follows once per frame:
--       Hands mode  - the right glove (a child of the controller): hand' = G^-1 * kick * G * hand (G = the gun relative
--                     to the hand this frame);
--       IK mode     - the right-hand IK target (controller space) via a runtime solver override, the saved values put
--                     back at the end: target' = rel^-1 * kick * rel * target (rel = the gun relative to the target);
--       two-handing - glove mode: both gloves are parented to the gun and follow it; IK mode: both IK hand targets are
--                     attached to the gun (two_handed.lua accessories) and follow it, so the solver is left alone.
--
-- Ranged weapons only. Anything bigger than a kick (reload / equip / melee bash played while the trigger is held) is not
-- recoil: past the max distance / angle the kick is dropped until the trigger is released. OW2AimFix.dll reads the
-- visible barrel, so the kick also climbs the shots during automatic fire.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local hands = require('libs/hands')
local attachments = require('libs/attachments')
local controllers = require('libs/controllers')
local ik = require('libs/ik')

local RTS_COMPONENT = 2
local TRIGGER_THRESHOLD = 64 -- of 255
local KICK_PRIORITY = -500   -- post stereo: after two_handed.lua's pivot (0), before ik_weapon_sync.lua (-1000)

_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 2.5, label = "Weapon Recoil", layout = {
    { widgetType = "checkbox", id = "ow2_recoil_enabled", label = "Weapon kick (from the game's arm animation)", initialValue = true },
    { widgetType = "slider_float", id = "ow2_recoil_strength_loc", label = "Kick distance strength", initialValue = 1.0, range = { 0.0, 3.0 } },
    { widgetType = "slider_float", id = "ow2_recoil_strength_rot", label = "Kick rotation strength", initialValue = 1.0, range = { 0.0, 3.0 } },
    { widgetType = "checkbox", id = "ow2_recoil_two_handed", label = "Weapon kick while two-handing", initialValue = true },
    { widgetType = "slider_float", id = "ow2_recoil_tail", label = "Recovery time after release (s)", initialValue = 0.35, range = { 0.05, 1.5 } },
    { widgetType = "slider_float", id = "ow2_recoil_max_cm", label = "Ignore motions larger than (cm)", initialValue = 12.0, range = { 2.0, 40.0 } },
    { widgetType = "slider_float", id = "ow2_recoil_max_deg", label = "Ignore rotations larger than (deg)", initialValue = 25.0, range = { 2.0, 90.0 } },
    { widgetType = "text", id = "ow2_recoil_status", label = "Last burst: -" },
}})

local function value(id, default)
    local v = configui.getValue(id)
    if v == nil then return default end
    return v
end

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

local function isIKMode()
    return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end

-- fire button = right trigger (read after UEVR mapped the VR controller into the gamepad state)
local triggerHeld = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    triggerHeld = state.Gamepad.bRightTrigger >= TRIGGER_THRESHOLD
end)

local function makeT(p)
    return kismet_math_library:MakeTransform(uevrUtils.vector(p.loc.X, p.loc.Y, p.loc.Z), uevrUtils.rotator(p.rot.Pitch, p.rot.Yaw, p.rot.Roll), uevrUtils.vector(1, 1, 1))
end

local function splitT(t)
    local l, r = t.Translation, kismet_math_library:Quat_Rotator(t.Rotation)
    return { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
end

local function worldT(component)
    return kismet_math_library:MakeTransform(component:K2_GetComponentLocation(), component:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1))
end

-- the held weapon: ranged or not, and the arms socket the game hangs its FPV mesh on (cached per weapon object).
-- Socket names are taken as FNames straight from the game's properties (string -> FName marshalling is unreliable on
-- this game, see the IK notes).
local weaponCache = { weapon = nil, ranged = false, socket = nil, socketName = "" }
local function isNone(fname)
    if fname == nil then return true end
    local ok, s = pcall(function() return fname:to_string() end)
    return not ok or s == nil or s == "" or s == "None"
end
local function refreshWeapon(pawn, arms)
    local weapon = nil
    pcall(function() weapon = pawn:GetCurrentWeapon() end)
    if weapon == weaponCache.weapon then return weaponCache end
    weaponCache = { weapon = weapon, ranged = false, socket = nil, socketName = "" }
    if weapon == nil then return weaponCache end
    local melee = false
    pcall(function() melee = string.find(tostring(weapon.WeaponCategory.TagName:to_string()), "Melee") ~= nil end)
    weaponCache.ranged = not melee
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
    weaponCache.socket = socket
    pcall(function() weaponCache.socketName = socket:to_string() end)
    print("[weapon_recoil] weapon " .. tostring(uevrUtils.getShortName(weapon)) .. ": ranged " .. tostring(weaponCache.ranged) .. ", socket " .. tostring(weaponCache.socketName))
    return weaponCache
end

local function readSocket(mesh, socket)
    local t = mesh:GetSocketTransform(socket, RTS_COMPONENT)
    local l, r = t.Translation, kismet_math_library:Quat_Rotator(t.Rotation)
    return { loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
end

-- the right-hand IK solver's saved values (data/ik_parameters.json, the solver driven by the right controller)
local function rightHandSolver()
    local offset, rotation, solverId = { 0, 0, 0 }, { 0, 0, 0 }, nil
    pcall(function()
        local params = json.load_file("ik_parameters.json")
        local profileName = params and params["_profileState"] and params["_profileState"]["currentEditingProfile"] or "default"
        local profile = params and (params[profileName] or params["default"])
        for id, solver in pairs(profile and profile["solvers"] or {}) do
            if solver["end_control_type"] == 1 then -- ik.ControllerType.RIGHT_CONTROLLER
                offset = solver["end_bone_offset"] or offset
                rotation = solver["end_bone_rotation"] or rotation
                solverId = id
            end
        end
    end)
    return offset, rotation, solverId
end

-- kick state
local active = false
local suppressedUntilRelease = false
local baseline = nil      -- socket pose (mesh space) the last frame before firing
local lastPose = nil      -- socket pose of the previous frame
local releasedAt = nil
local kick = nil          -- this frame's kick (gun frame) while active; applied to the gun after every view
local handRest = nil      -- Hands mode: { hand, loc, rot, scale } of the right glove before the kick
local ikRest = nil        -- IK mode: { solverId, offset, rotation } (the saved solver values)
local peakCm, peakDeg = 0, 0
local lastDelta = nil     -- last frame's unscaled kick (socket frame), to carry the baseline through an ADS transition

-- the arms are blending into / out of ADS ("fine aim"): ARK_P1P_AnimBP_C.FineAimProgressNormalizedSmoothed (0 = hip,
-- -> 1 aimed, MCP 2026-09-29) still moving. Change per frame, not a range: a smoothed value may settle short of 1.
-- Sampled once per frame (tick calls it before any use).
local adsProgress, adsMoving = nil, false
local function sampleAds(arms)
    local p = nil
    pcall(function() p = arms:GetAnimInstance().FineAimProgressNormalizedSmoothed end)
    adsMoving = p ~= nil and adsProgress ~= nil and math.abs(p - adsProgress) > 0.0005
    adsProgress = p
end
local function adsTransitioning() return adsMoving end

local function restoreHand()
    if handRest == nil then return end
    if alive(handRest.hand) then
        pcall(uevrUtils.set_component_relative_transform, handRest.hand, handRest.loc, handRest.rot, handRest.scale)
    end
    handRest = nil
end

local function restoreIK()
    if ikRest == nil then return end
    local r = ikRest
    ikRest = nil
    pcall(function()
        ik.setSolverRuntimeParameter(r.solverId, "end_bone_offset", r.offset)
        ik.setSolverRuntimeParameter(r.solverId, "end_bone_rotation", r.rotation)
    end)
end

-- two_handed.lua snapshots the glove's relative transform when it parents it to the gun: never a kicked one
_G.ow2RecoilRestoreHand = function() restoreHand() end

local function kickComponentWorld(component, k)
    local l, r = splitT(kismet_math_library:ComposeTransforms(makeT(k), worldT(component)))
    component:K2_SetWorldLocationAndRotation(uevrUtils.vector(l.X, l.Y, l.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), false, reusable_hit_result, false)
end

local function endKick(reason)
    kick = nil
    if not active then return end
    active = false
    baseline, releasedAt = nil, nil
    restoreHand()
    restoreIK()
    configui.setLabel("ow2_recoil_status", string.format("Last burst: peak %.1f cm, %.1f deg%s", peakCm, peakDeg, reason and (" (" .. reason .. ")") or ""))
end

-- Hands mode, once per frame: move the right glove (a child of the controller) so that it keeps its grip on the kicked
-- gun. G (gun relative to the hand) is taken from the hand's REST pose = rest relative x its parent now - not read off
-- the hand: set_component_relative_transform writes the fields only, so the hand's world pose still holds last frame's
-- kick until the parent next moves.
local function applyToHand(gun, kickT)
    local hand = hands.getHandComponent(Handed.Right)
    if not alive(hand) then return end
    if handRest == nil or handRest.hand ~= hand then
        restoreHand()
        local l, r, s = hand.RelativeLocation, hand.RelativeRotation, hand.RelativeScale3D
        handRest = { hand = hand, loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, scale = { X = s.X, Y = s.Y, Z = s.Z } }
    end
    local parent = hand.AttachParent
    if parent == nil then return end
    local parentW = parent:GetSocketTransform(hand.AttachSocketName, 0) -- RTS_World; no socket = the component itself
    local handW = kismet_math_library:ComposeTransforms(makeT(handRest), parentW)
    local G = kismet_math_library:MakeRelativeTransform(worldT(gun), handW)
    local t = kismet_math_library:ComposeTransforms(kismet_math_library:ComposeTransforms(
        kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(G), kickT), G), makeT(handRest))
    local l, r = splitT(t)
    uevrUtils.set_component_relative_transform(hand, l, r, handRest.scale)
end

-- IK mode, once per frame: the right-hand target (controller space, what libs/ik.lua solves r_hand_JNT to:
-- controller + rotate(end_bone_offset, controller rot), ComposeRotators(end_bone_rotation, controller rot)) moved so that
-- the hand keeps its grip on the kicked gun. rel is taken from the gun's true (controller-hook) pose this view - read
-- before ik_weapon_sync.lua redraws it rig-relative.
local function applyToIK(gun, kickT)
    if ikRest == nil then
        local off, rot, solverId = nil, nil, nil
        if _G.ow2IKRightHandRest ~= nil then
            -- the weapon-adjusted target (ik_hand_offset.lua), so the end of the kick restores the per-weapon IK hand offset
            local id, o, r = _G.ow2IKRightHandRest()
            solverId, off, rot = id, o, r
        end
        if solverId == nil then off, rot, solverId = rightHandSolver() end
        if solverId == nil then return end
        ikRest = { solverId = solverId, offset = off, rotation = rot }
    end
    local ctrl = controllers.getController(Handed.Right, true)
    if not alive(ctrl) then return end
    local o, ro = ikRest.offset, ikRest.rotation
    local targetT = kismet_math_library:MakeTransform(uevrUtils.vector(o[1], o[2], o[3]), uevrUtils.rotator(ro[1], ro[2], ro[3]), uevrUtils.vector(1, 1, 1))
    local handW = kismet_math_library:ComposeTransforms(targetT, worldT(ctrl))
    local relT = kismet_math_library:MakeRelativeTransform(worldT(gun), handW)
    local t = kismet_math_library:ComposeTransforms(kismet_math_library:ComposeTransforms(
        kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(relT), kickT), relT), targetT)
    local l, r = splitT(t)
    ik.setSolverRuntimeParameter(ikRest.solverId, "end_bone_offset", { l.X, l.Y, l.Z })
    ik.setSolverRuntimeParameter(ikRest.solverId, "end_bone_rotation", { r.Pitch, r.Yaw, r.Roll })
end

-- once per frame (first post-stereo view): measure the kick and apply the per-frame (hand) parts
local function tick(gun)
    local twoHanding = _G.isTwoHandingActive == true
    if value("ow2_recoil_enabled", true) == false or (twoHanding and value("ow2_recoil_two_handed", true) == false) then
        endKick() lastPose = nil return
    end
    local pawn = uevr.api:get_local_pawn(0)
    local arms = nil
    pcall(function() arms = pawn.FPVMesh end)
    if pawn == nil or not alive(arms) or not alive(gun) then endKick() lastPose = nil return end
    local w = refreshWeapon(pawn, arms)
    if not w.ranged or w.socket == nil then endKick() lastPose = nil return end

    local ok, pose = pcall(readSocket, arms, w.socket)
    if not ok or pose == nil then endKick() lastPose = nil return end
    sampleAds(arms)

    if not triggerHeld then suppressedUntilRelease = false end
    if not active then
        if triggerHeld and not suppressedUntilRelease and lastPose ~= nil and not adsTransitioning(arms) then
            active, baseline, releasedAt, lastDelta = true, lastPose, nil, nil
            peakCm, peakDeg = 0, 0
        else
            lastPose = pose
            return
        end
    end
    lastPose = pose

    local now = os.clock()
    if triggerHeld then releasedAt = nil elseif releasedAt == nil then releasedAt = now end
    local weight = 1.0
    if releasedAt ~= nil then
        local f = (now - releasedAt) / math.max(0.05, value("ow2_recoil_tail", 0.35))
        if f >= 1.0 then endKick() return end
        if f > 0.7 then weight = (1.0 - f) / 0.3 end
    end

    -- ADS raise / lower in progress (two_handed.lua holds ADS while two-handing): that arm motion is not recoil. The
    -- baseline is carried along so the kick so far stays exactly as it was: baseline' = lastDelta^-1 * pose.
    if adsTransitioning(arms) and lastDelta ~= nil then
        local b = kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(makeT(lastDelta)), makeT(pose))
        local bl, br = splitT(b)
        baseline = { loc = bl, rot = br }
    end

    -- the socket's change since the trigger press, in the socket's (= gun's) own frame
    local d = kismet_math_library:MakeRelativeTransform(makeT(pose), makeT(baseline))
    do
        local dl, dr = splitT(d)
        lastDelta = { loc = dl, rot = dr }
    end
    local t, r = d.Translation, kismet_math_library:Quat_Rotator(d.Rotation)
    local cm = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
    local deg = math.max(math.abs(r.Pitch), math.abs(r.Yaw), math.abs(r.Roll))
    if cm > value("ow2_recoil_max_cm", 12.0) or deg > value("ow2_recoil_max_deg", 25.0) then
        suppressedUntilRelease = true
        endKick(string.format("larger motion ignored: %.1f cm, %.1f deg", cm, deg))
        return
    end
    if cm > peakCm then peakCm = cm end
    if deg > peakDeg then peakDeg = deg end

    local sl, sr = value("ow2_recoil_strength_loc", 1.0) * weight, value("ow2_recoil_strength_rot", 1.0) * weight
    kick = { loc = { X = t.X * sl, Y = t.Y * sl, Z = t.Z * sl }, rot = { Pitch = r.Pitch * sr, Yaw = r.Yaw * sr, Roll = r.Roll * sr } }

    -- the hand that holds the gun (gun not kicked yet in this view: G / rel come from its true pose)
    if isIKMode() then
        restoreHand()
        if twoHanding and _G.isTwoHandingIKRightLocked ~= nil and _G.isTwoHandingIKRightLocked() then
            restoreIK() -- the right IK target is attached to the gun (two_handed.lua) and follows the kicked gun already
        else
            applyToIK(gun, makeT(kick))
        end
    else
        restoreIK()
        if twoHanding then
            restoreHand() -- both gloves are parented to the gun meanwhile and follow it
        else
            applyToHand(gun, makeT(kick))
        end
    end
end

-- Every post-stereo view: UObjectHook has re-placed the gun (and two_handed.lua pivoted it), so the kick is re-applied
-- each time; the first view of a frame (after the world tick = this frame's arm pose) also measures it.
local ranThisFrame = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisFrame = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    local gun = nil
    pcall(function() gun = attachments.getCurrentGrippedAttachment(Handed.Right) end)
    if not ranThisFrame then
        ranThisFrame = true
        local ok, err = pcall(tick, gun)
        if not ok then
            print("[weapon_recoil] tick: " .. tostring(err))
            pcall(endKick, "error")
        end
    end
    if kick ~= nil and alive(gun) then pcall(kickComponentWorld, gun, kick) end
end, KICK_PRIORITY)

uevrUtils.registerPreLevelChangeCallback(function(level)
    -- the hand / rig go with the level: forget them without touching them
    active, baseline, lastPose, releasedAt, handRest, ikRest, kick, lastDelta = false, nil, nil, nil, nil, nil, nil, nil
    adsProgress, adsMoving = nil, false
    weaponCache = { weapon = nil, ranged = false, socket = nil, socketName = "" }
end)

uevr.params.sdk.callbacks.on_script_reset(function()
    pcall(restoreHand)
    pcall(restoreIK)
end)

print("[weapon_recoil] loaded")
