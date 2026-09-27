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
            { widgetType = "checkbox", id = "th_snap_left_hand", label = "Snap left hand to grip point", initialValue = true },
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

-- World-space fore-grip point for the current weapon mesh
local function getGripPoint(weaponMesh)
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

local function applyLeftOffset()
    if not active or leftBaseRel == nil then return end
    local pmc = hands.getHandComponent(Handed.Left)
    if not alive(pmc) then return end
    local p = getWeaponParams(currentWeaponID) or {}
    pcall(function()
        uevrUtils.set_component_relative_transform(pmc,
            { X = leftBaseRel.loc.X + (p.lhOffX or 0), Y = leftBaseRel.loc.Y + (p.lhOffY or 0), Z = leftBaseRel.loc.Z + (p.lhOffZ or 0) },
            { Pitch = leftBaseRel.rot.Pitch + (p.lhRotPitch or 0), Yaw = leftBaseRel.rot.Yaw + (p.lhRotYaw or 0), Roll = leftBaseRel.rot.Roll + (p.lhRotRoll or 0) },
            { X = 1, Y = 1, Z = 1 })
    end)
end

local function captureLeftBase()
    leftBaseRel = nil
    local pmc = hands.getHandComponent(Handed.Left)
    if not alive(pmc) then return end
    pcall(function()
        leftBaseRel = {
            loc = { X = pmc.RelativeLocation.X, Y = pmc.RelativeLocation.Y, Z = pmc.RelativeLocation.Z },
            rot = { Pitch = pmc.RelativeRotation.Pitch, Yaw = pmc.RelativeRotation.Yaw, Roll = pmc.RelativeRotation.Roll },
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
    pcall(function()
        uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Left, ikBase.weaponMesh, "", 0,
            { X = ikBase.loc.X + (p.lhOffX or 0), Y = ikBase.loc.Y + (p.lhOffY or 0), Z = ikBase.loc.Z + (p.lhOffZ or 0) },
            { Pitch = ikBase.rot.Pitch + (p.lhRotPitch or 0), Yaw = ikBase.rot.Yaw + (p.lhRotYaw or 0), Roll = ikBase.rot.Roll + (p.lhRotRoll or 0) })
        ikAccessoryAttached = true
    end)
end

local function attachIKLeftHand(weaponMesh, gripPoint)
    ikBase = nil
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

-- ---------------------------------------------------------------------------------------------
-- Activation
-- ---------------------------------------------------------------------------------------------
local function activate(weaponMesh, gripPoint)
    if active then return end
    active = true
    local animName = attachments.getCurrentGripAnimation(Handed.Right)
    if ikMode() then
        attachIKLeftHand(weaponMesh, gripPoint)
    else
        parentHandToWeapon(Handed.Right, weaponMesh, nil)
        parentHandToWeapon(Handed.Left, weaponMesh, configui.getValue("th_snap_left_hand") ~= false and gripPoint or nil)
        captureLeftBase()
        applyLeftOffset()
    end
    -- left hand takes the weapon's left grip pose (left_grip_weapon_<animation>) and stays in it: the left
    -- trigger is the grab button, so the input-driven trigger lerp for that hand is locked while held
    pcall(function() hands.setHoldingAttachment(Handed.Left, (type(animName) == "string" and animName) or true) end)
    pcall(function() if hands.setInputLocked then hands.setInputLocked(Handed.Left, true) end end)
    _G.isTwoHandingActive = true
    status("two-handing")
    scheduleLeftPose()
end

local function deactivate(reason)
    if not active then return end
    active = false
    leftBaseRel = nil
    detachIKLeftHand()
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
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    active = false
    -- the IK accessory table in libs/ik.lua survives the rig rebuild: release the left hand or the new
    -- rig would keep targeting the old world's weapon mesh
    if ikAccessoryAttached then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end) end
    ikAccessoryAttached = false
    ikBase = nil
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
            twoHandedAiming.applyTwoHandedRotation(weaponMesh, rightHand, leftHand)
            -- safety net: re-assert the captured pose once a second (hand animation lerps can overwrite it)
            poseReapplyTimer = (poseReapplyTimer or 0) + 1
            if poseReapplyTimer >= 60 then poseReapplyTimer = 0; applyLeftPose() end
        end
    end
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not vr.is_hmd_active() then return end
    if ranThisTick then return end
    ranThisTick = true
    local ok, err = pcall(tick)
    if not ok then print("[two_handed] " .. tostring(err)) end
end)

print("[two_handed] loaded")
