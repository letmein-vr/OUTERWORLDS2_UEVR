local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require("libs/configui")
local reticule = require("libs/reticule")
local hands = require('libs/hands')
local attachments = require('libs/attachments')
local accessories = require('libs/accessories')
local input = require('libs/input')
local pawnModule = require('libs/pawn')
local animation = require('libs/animation')
local montage = require('libs/montage')
local interaction = require('libs/interaction')
local ui = require('libs/ui')
local remap = require('libs/remap')
local gestures = require('libs/gestures')

-- Release layout (2026-10-12): developer mode OFF. This hides the library dev panels (Input/UI/Pawn/
-- Reticule/Remap/Montage/Interaction Dev Config); the only configui panel left is "Outer Worlds 2 VR"
-- (zz_ow2_vr_panel.lua). Three switches bring the dev panels back for tuning sessions:
--   * this flag = true             -> Input/UI/Pawn/Reticule/Remap/Montage/Interaction dev panels
--   * ik.init(true, ...) below     -> IK dev panel
--   * attachments.init(true, ...)  -> "Attachments Config Dev" (scripts/weaponhook.lua)
uevrUtils.setDeveloperMode(false)

-- VR hands wizard ("Hand Config" panel). Hidden; uncomment to tune. The saved data/hands_parameters.json is what
-- scripts/hands.lua builds from. Never use the wizard's script-generation step: it overwrites scripts/hands.lua with its
-- template (see uevr-hands-wizard-leak-bug / the wizard-regenerates-hands.lua trap).
-- hands.enableConfigurationTool()

-- Full-arm IK rig (libs/ik), used when the "Hands Mode" panel (scripts/hands.lua) is set to "IK arms".
-- The library is always loaded (its dev panel only appears when developer mode is on); whether a rig
-- is auto-created follows the mode. scripts/hands.lua drives this through _G.setIKEnabled / _G.ikRebuild (it loads first, so the
-- mode getter already exists here). The mesh-created callback keeps the rig meshes OUT of the game's
-- foreground pass (see weaponhook.lua for why).
local ik = require('libs/ik')
-- Prosthetics: a prosthetic limb is NOT part of the arms mesh. The game adds it as an extra SkeletalMeshComponent
-- attached to Pawn.FPVMesh (e.g. SK_ARK_PRS_TP_HighEnd_LeftArm_01_F, runtime-numbered name) that follows FPVMesh
-- through leader pose, and the arms mesh drops its own flesh limb. The IK rig only copies FPVMesh, so that limb
-- was simply missing. Each skeletal-mesh child of FPVMesh gets a PoseableMesh copy (the same creation path the
-- rig uses for the arms) that is appended to the rig's meshList: the solvers write the arm pose to every mesh in
-- that list, Rig:hide() hides them all and rig destruction destroys them (and their owner actors).
-- Finger grip/trigger poses are only driven on the rig's arms mesh, so the finger bones (everything below
-- l_hand_JNT / r_hand_JNT) are copied from it to each prosthetic copy every post-tick, after IK + finger animation.
-- The copy sits beside the arms mesh (same parent, same relative transform), not under it: the rig's tick sets
-- RelativeLocation.Z on every mesh in meshList, which would otherwise be applied twice (prosthetic too high).
-- NOT leader pose: SetLeaderPoseComponent(freshRigMesh, true) crashed the game (AV in game code, 2026-09-28) -
-- the rig's PoseableMesh has no initialised bone arrays in its creation frame.
local HAND_BONES = { l_hand_JNT = true, r_hand_JNT = true }
local prostheticFingerLinks = {} -- { src = rig arms mesh, dst = prosthetic copy, bones = { FName... } }

-- A prosthetic limb among FPVMesh's children. Identified by asset folder, NOT just "skeletal mesh child":
-- some weapons (e.g. the pistol) parent their FPV weapon mesh to FPVMesh too, and treating that as a limb hid
-- the gun and would have duplicated it onto the rig/gloves (2026-09-28).
local function isProstheticMesh(child)
    if child == nil then return false end
    local ok, result = pcall(function()
        local asset = child.SkinnedAsset
        return asset ~= nil and string.find(asset:get_full_name(), "/Prosthetics/", 1, true) ~= nil
    end)
    return ok and result == true
end

local function isComponentAlive(c)
    if c == nil then return false end
    local ok, r = pcall(function() return c:get_full_name() ~= nil end)
    return ok and r
end

-- bones that have one of `ancestors` (name set, default = the two hand bones) as a strict ancestor
local function getFingerBones(mesh, ancestors)
    ancestors = ancestors or HAND_BONES
    local bones = {}
    for _, name in ipairs(uevrUtils.getBoneNames(mesh) or {}) do
        -- walk up the hierarchy: keep the bone if an ancestor bone is a strict ancestor
        local parent = mesh:GetParentBone(uevrUtils.fname_from_string(name)):to_string()
        while parent ~= nil and parent ~= "None" do
            if ancestors[parent] then
                table.insert(bones, uevrUtils.fname_from_string(name))
                break
            end
            parent = mesh:GetParentBone(uevrUtils.fname_from_string(parent)):to_string()
        end
    end
    return bones
end

-- the rig / gloves of the previous level are torn down on level change; drop the links so the per-tick copy
-- never touches their (possibly reclaimed) components
uevrUtils.registerPreLevelChangeCallback(function(level)
    prostheticFingerLinks = {}
end)

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    for i = #prostheticFingerLinks, 1, -1 do
        local link = prostheticFingerLinks[i]
        if not (isComponentAlive(link.src) and isComponentAlive(link.dst)) then
            -- source (rig mesh / glove) gone but the copy still alive: glove destruction does not destroy
            -- children, so the copy would be left behind - destroy it and its own owner actor
            if isComponentAlive(link.dst) then pcall(function() uevrUtils.destroyComponent(link.dst, true, false) end) end
            table.remove(prostheticFingerLinks, i)
        else
            pcall(function()
                for _, bone in ipairs(link.bones) do
                    local t = link.src:GetBoneTransformByName(bone, EBoneSpaces.ComponentSpace)
                    link.dst:SetBoneTransformByName(bone, t, EBoneSpaces.ComponentSpace)
                end
            end)
        end
    end
end)

local function copyProstheticsToRig(meshList, rig)
    local ikArmsMesh = meshList and meshList[1]
    local pawn = uevr.api:get_local_pawn(0)
    local fpv = nil
    pcall(function() fpv = pawn.FPVMesh end)
    if fpv == nil or ikArmsMesh == nil then return end
    local skelClass = uevrUtils.get_class("Class /Script/Engine.SkeletalMeshComponent")
    local poseableClass = uevrUtils.get_class("Class /Script/Engine.PoseableMeshComponent")
    local children = nil
    pcall(function() children = fpv.AttachChildren end)
    for i = 1, (children and #children or 0) do
        local child = children[i]
        pcall(function()
            if not isProstheticMesh(child) then return end
            local copy = uevrUtils.createPoseableMeshFromSkeletalMesh(child, { useDefaultPose = true })
            if copy == nil then return end
            local parent = ikArmsMesh.AttachParent
            if parent ~= nil then
                copy:K2_AttachTo(parent, uevrUtils.fname_from_string(""), 0, false)
                local l, r = ikArmsMesh.RelativeLocation, ikArmsMesh.RelativeRotation
                copy.RelativeLocation = uevrUtils.vector(l.X, l.Y, l.Z)
                copy.RelativeRotation = uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll)
            else
                copy:K2_AttachTo(ikArmsMesh, uevrUtils.fname_from_string(""), 0, false)
                copy.RelativeLocation = uevrUtils.vector(0, 0, 0)
                copy.RelativeRotation = uevrUtils.rotator(0, 0, 0)
            end
            copy:SetForeground(false) -- the foreground pass breaks AFW (see weaponhook.lua)
            copy:SetCastShadow(false)
            -- match the rig's current montage hide state (Rig:hide only re-applies on a state change)
            copy:SetVisibility(not (rig ~= nil and rig.wasHidden == true), true)
            copy:SetHiddenInGame(false, true)
            copy.BoundsScale = 16.0
            table.insert(meshList, copy)
            local fingers = getFingerBones(copy)
            table.insert(prostheticFingerLinks, { src = ikArmsMesh, dst = copy, bones = fingers })
            print("[prosthetics] copied " .. child.SkinnedAsset:get_full_name() .. " onto the IK rig (" .. #fingers .. " finger bones)")
        end)
    end
end

-- Gloves ("Hands" mode): each glove is an FPVMesh copy cut down to one hand with
-- animation.transformBoneToRoot(glove, <wrist bone>, Location, Rotation, Scale, TaperOffset) from
-- hands_parameters.json. A prosthetic on that side gets a PoseableMesh copy attached under the glove (identity
-- relative), the SAME transformBoneToRoot pass (re-applied at the glove's 100/600/1500/3000 ms settle delays),
-- and a per-tick copy of every bone below the wrist bone from the glove (finger / grip / trigger poses).
-- Side comes from the prosthetic asset name (…LeftArm… / …RightArm…).
hands.onCreatedCallback(function(hand, component, componentName)
    -- deferred one tick: hands.create() fires this callback BEFORE it stores the definitions
    -- (handDefinitions = definition runs after its creation loop), so getHandDefinition() is still nil here
    uevrUtils.setTimeout(1, function()
    if not isComponentAlive(component) then return end
    pcall(function()
        local definitionSet = hands.getHandDefinition(componentName)
        local def = definitionSet and definitionSet[hand == Handed.Left and "Left" or "Right"]
        if def == nil or def["Name"] == nil or def["Name"] == "" then return end
        local fpv = uevr.api:get_local_pawn(0).FPVMesh
        local skelClass = uevrUtils.get_class("Class /Script/Engine.SkeletalMeshComponent")
        local poseableClass = uevrUtils.get_class("Class /Script/Engine.PoseableMeshComponent")
        local children = fpv.AttachChildren
        for i = 1, (children and #children or 0) do
            pcall(function()
                local child = children[i]
                if not isProstheticMesh(child) then return end
                local asset = child.SkinnedAsset
                local assetName = asset:get_full_name()
                local side = string.find(assetName, "LeftArm", 1, true) and Handed.Left
                    or (string.find(assetName, "RightArm", 1, true) and Handed.Right) or nil
                if side ~= hand then return end

                local copy = uevrUtils.createPoseableMeshFromSkeletalMesh(child, { useDefaultPose = true })
                if copy == nil then return end
                copy:K2_AttachTo(component, uevrUtils.fname_from_string(""), 0, false)
                copy.RelativeLocation = uevrUtils.vector(0, 0, 0)
                copy.RelativeRotation = uevrUtils.rotator(0, 0, 0)
                copy:SetForeground(false) -- the foreground pass breaks AFW (see weaponhook.lua)
                copy:SetCastShadow(false)
                copy.BoundsScale = 16.0
                local wrist = def["Name"]
                local function v3(t, d) t = t or d return uevrUtils.vector(t[1], t[2], t[3]) end
                local function r3(t, d) t = t or d return uevrUtils.rotator(t[1], t[2], t[3]) end
                local function cutToHand()
                    if isComponentAlive(copy) then
                        animation.transformBoneToRoot(copy, wrist, v3(def["Location"], {0,0,0}), r3(def["Rotation"], {0,0,0}),
                            v3(def["Scale"], {1,1,1}), v3(def["TaperOffset"], {0,0,0}))
                    end
                end
                cutToHand()
                for _, delayMs in ipairs({100, 600, 1500, 3000}) do uevrUtils.setTimeout(delayMs, cutToHand) end
                local bones = getFingerBones(copy, { [wrist] = true })
                table.insert(prostheticFingerLinks, { src = component, dst = copy, bones = bones })
                print("[prosthetics] glove copy of " .. assetName .. " on " .. (hand == Handed.Left and "left" or "right") .. " hand (" .. #bones .. " bones below " .. wrist .. ")")
            end)
        end
    end)
    end)
end)

ik.registerOnMeshCreatedCallback(function(meshList, rig)
    for _, mesh in ipairs(meshList or {}) do
        if mesh ~= nil and mesh.SetForeground ~= nil then
            pcall(function() mesh:SetForeground(false) end)
        end
    end
    copyProstheticsToRig(meshList, rig)
    -- same as the glove path: a fresh rig starts in the open pose until an input edge; re-assert the
    -- current weapon grip/trigger state (scripts/hands.lua owns the helper)
    if _G.refreshWeaponPoses ~= nil then pcall(_G.refreshWeaponPoses) end
end)
ik.init(false, LogLevel.Warning) -- no IK dev panel in the release layout (true brings it back); Warning keeps solver failures in log.txt without per-tick debug noise

local function ikWanted()
    return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end
_G.setIKEnabled = function(enabled)
    ik.setAutoCreateArms(enabled == true) -- the 1 s auto-create builds the rig from ik_parameters.json + hands_parameters.json
    if not enabled and ik.exists() then ik.destroyAll() end
end
_G.ikRebuild = function()
    -- suit / armor change: drop the rig, auto-create rebuilds it (with the new arms mesh) within a second
    if ik.exists() then ik.destroyAll() end
end
ik.setAutoCreateArms(ikWanted())

ui.init()
-- Montage config dev panel hidden for the release layout (no argument = developer mode off); montage.init(true) shows it
-- again for tuning.
montage.init()
-- The library only polls pawn:GetCurrentMontage(), i.e. Pawn.Mesh = the third-person body. OW2 plays its
-- first-person montages (melee, reload, equip...) on the arms mesh, so watch that too; the weapon mesh's
-- *_MESB_* montages mirror these and it is re-parented by weaponhook, so it is not monitored.
montage.addMeshMonitor("Arms", "Pawn.FPVMesh")
-- Character interactions and in-game cinematics: the game keeps every such montage under
-- /Game/Art/ANIM/Character/P1P/Interactables/ (engineering panels, AutoDoc, consoles, switch drums...) and
-- prefixes the cinematic ones CIN_; weapon montages live under /P1P/Weap/ and /P3P/<class>/, consumables under
-- /Uni/. Any montage without its own explicit settings that matches uses this rule's settings (edit them in the
-- Montages panel: "* Rule: Interactables & Cinematics"). Seed = hands hidden, input.lua disabled, pawn arms
-- visible, UEVR aim Game, weapon hidden.
montage.addPatternRule("rule_interactables", "* Rule: Interactables & Cinematics",
    { pathContains = { "/Interactables/" }, namePrefixes = { "CIN_" } },
    { handsWhenActive = 2, inputWhenActive = 3, pawnArmsWhenActive = 3, aimMethodWhenActive = 2, weaponWhenActive = 2 })
-- Ladder climbing is not a montage (only its enter/exit are): the arms anim instance (ARK_P1P_AnimBP_C) keeps
-- bIsUsingLadderAnimations true from grabbing the ladder until the exit anim starts, and MovementStateIsClimbing
-- true through the exit anim as well (MCP watches 2026-09-28: continuous, incl. pausing mid-ladder).
-- Seed = hands hidden, input.lua disabled, pawn arms visible ("* Rule: Ladder" in the Montages panel).
montage.addStateRule("rule_ladder", "* Rule: Ladder", function()
    local anim = uevr.api:get_local_pawn(0).FPVMesh.AnimScriptInstance
    return anim.bIsUsingLadderAnimations == true or anim.MovementStateIsClimbing == true
end, { handsWhenActive = 2, inputWhenActive = 3, pawnArmsWhenActive = 3 })
interaction.init()
reticule.init()
-- "Weapon Reticule" section of the Outer Worlds 2 VR panel (zz_ow2_vr_panel.lua; saved in data/ow2_vr_config.json).
-- Off = no VR reticule; the game's crosshair goes back onto the HUD.
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 6, label = "Weapon Reticule", layout = {
    { widgetType = "checkbox", id = "ret_enabled", label = "Enable VR weapon reticule (off = game's HUD crosshair)", initialValue = true },
    { widgetType = "slider_float", id = "ret_brightness", label = "Reticule brightness", range = {1.0, 20.0}, initialValue = 1.0, speed = 0.1 },
}})
configui.onCreateOrUpdate("ret_enabled", function(value)
    -- configui callbacks run on the draw thread; OW2 drops component destruction requested off the game thread
    uevrUtils.setTimeout(1, function() reticule.setEnabled(value ~= false) end)
end)
-- Brightness = the WidgetComponent's tint (RGB multiplier; its default material is unlit, so values > 1 act like an
-- emissive boost). The reticule is rebuilt on every level load / enable toggle, so the value is (re)applied by a
-- light poll whenever the live component's tint differs, not only when the slider moves.
uevrUtils.setInterval(250, function()
    pcall(function()
        local c = reticule.getComponent()
        if c == nil or c.SetTintColorAndOpacity == nil then return end
        local b = configui.getValue("ret_brightness") or 1.0
        local t = c.TintColorAndOpacity
        if t == nil or math.abs(t.R - b) > 0.001 then
            c:SetTintColorAndOpacity(uevrUtils.color_from_rgba(b, b, b, 1.0)) -- real LinearColor struct, not a Lua table
        end
    end)
end)
-- Reticule target for the "Custom" target method (reticule_parameters.json reticuleTargetMethod = 6): trace from the
-- held weapon's muzzle along its barrel. The lib's RIGHT_ATTACHMENT method rebuilds a raw-controller attachment's
-- aim from controller rotation + negated offsets + a fixed (0,-90,0) (its own comment calls it broken) and for OW2's
-- offsets pointed the trace straight down - reticle stuck on the floor under the hand (2026-09-29). The weapon mesh
-- has a real world transform (UEVR moves it); its X axis is the barrel and MuzzleFlashSocket the muzzle (same data
-- OW2AimFix uses). No gun out (no weapon, or a melee weapon without a muzzle socket) -> nil: the trace is skipped
-- and reticule.lua clears its last hit, which hides the reticule.
local muzzleSocketName = nil
reticule.registerCustomTargetCallback(function()
    local location, rotation = nil, nil
    pcall(function()
        local mesh = uevr.api:get_local_pawn(0):GetCurrentWeapon().FPVCurrentVisuals.WeaponMesh
        if muzzleSocketName == nil then muzzleSocketName = uevrUtils.fname_from_string("MuzzleFlashSocket") end
        if mesh:DoesSocketExist(muzzleSocketName) then
            location = mesh:GetSocketLocation(muzzleSocketName)
            rotation = mesh:K2_GetComponentRotation()
        end
    end)
    return location, rotation
end)
pawnModule.init()
remap.init()
input.init()
accessories.init()

-- Non-gameplay screens: input.lua pins the VR camera to the pawn root every frame, which is only right for the
-- real player character. The main menu (OwMainMenuPawn_BP_C, ~30 m from the Moon Man stage camera) and the
-- character creator (CharacterCreation_Lite: a plain DefaultPawn parked at z = -52300, ~520 m under the scene)
-- both render from a fixed game camera instead, so the view ended up in the dark / under the map. Disable
-- input.lua for any pawn that is not IndianaPlayerCharacter_BP_C so UEVR follows the game camera there.
-- Class name is resolved only when the pawn object changes; if it cannot be read, input.lua stays enabled.
local PLAYER_PAWN_CLASS = "IndianaPlayerCharacter_BP_C"
local menuPawnCheck = { pawn = nil, isMenu = false }
input.registerIsDisabledCallback(function()
    local p = uevr.api:get_local_pawn(0)
    if p ~= menuPawnCheck.pawn then
        menuPawnCheck.pawn = p
        menuPawnCheck.isMenu = false
        if p ~= nil then
            pcall(function()
                menuPawnCheck.isMenu = p:get_class():get_fname():to_string() ~= PLAYER_PAWN_CLASS
            end)
        end
    end
    if menuPawnCheck.isMenu then return true, 100 end
    return nil
end)
