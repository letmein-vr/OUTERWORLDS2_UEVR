-- PiP (picture-in-picture) scopes for The Outer Worlds 2 (2026-11-02), built with libs/scope.lua.
--
-- Which weapons get one: the game's own sight data. The equipped weapon's sight mode (Weapon:GetPrioritizedSightMode(),
-- a RangedMode) references a SightData asset, and SightData.bIsScoped says whether that sight is a magnifying scope.
-- MCP 2026-11-02, loaded sights: SightData_SR_Damage / SR_Accurate (base sniper scopes) and SR_Damage_Telescopic (the
-- telescopic mod) = true; SightData_MR_Frontline and SR_Accurate_Hologram (holographic mod) = false.
-- Base and modded weapons share one base mesh (and so one attachments-panel entry), so the decision follows the sight,
-- not the weapon: a scope mod fitted at the workbench adds the PiP, a holographic mod removes it.
--
-- Reading the sight: RangedMode.SightData (reflected TSoftObjectPtr) is the mode's BASE sight. A mod's sight is stored in
-- the next soft pointer, an unreflected native field right after it (offset SightData + 0x28, the size of a
-- TSoftObjectPtr; MCP: base SR_Damage at +0, SR_Damage_Telescopic at +0x28 on the telescopic-modded rifle). A soft
-- pointer starts with a weak pointer whose first int32 is the object index (UEVR Lua has no soft/weak property reader).
-- The override is used only if it resolves to a SightData, otherwise the base sight - so a layout change after a game
-- patch degrades to "base sight only" instead of reading garbage.
--
-- The scope is a libs/scope.lua instance attached to the weapon mesh on the right controller (FPVCurrentVisuals.WeaponMesh,
-- as in weaponhook.lua). It shows only while the HMD is near the ocular lens (scope.lua's per-scope "Deactivate
-- distance"); right stick up/down zooms while it is showing (scope.lua). Settings are stored per sight asset
-- (scope_parameters.json, ID = sight name, e.g. SightData_SR_Damage_Telescopic) and edited in the "PiP Scope" section,
-- which always edits the sight currently equipped.
--
-- Aiming accuracy: the objective lens (the scene capture) sits ON THE BORE LINE. It is re-attached to the weapon mesh's
-- MuzzleFlashSocket (MCP 2026-11-02, SR_Accurate: socket at X 97 / Y 0 / Z 10.6 cm with identity rotation relative to
-- the mesh, i.e. its X is the barrel axis), so "Objective Lens Location / Rotation" are offsets from the muzzle and the
-- centre of the PiP image is where the barrel points. The capture also ignores the weapon mesh and everything attached
-- to it (scope body, reticle, suppressor and other mods; HideComponent), so no part of the gun can block the view -
-- with the camera at the scope's own position the scope model filled the picture. Weapons without that socket keep
-- the camera on the mesh origin.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local controllers = require('libs/controllers')
local scope = require('libs/scope')

-- Defaults for sights without stored settings, from xaero's tuned SightData_SR_Accurate (2026-11-02). OW2 weapon meshes
-- point the barrel along their +X axis (mesh origin -> MuzzleFlashSocket runs along GetForwardVector; the world
-- reticule uses the same axis), so objective rotation X = 90 cancels scope.lua's -90 pitch and looks down the barrel.
scope.setParameterDefault("objective_lens_rotation", {90.0, 0.0, 0.0})
scope.setParameterDefault("objective_lens_location", {0.0, 0.0, 0.0})
scope.setParameterDefault("ocular_lens_rotation", {90.0, 0.0, 0.0})
scope.setParameterDefault("ocular_lens_location", {19.2, 0.0, 18.05})
scope.setParameterDefault("ocular_lens_scale", 0.627)
-- scope.lua shows the PiP while the HMD is within this distance of the ocular lens. Its default (50 cm) is about where
-- the eyepiece sits with the rifle simply held, so the scope never switched off (2026-11-02); 20 cm = eye at the scope.
scope.setParameterDefault("deactivate_distance", 20.0)

local MUZZLE_SOCKET = "MuzzleFlashSocket"

local PREFIX = "ps_"
local SOFT_PTR_SIZE = 0x28
local POLL_S = 0.25

local layout = {
    { widgetType = "checkbox", id = "ps_enabled", label = "PiP scopes on weapons with a magnifying scope", initialValue = true },
    { widgetType = "text", id = "ps_status", label = "Sight: -" },
    { widgetType = "text", label = "Settings below are for the sight currently equipped (saved per sight)" },
}
for _, widget in ipairs(scope.getConfigWidgets(PREFIX)) do table.insert(layout, widget) end
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 2.8, label = "PiP Scope", layout = layout })

local current = { weapon = nil, mesh = nil, sightID = nil, scoped = false, instance = nil, status = "" } -- weapon / mesh = addresses
local sightClass = nil
local sightOffset = nil -- byte offset of RangedMode.SightData (reflection)
local nextPoll = 0

scope.createConfigCallbacks(function() return current.instance ~= nil and current.sightID or nil end, PREFIX)

local function isAlive(object)
    return object ~= nil and pcall(function() return object:get_full_name() end)
end

-- objects are compared by address (Lua wrappers of the same UObject are not guaranteed to be the same value)
local function addressOf(object)
    if object == nil then return nil end
    local ok, address = pcall(function() return object:get_address() end)
    return ok and address or nil
end

local function findPropertyOffset(class, name)
    local struct = class
    while struct ~= nil do
        local property = struct:find_property(name)
        if property ~= nil then return property:get_offset() end
        struct = struct:get_super_struct()
    end
    return nil
end

-- the SightData behind a TSoftObjectPtr at `offset` in `object`, nil if unresolved or not a SightData
local function sightAt(object, offset)
    local index = object:read_dword(offset)
    if index == nil or index <= 0 or index >= 0x7FFFFFFF then return nil end
    local resolved = uevr.api:get_uobject_array():get_object(index)
    if resolved ~= nil and resolved:is_a(sightClass) then return resolved end
    return nil
end

local function effectiveSight(weapon)
    if sightClass == nil then
        sightClass = uevrUtils.get_class("Class /Script/Arkansas.SightData")
        if sightClass == nil then return nil end
    end
    local mode = weapon:GetPrioritizedSightMode()
    if mode == nil then return nil end
    if sightOffset == nil then
        sightOffset = findPropertyOffset(mode:get_class(), "SightData")
        if sightOffset == nil then return nil end
    end
    return sightAt(mode, sightOffset + SOFT_PTR_SIZE) or sightAt(mode, sightOffset)
end

local muzzleSocketName = nil
local primitiveClass = nil

-- objective lens onto the muzzle socket (bore line); its stored location / rotation are then offsets from the muzzle
local function placeObjectiveAtMuzzle(instance, mesh, sightID)
    if muzzleSocketName == nil then muzzleSocketName = uevrUtils.fname_from_string(MUZZLE_SOCKET) end
    if mesh:DoesSocketExist(muzzleSocketName) ~= true then return false end
    local objective = instance:getObjectiveLensComponent()
    if objective == nil then return false end
    objective:K2_AttachToComponent(mesh, muzzleSocketName, 0, 0, 0, false)
    instance:setObjectiveLensRelativeLocation(scope.getParameter(sightID, "objective_lens_location"))
    instance:setObjectiveLensRelativeRotation(scope.getParameter(sightID, "objective_lens_rotation"))
    return true
end

-- the scene capture skips the weapon mesh and every primitive attached under it (scope parts, suppressor, muzzle
-- flash...) except the PiP ocular lens. HideComponent adds each one once; re-run every poll for parts attached later.
local function hideWeaponFromCapture(instance, mesh)
    local capture = instance:getObjectiveLensComponent()
    if capture == nil then return end
    if primitiveClass == nil then primitiveClass = uevrUtils.get_class("Class /Script/Engine.PrimitiveComponent") end
    local ocularAddress = addressOf(instance:getOcularLensComponent())
    capture:HideComponent(mesh)
    local function hideChildren(parent, depth)
        local children = parent.AttachChildren
        if children == nil or depth > 3 then return end
        for i = 1, #children do
            local child = children[i]
            if child ~= nil and addressOf(child) ~= ocularAddress then
                if primitiveClass ~= nil and child:is_a(primitiveClass) then capture:HideComponent(child) end
                hideChildren(child, depth + 1)
            end
        end
    end
    hideChildren(mesh, 1)
end

-- load the equipped sight's stored settings into the shared panel widgets (no callbacks: nothing to save)
local function loadSettingsIntoPanel(sightID)
    for _, widget in ipairs(scope.getConfigWidgets(PREFIX)) do
        local key = widget.id:sub(#PREFIX + #"scope_" + 1)
        local value = scope.getParameter(sightID, key)
        if value ~= nil then pcall(function() configui.setValue(widget.id, value, true) end) end
    end
end

local function destroyScope()
    if current.instance ~= nil then
        pcall(function() current.instance:destroy() end)
        current.instance = nil
    end
end

local function setStatus(text)
    pcall(function() configui.setLabel("ps_status", text) end)
end

-- the same HMD -> ocular lens distance scope.lua's updateActiveState compares with "Deactivate distance", and whether
-- the PiP is showing - for tuning the distance (status line, 4 Hz)
local function eyeDistanceText(instance, sightID)
    local threshold = scope.getParameter(sightID, "deactivate_distance") or 0
    local showing = instance:isDisplaying() and "showing" or "hidden"
    local head = controllers.getControllerLocation(2)
    local lens = instance:getOcularLensComponent()
    if head == nil or lens == nil then
        return string.format("eye distance: no HMD location (off beyond %.0f cm) - %s", threshold, showing)
    end
    local l = lens:K2_GetComponentLocation()
    local dx, dy, dz = l.X - head.X, l.Y - head.Y, l.Z - head.Z
    return string.format("eye %.0f cm (off beyond %.0f) - %s", math.sqrt(dx * dx + dy * dy + dz * dz), threshold, showing)
end

-- errors go to log.txt (Lua print does not), each distinct message once
local loggedErrors = {}
local function logError(text)
    if loggedErrors[text] then return end
    loggedErrors[text] = true
    pcall(function() uevr.params.functions.log_error("[pip_scope] " .. text) end)
end

local function update()
    local pawn = uevr.api:get_local_pawn(0)
    local equipment = pawn ~= nil and pawn.PlayerEquipment or nil
    local weapon = equipment ~= nil and equipment.EquippedWeapon or nil
    local mesh = nil
    if weapon ~= nil then pcall(function() mesh = weapon.FPVCurrentVisuals.WeaponMesh end) end
    local sight = (weapon ~= nil and configui.getValue("ps_enabled") ~= false) and effectiveSight(weapon) or nil
    local sightID = sight ~= nil and sight:get_fname():to_string() or nil
    local scoped = sight ~= nil and sight.bIsScoped == true

    -- rebuild when the weapon, its mesh or its sight changes, or the scope's components died
    local weaponAddress, meshAddress = addressOf(weapon), addressOf(mesh)
    local changed = weaponAddress ~= current.weapon or meshAddress ~= current.mesh or sightID ~= current.sightID or scoped ~= current.scoped
    if not changed and current.instance ~= nil and not isAlive(current.instance:getOcularLensComponent()) then changed = true end
    if not changed then
        if current.instance ~= nil then
            hideWeaponFromCapture(current.instance, mesh)
            setStatus(current.status .. " | " .. eyeDistanceText(current.instance, sightID))
        end
        return
    end

    -- the status shows what was detected even if the scope below fails to build
    local status = "Sight: " .. (sightID or "none") .. (scoped and " (scoped)" or (sightID ~= nil and " (not scoped)" or ""))
    setStatus(status)
    destroyScope()
    -- recorded before building, so a scope that fails to build is not retried every poll (only on the next change)
    current.weapon, current.mesh, current.sightID, current.scoped = weaponAddress, meshAddress, sightID, scoped
    if scoped and isAlive(mesh) then
        local atMuzzle = false
        local ok, err = pcall(function()
            current.instance = scope.new(sightID)
            current.instance:attachTo(mesh)
            atMuzzle = placeObjectiveAtMuzzle(current.instance, mesh, sightID)
            hideWeaponFromCapture(current.instance, mesh)
        end)
        if not ok then
            destroyScope()
            setStatus(status .. " - PiP failed: " .. tostring(err))
            logError("scope for " .. sightID .. ": " .. tostring(err))
            return
        end
        loadSettingsIntoPanel(sightID)
        current.status = status .. (atMuzzle and " - PiP on, camera at the muzzle" or " - PiP on, camera on the mesh (no muzzle socket)")
        setStatus(current.status)
    end
end

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    local now = os.clock()
    if now < nextPoll then return end
    nextPoll = now + POLL_S
    local ok, err = pcall(update)
    if not ok then
        setStatus("Error: " .. tostring(err))
        logError(tostring(err))
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    destroyScope()
    current.weapon, current.mesh, current.sightID, current.scoped = nil, nil, nil, false
end)

uevr.sdk.callbacks.on_script_reset(function()
    destroyScope()
end)
