-- Left-hand gadget props on the left controller for The Outer Worlds 2 (2026-11-02), like weaponhook.lua does for the
-- right-hand weapon.
--
-- A gadget used with the left trigger (e.g. the Dematerializer acid spray, Gadget_Dematerializer_C) has no weapon mesh
-- of its own (its DematerializerWeapon's FPVCurrentVisuals.WeaponMesh stays nil). While it is in use the game creates a
-- SkeletalMeshComponent on the pawn (SK_Dematerializer_001) and attaches it to Pawn.FPVMesh - the hidden first-person
-- arms - and detaches it when the use ends (MCP watch on FPVMesh.AttachChildren, 2026-11-02). Nothing reflected points
-- at that component, so while a gadget is equipped (PlayerEquipment.EquippedGadget) the FPVMesh children are scanned
-- for a skeletal mesh that is neither a prosthetic limb copy (/Prosthetics/ asset, see weaponhook.lua) nor the current
-- weapon's FPV mesh. That prop rides the left raw controller through libs/attachments (attachment ID from its outer +
-- asset, e.g. IndianaPlayerCharacter_BP_C_SK_Dematerializer_001, so its offsets are tuned in the attachments panel).
--
-- The game's attachment to FPVMesh is left in place (detachFromOriginOnGrip = false): when the game detaches the prop,
-- it is released from the controller too. Permanent UObjectHook state (restoreTransformToOriginOnReattach = true), or
-- the backend would restore its pre-attach transform after every stereo pass (see weaponhook.lua / the
-- non-permanent attachment gotcha). Kept out of the foreground pass like every other VR-held mesh (breaks AFW).

local uevrUtils   = require('libs/uevr_utils')
local attachments = require('libs/attachments')

local ATTACH_OPTIONS = {
    detachFromOriginOnGrip = false,
    maintainWorldPositionOnDetachFromOrigin = false,
    detachFromParentOnRelease = false,
    maintainWorldPositionOnDetachFromParent = false,
    reattachToOriginOnRelease = false,
    restoreTransformToOriginOnReattach = true,
    allowChildVisibilityHandling = true,
    allowChildHiddenInGameHandling = true,
    allowRenderInMainPassHandling = true,
}

local skeletalMeshClass = nil -- resolved lazily (class lookups can fail while scripts load at game start)
local heldProp = nil

local function isAlive(object)
    return object ~= nil and pcall(function() return object:get_full_name() end)
end

local function release()
    if heldProp ~= nil then
        pcall(function() attachments.detachGripAttachments(Handed.Left) end)
        heldProp = nil
    end
end

local function currentWeaponMesh(pawn)
    local mesh = nil
    pcall(function() mesh = pawn:GetCurrentWeapon().FPVCurrentVisuals.WeaponMesh end)
    return mesh
end

local function findGadgetProp(pawn, arms)
    if skeletalMeshClass == nil then
        skeletalMeshClass = uevrUtils.get_class("Class /Script/Engine.SkeletalMeshComponent")
        if skeletalMeshClass == nil then return nil end
    end
    local children = arms.AttachChildren
    if children == nil then return nil end
    local weaponMesh = nil
    for i = 1, #children do
        local child = children[i]
        local isProp = false
        pcall(function()
            if child ~= nil and child:is_a(skeletalMeshClass) and child.SkinnedAsset ~= nil
                and string.find(child.SkinnedAsset:get_full_name(), "/Prosthetics/", 1, true) == nil then
                if weaponMesh == nil then weaponMesh = currentWeaponMesh(pawn) or false end
                isProp = child ~= weaponMesh
            end
        end)
        if isProp then return child end
    end
    return nil
end

local function isChildOf(component, parent)
    local ok, attached = pcall(function() return component.AttachParent == parent end)
    return ok and attached
end

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    local ok, err = pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local arms = pawn ~= nil and pawn.FPVMesh or nil
        local equipment = pawn ~= nil and pawn.PlayerEquipment or nil
        if arms == nil or equipment == nil or equipment.EquippedGadget == nil then release() return end

        -- the game detached (or destroyed) the prop: give the left hand back
        if heldProp ~= nil and not (isAlive(heldProp) and isChildOf(heldProp, arms)) then release() end

        if heldProp == nil then
            local prop = findGadgetProp(pawn, arms)
            if prop ~= nil then
                attachments.attachToRawController(prop, Handed.Left, ATTACH_OPTIONS)
                heldProp = prop
            end
        end

        if heldProp ~= nil and heldProp.bForeground == true then heldProp:SetForeground(false) end
    end)
    if not ok then print("[left_gadget] " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    heldProp = nil
end)
