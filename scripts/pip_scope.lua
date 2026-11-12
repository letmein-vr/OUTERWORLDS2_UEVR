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
--
-- Automatic lens + game zoom (2026-11-12, Borderlands 4 method; option ps_auto, default on):
--   * Lens: every OW2 sight is a mod mesh set on the weapon mesh (Mod_Socket): a body plus a reticle mesh (name
--     *_Reticle, or *_Recticle on the Holo scope), and sometimes _Hide / _Glass. The reticle of a magnifying scope is a
--     flat disc on the optical axis at the eyepiece (MCP: MOD_HR_Scope_BaseScope_Reticle = disc at X 19.7 / Z 18.1,
--     3.04 cm across - xaero's hand-tuned SR_Accurate lens was (19.2, 0, 18.05) at 3.1 cm; MOD_OA_Longburst_Prism_
--     Reticle at X 2.6 / Z 14.7, 1.96 cm). So the ocular lens goes to that disc's centre (in weapon-mesh space), sized
--     to its diameter, set back toward the eye by the per-sight "lens offset" (default 0.5 cm, as tuned) so it covers
--     the game's reticle. Per-sight offset / tilt / size trims in the panel. No flat reticle found: the manual
--     ocular settings apply.
--   * Zoom: the game's own ADS magnification - SightData.AimingFOVMagnification when bUseMagnification, else its
--     AimingFOVAdjustment, else the fire mode's FineAimMagnification / FineAimFovAdjustment (controls.lua's "Disable
--     ADS zoom" holds those neutral for the HMD view; _G.ow2OriginalZoomValue returns the game's values). The PiP
--     shows the world M times narrower than the lens appears to the eye: every frame FOV = 2*atan(lens radius / eye
--     distance / M), so moving the eye keeps the magnification. scope.lua's stick zoom is overridden while on.

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
-- automatic lens trims (per sight)
scope.setParameterDefault("lens_offset", 0.5) -- cm toward the eye from the reticle disc (xaero's SR_Accurate tuning)
scope.setParameterDefault("lens_tilt", 0.0)   -- deg, pitch about the gun's right axis on top of the 90 facing the eye
scope.setParameterDefault("lens_size", 1.0)   -- x the reticle disc's diameter
scope.setParameterDefault("reticle_depth", 0.0) -- cm toward the eye: reticle copy of a skeletal scope (no reticle part)

local MUZZLE_SOCKET = "MuzzleFlashSocket"
local LENS_MESH_DIAMETER = 5.0 -- cm: scope.lua's ocular lens = engine Cylinder (100 cm) x 0.05 x scale
local MIN_EYE_DISTANCE = 3.0   -- cm: clamp for the FOV formula
local FLAT_RATIO = 0.2         -- a reticle disc: depth (X extent) at most this x its smaller cross extent

local PREFIX = "ps_"
local SOFT_PTR_SIZE = 0x28
local POLL_S = 0.25

local layout = {
    { widgetType = "checkbox", id = "ps_enabled", label = "PiP scopes on weapons with a magnifying scope", initialValue = true },
    { widgetType = "text", id = "ps_status", label = "Sight: -" },
    { widgetType = "checkbox", id = "ps_auto", label = "Automatic lens (on the scope's reticle) + the game's zoom", initialValue = true },
    { widgetType = "text", id = "ps_auto_status", label = "Lens: -" },
    { widgetType = "checkbox", id = "ps_game_reticle", label = "Game reticle over the PiP (a copy of the scope's reticle drawn on the lens)", initialValue = true },
    { widgetType = "slider_float", id = "ps_lens_offset", label = "Lens offset toward the eye (cm) - this sight only", initialValue = 0.5, range = { -10.0, 10.0 } },
    { widgetType = "slider_float", id = "ps_lens_tilt", label = "Lens tilt forward / back (deg) - this sight only", initialValue = 0.0, range = { -60.0, 60.0 } },
    { widgetType = "slider_float", id = "ps_lens_size", label = "Lens size (x the reticle) - this sight only", initialValue = 1.0, range = { 0.5, 2.5 } },
    { widgetType = "slider_float", id = "ps_reticle_depth", label = "Reticle depth (cm toward the eye) - scopes without a reticle part, this sight only", initialValue = 0.0, range = { 0.0, 40.0 } },
    { widgetType = "slider_float", id = "ps_magnification", label = "Magnification (x the game's)", initialValue = 1.0, range = { 0.5, 3.0 } },
    { widgetType = "spacing" },
    { widgetType = "text", label = "Settings below are for the sight currently equipped (saved per sight); with the automatic lens on, the ocular lens location / rotation / scale and the zoom FOVs are not used" },
}
for _, widget in ipairs(scope.getConfigWidgets(PREFIX)) do table.insert(layout, widget) end
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 2.8, label = "PiP Scope", layout = layout })

-- weapon / mesh = addresses; sightObj / modeObj / meshObj = the objects (game zoom, auto lens); lens = { loc, diameter }
local current = { weapon = nil, mesh = nil, sightID = nil, scoped = false, instance = nil, status = "",
    sightObj = nil, modeObj = nil, meshObj = nil, lens = nil, zoom = nil }
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
    return sightAt(mode, sightOffset + SOFT_PTR_SIZE) or sightAt(mode, sightOffset), mode
end

-- ---------------------------------------------------------------------------------------------
-- Automatic lens: the fitted scope's reticle disc
-- ---------------------------------------------------------------------------------------------
local staticMeshComponentClass = nil

local function componentT(c)
    return kismet_math_library:MakeTransform(c:K2_GetComponentLocation(), c:K2_GetComponentRotation(), c:K2_GetComponentScale())
end

-- the flattest reticle-named static mesh under the weapon mesh: { loc = weapon-mesh-space centre, diameter, name } or nil
local function findReticleLens(mesh)
    if staticMeshComponentClass == nil then staticMeshComponentClass = uevrUtils.get_class("Class /Script/Engine.StaticMeshComponent") end
    local best, bestFlat = nil, nil
    local function visit(parent, depth)
        local children = parent.AttachChildren
        if children == nil or depth > 2 then return end
        for i = 1, #children do
            local child = children[i]
            pcall(function()
                if staticMeshComponentClass ~= nil and child:is_a(staticMeshComponentClass) and child.StaticMesh ~= nil then
                    local name = child.StaticMesh:get_fname():to_string()
                    local lower = name:lower()
                    if lower:find("reticle", 1, true) or lower:find("recticle", 1, true) then
                        local b = child.StaticMesh:GetBounds()
                        local e = b.BoxExtent
                        local cross = math.min(e.Y, e.Z)
                        local flat = cross > 0.1 and e.X / cross or math.huge
                        if flat <= FLAT_RATIO and (bestFlat == nil or flat < bestFlat) then
                            bestFlat = flat
                            best = { component = child, origin = b.Origin, cross = cross, name = name }
                        end
                    end
                end
            end)
            visit(child, depth + 1)
        end
    end
    visit(mesh, 1)
    if best == nil then return nil end
    -- the disc's centre and width in the weapon mesh's own space (the ocular lens is attached to the mesh root)
    local meshT = componentT(mesh)
    local reticleT = componentT(best.component)
    local o = best.origin
    local world = kismet_math_library:TransformLocation(reticleT, uevrUtils.vector(o.X, o.Y, o.Z))
    local p = kismet_math_library:InverseTransformLocation(meshT, world)
    local scale = 1.0
    pcall(function() scale = best.component:K2_GetComponentScale().Y / mesh:K2_GetComponentScale().Y end)
    -- Rear limit: the scope part that encloses the reticle can end just behind it, with its glass on that rear face
    -- (MR_Standard: MOD_MRS_Scope_Telescopic, glass = its material slot "Reticle", rear face at X 10.48 vs the reticle at
    -- 10.62 - MCP 2026-11-12: the face covered the PiP lens and the reticle copy). The lens never goes behind such a face.
    -- Every part counts, including the ones the game hides while aiming (MOD_MRS_Telescopic_Front on Sight_Hide_Socket
    -- has a glass slot too): moving the lens toward the eye never hides it.
    local rears = {} -- rear faces (weapon-mesh X) of the parts enclosing the reticle, in front of it (toward the eye)
    local function scan(parent, depth)
        local children = parent.AttachChildren
        if children == nil or depth > 2 then return end
        for i = 1, #children do
            local child = children[i]
            pcall(function()
                if child ~= best.component and child:is_a(staticMeshComponentClass) and child.StaticMesh ~= nil then
                    local childT = componentT(child)
                    local q = kismet_math_library:InverseTransformLocation(childT, world) -- reticle centre in the part's space
                    local b = child.StaticMesh:GetBounds()
                    local bo, be = b.Origin, b.BoxExtent
                    if math.abs(q.X - bo.X) <= be.X and math.abs(q.Y - bo.Y) <= be.Y and math.abs(q.Z - bo.Z) <= be.Z then
                        -- the part's rear face on the axis, in weapon-mesh space
                        local rearWorld = kismet_math_library:TransformLocation(childT, uevrUtils.vector(bo.X - be.X, q.Y, q.Z))
                        local rx = kismet_math_library:InverseTransformLocation(meshT, rearWorld).X
                        if rx < p.X then table.insert(rears, rx) end
                    end
                end
            end)
            scan(child, depth + 1)
        end
    end
    scan(mesh, 1)
    return { loc = { X = p.X, Y = p.Y, Z = p.Z }, diameter = 2.0 * best.cross * scale, name = best.name,
        component = best.component, origin = { X = o.X, Y = o.Y, Z = o.Z }, rears = rears }
end

-- Lens X (weapon-mesh space) for a lens offset: reticle - offset, unless a part enclosing the reticle ends just in front
-- of that spot (within REAR_FACE_WINDOW_CM toward the eye, or between it and the reticle): then the lens goes
-- REAR_FACE_GAP_CM in front of that end, so the end - and its glass - cannot cover the lens or the reticle copy (0.1 cm
-- in front of the lens). Ends further toward the eye are tube openings the lens sits well inside of (e.g. SR_Damage
-- Telescopic, confirmed working at reticle - 0.5). One pass from the reticle toward the eye: chained ends are handled.
local REAR_FACE_GAP_CM = 0.3
local REAR_FACE_WINDOW_CM = 1.0
local function lensX(lens, offset)
    local x = lens.loc.X - offset
    local faces = {}
    for _, f in ipairs(lens.rears or {}) do table.insert(faces, f) end
    table.sort(faces, function(a, b) return a > b end)
    for _, f in ipairs(faces) do
        if f < lens.loc.X and f > x - REAR_FACE_WINDOW_CM then x = math.min(x, f - REAR_FACE_GAP_CM) end
    end
    return x
end

-- ---------------------------------------------------------------------------------------------
-- Game reticle over the PiP (option ps_game_reticle, 2026-11-12). The game's reticle is a static mesh disc (*_Reticle)
-- with a TRANSLUCENT UNLIT material (MM_Sight_Reticle_A, texture param "Reticle"). The PiP lens sits just in front of
-- that disc (toward the eye), so the game's own disc is behind the PiP. Instead a COPY of the reticle mesh with the
-- same material is drawn RETICLE_COPY_GAP_CM in front of the lens while the PiP shows: the reticle is on top of the
-- picture and no game part has to change.
-- Why not move the lens behind the game's disc: the scope glass sits in front of the disc and is opaque
-- (MM_W_Glass_Simple / MI_*_Scope_Glass), and it is built differently on every scope - its own mesh
-- (MOD_SR_Telescopic_Glass), a slot of the game's "hide while aiming" housing (MOD_HR_Scope_BaseScope_Hide), or a
-- slot of the scope body itself (MOD_MRS_Scope_Telescopic slot "Reticle" = MI_P_MRS_Scope_Glass) - MCP 2026-11-12.
-- The copy's material is a dynamic instance with the eye-relief darkening opened up (scalar EyeRelief_Radius 0.456 at
-- EyeRelief_Dist -6, GradientDensity 15: the disc darkens unless the eye is on the axis, which the flat camera always
-- is). The capture hides it like every other child of the weapon mesh.
-- ---------------------------------------------------------------------------------------------
local RETICLE_COPY_GAP_CM = 0.1  -- copy this far in front of (toward the eye from) the PiP lens
local OPEN_EYE_RELIEF = 1000.0
local EYE_RELIEF_PARAM = "EyeRelief_Radius"

local function gameReticleEnabled() return configui.getValue("ps_auto") ~= false and configui.getValue("ps_game_reticle") ~= false end

local reticleCopy = { component = nil, shown = nil }

local function destroyReticleCopy()
    if reticleCopy.component ~= nil then
        local c = reticleCopy.component
        pcall(function() uevrUtils.detachAndDestroyComponent(c, true, true) end)
    end
    reticleCopy = { component = nil, shown = nil }
end

-- the copy's transform on the weapon mesh: the game reticle's, moved along the mesh X (the scope axis) to just in front
-- of the lens (lens = disc - offset)
local function placeReticleCopy(copy, mesh, lens, offset)
    local rel = kismet_math_library:MakeRelativeTransform(componentT(lens.component), componentT(mesh))
    local t, s = rel.Translation, rel.Scale3D
    local r = kismet_math_library:Quat_Rotator(rel.Rotation)
    uevrUtils.set_component_relative_transform(copy, { X = t.X - offset - RETICLE_COPY_GAP_CM, Y = t.Y, Z = t.Z },
        { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, { X = s.X, Y = s.Y, Z = s.Z })
end

local function createReticleCopy(mesh, lens, offset)
    destroyReticleCopy()
    local copy = uevrUtils.createStaticMeshComponent(lens.component.StaticMesh, { visible = false, collisionEnabled = false })
    if copy == nil then return end
    reticleCopy.component = copy
    copy:K2_AttachTo(mesh, uevrUtils.fname_from_string(""), 0, false)
    pcall(function() copy:SetCastShadow(false) end)
    placeReticleCopy(copy, mesh, lens, offset)
    pcall(function()
        local material = lens.component:GetMaterial(0)
        if material == nil then return end
        -- an earlier version (2026-11-12) put a dynamic instance named ow2_pip_reticle on the GAME's reticle; it stays on
        -- that component across script resets. Put the game reticle back on its own material and copy from that (a
        -- dynamic instance made from a dynamic instance is not reliable).
        if string.find(material:get_fname():to_string(), "ow2_pip_reticle", 1, true) ~= nil and material.Parent ~= nil then
            local original = material.Parent
            pcall(function() lens.component:SetMaterial(0, original) end)
            material = original
        end
        local mid = copy:CreateDynamicMaterialInstance(0, material, uevrUtils.fname_from_string("ow2_pip_reticle_copy"))
        if mid ~= nil then
            mid:SetScalarParameterValue(uevrUtils.fname_from_string(EYE_RELIEF_PARAM), OPEN_EYE_RELIEF)
            -- the off-axis ring's colour (black on MI_Sight_Reticle_Holo_Telescopic_P_Telescopic, tinted on others):
            -- transparent, in case the ring still shows
            mid:SetVectorParameterValue(uevrUtils.fname_from_string("EyeReliefColor"), uevrUtils.color_from_rgba(0, 0, 0, 0))
        end
    end)
end

-- shown only while the PiP shows (the game's own reticle is visible otherwise)
local function showReticleCopy(show)
    local c = reticleCopy.component
    if c == nil or reticleCopy.shown == show then return end
    if not isAlive(c) then reticleCopy = { component = nil, shown = nil } return end
    pcall(function() c:SetVisibility(show, false) end)
    reticleCopy.shown = show
end

-- ---------------------------------------------------------------------------------------------
-- Scopes whose reticle is a material SECTION of a skeletal scope mesh (2026-11-12): the base SR_Damage scope is one
-- SkeletalMeshComponent SK_MOD_SR_Scope_Base with slots Reticle1 (MI_Sight_Reticle_Holo_Telescopic__OA), the body and
-- ScopeGlassSG1 - no reticle part, so no automatic lens (the manual ocular settings apply). The reticle's position inside
-- the mesh cannot be read (cooked without CPU vertex data: GetRefPosePosition returns 0). So the reticle copy here is a
-- copy of the whole scope mesh with every section but the reticle hidden (ShowMaterialSection hides by material slot),
-- at the scope's own transform moved toward the eye by the per-sight "Reticle depth" (scope parameter reticle_depth),
-- tuned once in the headset until the reticle sits just in front of the PiP lens.
-- ---------------------------------------------------------------------------------------------
local skeletalMeshComponentClass = nil

-- { component, slot, name } of a skeletal scope part with a reticle material slot (MI_Sight_Reticle_*), or nil
local function findSkeletalReticle(mesh)
    if skeletalMeshComponentClass == nil then skeletalMeshComponentClass = uevrUtils.get_class("Class /Script/Engine.SkeletalMeshComponent") end
    if skeletalMeshComponentClass == nil then return nil end
    local found = nil
    local function visit(parent, depth)
        local children = parent.AttachChildren
        if children == nil or depth > 2 or found ~= nil then return end
        for i = 1, #children do
            local child = children[i]
            pcall(function()
                if found == nil and child:is_a(skeletalMeshComponentClass) and child.SkeletalMesh ~= nil then
                    for slot = 0, child:GetNumMaterials() - 1 do
                        local m = child:GetMaterial(slot)
                        local name = m ~= nil and m:get_fname():to_string() or ""
                        if name:lower():find("reticle", 1, true) then
                            found = { component = child, slot = slot, name = child.SkeletalMesh:get_fname():to_string(),
                                slots = child:GetNumMaterials() }
                            return
                        end
                    end
                end
            end)
            visit(child, depth + 1)
        end
    end
    visit(mesh, 1)
    return found
end

local function placeSkeletalReticleCopy(copy, mesh, skel, depth)
    local rel = kismet_math_library:MakeRelativeTransform(componentT(skel.component), componentT(mesh))
    local t, s = rel.Translation, rel.Scale3D
    local r = kismet_math_library:Quat_Rotator(rel.Rotation)
    uevrUtils.set_component_relative_transform(copy, { X = t.X - depth, Y = t.Y, Z = t.Z },
        { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, { X = s.X, Y = s.Y, Z = s.Z })
end

local function createSkeletalReticleCopy(mesh, skel, depth)
    destroyReticleCopy()
    local copy = uevrUtils.createSkeletalMeshComponent(skel.component.SkeletalMesh, { visible = false, collisionEnabled = false })
    if copy == nil then return end
    reticleCopy.component = copy
    pcall(function() copy:SetVisibility(false, false) end) -- (this creator ignores options.visible)
    pcall(function() copy:SetCollisionEnabled(0) end)
    copy:K2_AttachTo(mesh, uevrUtils.fname_from_string(""), 0, false)
    pcall(function() copy:SetCastShadow(false) end)
    placeSkeletalReticleCopy(copy, mesh, skel, depth)
    -- only the reticle section: every other material slot hidden, on every LOD (section index -1 = by slot)
    local lods = 1
    pcall(function() lods = math.max(1, copy:GetNumLODs()) end)
    for slot = 0, skel.slots - 1 do
        if slot ~= skel.slot then
            for lod = 0, lods - 1 do pcall(function() copy:ShowMaterialSection(slot, -1, false, lod) end) end
        end
    end
    pcall(function()
        local material = skel.component:GetMaterial(skel.slot)
        if material == nil then return end
        local mid = copy:CreateDynamicMaterialInstance(skel.slot, material, uevrUtils.fname_from_string("ow2_pip_reticle_copy"))
        if mid ~= nil then
            mid:SetScalarParameterValue(uevrUtils.fname_from_string(EYE_RELIEF_PARAM), OPEN_EYE_RELIEF)
            mid:SetVectorParameterValue(uevrUtils.fname_from_string("EyeReliefColor"), uevrUtils.color_from_rgba(0, 0, 0, 0))
        end
    end)
end

-- every poll for a skeletal scope: the copy at the per-sight depth (created once, re-placed when the depth changes)
local function applySkeletalReticle(sightID)
    local skel = current.skel
    if skel == nil or not gameReticleEnabled() or not isAlive(skel.component) or not isAlive(current.meshObj) then
        if skel ~= nil and reticleCopy.component ~= nil then destroyReticleCopy() end
        return
    end
    local depth = scope.getParameter(sightID, "reticle_depth") or 0.0
    if reticleCopy.component == nil or not isAlive(reticleCopy.component) then
        createSkeletalReticleCopy(current.meshObj, skel, depth)
    else
        placeSkeletalReticleCopy(reticleCopy.component, current.meshObj, skel, depth)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Game zoom: the magnification the flat game applies while aiming down this sight
-- ---------------------------------------------------------------------------------------------
local function original(obj, field)
    if obj == nil then return nil end
    if _G.ow2OriginalZoomValue ~= nil then
        local ok, v = pcall(_G.ow2OriginalZoomValue, obj, field)
        if ok then return v end
    end
    local v = nil
    pcall(function() v = obj[field] end)
    return v
end

-- the flat game's camera FOV without zoom (the FPV camera on the arms), for sights that zoom by a FOV adjustment
local fpvCameraClass = nil
local function baseFOV()
    local fov = 90.0
    pcall(function()
        if fpvCameraClass == nil then fpvCameraClass = uevrUtils.get_class("Class /Script/Arkansas.FPVCameraComponent") end
        local arms = uevr.api:get_local_pawn(0).FPVMesh
        for _, c in ipairs(arms.AttachChildren or {}) do
            if fpvCameraClass ~= nil and c:is_a(fpvCameraClass) then fov = c.FieldOfView return end
        end
    end)
    return fov
end

-- magnification (>= 1) and where it came from
local function gameZoom(sight, mode)
    local function fromAdjustment(adj)
        local base = baseFOV()
        local zoomed = math.max(1.0, base + adj)
        return math.tan(math.rad(base) * 0.5) / math.tan(math.rad(zoomed) * 0.5)
    end
    if sight ~= nil then
        if original(sight, "bUseMagnification") == true then
            local m = original(sight, "AimingFOVMagnification")
            if type(m) == "number" and m > 0 then return m, "sight magnification" end
        end
        local adj = original(sight, "AimingFOVAdjustment")
        if type(adj) == "number" and adj < -0.01 then return fromAdjustment(adj), "sight FOV adjustment" end
    end
    local m = original(mode, "FineAimMagnification")
    if type(m) == "number" and m > 1.001 then return m, "fire mode magnification" end
    local adj = original(mode, "FineAimFovAdjustment")
    if type(adj) == "number" and adj < -0.01 then return fromAdjustment(adj), "fire mode FOV adjustment" end
    return 1.0, "no game zoom"
end

local function autoEnabled() return configui.getValue("ps_auto") ~= false end

local function setAutoStatus(text)
    pcall(function() configui.setLabel("ps_auto_status", text) end)
end

-- ocular lens on the reticle disc (+ per-sight trims); re-run every poll so a manual-widget drag cannot leave it off
local function applyAutoLens(instance, sightID)
    local lens = current.lens
    if lens == nil then return end
    -- effective offset: in front of any scope-part end that would cover the lens (see lensX)
    local offset = lens.loc.X - lensX(lens, scope.getParameter(sightID, "lens_offset") or 0.5)
    local tilt = scope.getParameter(sightID, "lens_tilt") or 0.0
    local size = scope.getParameter(sightID, "lens_size") or 1.0
    instance:setOcularLensRelativeLocation({ lens.loc.X - offset, lens.loc.Y, lens.loc.Z })
    instance:setOcularLensRelativeRotation({ 90.0 + tilt, 0.0, 0.0 })
    instance:setOcularLensScale(lens.diameter * size / LENS_MESH_DIAMETER)
    -- game reticle over the PiP: a copy of the reticle just in front of the lens (created once per scope, kept in place)
    if gameReticleEnabled() and isAlive(lens.component) and isAlive(current.meshObj) then
        if reticleCopy.component == nil or not isAlive(reticleCopy.component) then
            createReticleCopy(current.meshObj, lens, offset)
        else
            placeReticleCopy(reticleCopy.component, current.meshObj, lens, offset)
        end
    elseif reticleCopy.component ~= nil then
        destroyReticleCopy()
    end
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
    for id, key in pairs({ ps_lens_offset = "lens_offset", ps_lens_tilt = "lens_tilt", ps_lens_size = "lens_size", ps_reticle_depth = "reticle_depth" }) do
        local value = scope.getParameter(sightID, key)
        if value ~= nil then pcall(function() configui.setValue(id, value, true) end) end
    end
end

local function destroyScope()
    pcall(destroyReticleCopy)
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
    local sight, mode = nil, nil
    if weapon ~= nil and configui.getValue("ps_enabled") ~= false then sight, mode = effectiveSight(weapon) end
    local sightID = sight ~= nil and sight:get_fname():to_string() or nil
    local scoped = sight ~= nil and sight.bIsScoped == true

    -- rebuild when the weapon, its mesh or its sight changes, or the scope's components died
    local weaponAddress, meshAddress = addressOf(weapon), addressOf(mesh)
    local changed = weaponAddress ~= current.weapon or meshAddress ~= current.mesh or sightID ~= current.sightID or scoped ~= current.scoped
    if not changed and current.instance ~= nil and not isAlive(current.instance:getOcularLensComponent()) then changed = true end
    if not changed then
        if current.instance ~= nil then
            hideWeaponFromCapture(current.instance, mesh)
            -- scope mods can attach after the weapon: look for the reticle again until found
            if autoEnabled() and current.lens == nil and isAlive(mesh) then
                current.lens = findReticleLens(mesh)
                if current.lens ~= nil then loadSettingsIntoPanel(sightID) end
            end
            if autoEnabled() and current.lens ~= nil then pcall(applyAutoLens, current.instance, sightID) end
            -- no reticle part: a reticle section in a skeletal scope mesh (found late too, like the mods)
            if autoEnabled() and current.lens == nil and current.skel == nil and isAlive(mesh) then
                pcall(function() current.skel = findSkeletalReticle(mesh) end)
            end
            if autoEnabled() and current.lens == nil and current.skel ~= nil then pcall(applySkeletalReticle, sightID) end
            setStatus(current.status .. " | " .. eyeDistanceText(current.instance, sightID))
            if not autoEnabled() then
                setAutoStatus("Lens: off (manual settings below)")
            elseif current.lens ~= nil then
                setAutoStatus(string.format("Lens on %s (X %.1f Y %.1f Z %.1f, %.2f cm) | game zoom %.2fx (%s)", current.lens.name,
                    current.lens.loc.X, current.lens.loc.Y, current.lens.loc.Z, current.lens.diameter, current.zoom or 1.0, current.zoomSource or "-"))
            elseif current.skel ~= nil then
                setAutoStatus(string.format("Lens: manual (reticle is part of the scope mesh %s - set 'Reticle depth', now %.1f cm) | game zoom %.2fx (%s)",
                    current.skel.name, scope.getParameter(sightID, "reticle_depth") or 0.0, current.zoom or 1.0, current.zoomSource or "-"))
            else
                setAutoStatus(string.format("Lens: no reticle disc on this scope (manual settings below) | game zoom %.2fx (%s)", current.zoom or 1.0, current.zoomSource or "-"))
            end
        end
        return
    end

    -- the status shows what was detected even if the scope below fails to build
    local status = "Sight: " .. (sightID or "none") .. (scoped and " (scoped)" or (sightID ~= nil and " (not scoped)" or ""))
    setStatus(status)
    destroyScope()
    -- recorded before building, so a scope that fails to build is not retried every poll (only on the next change)
    current.weapon, current.mesh, current.sightID, current.scoped = weaponAddress, meshAddress, sightID, scoped
    current.sightObj, current.modeObj, current.meshObj, current.lens, current.zoom, current.zoomSource = sight, mode, mesh, nil, nil, nil
    current.skel = nil
    if scoped and isAlive(mesh) then
        pcall(function() current.zoom, current.zoomSource = gameZoom(sight, mode) end)
        pcall(function() current.lens = findReticleLens(mesh) end)
        if current.lens == nil then pcall(function() current.skel = findSkeletalReticle(mesh) end) end
        local atMuzzle = false
        local ok, err = pcall(function()
            current.instance = scope.new(sightID)
            current.instance:attachTo(mesh)
            atMuzzle = placeObjectiveAtMuzzle(current.instance, mesh, sightID)
            if autoEnabled() and current.lens ~= nil then applyAutoLens(current.instance, sightID) end
            if autoEnabled() and current.lens == nil and current.skel ~= nil then pcall(applySkeletalReticle, sightID) end
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

-- the game's magnification, every frame while the PiP shows: the picture is M times narrower than the lens looks
local function applyGameZoomFOV(instance)
    local lens = current.lens
    if current.zoom == nil then return end
    if lens == nil then
        -- no reticle disc (manual lens, e.g. a skeletal scope): the lens radius from the manual ocular scale
        local s = scope.getParameter(current.sightID, "ocular_lens_scale")
        if type(s) ~= "number" or s <= 0 then return end
        lens = { diameter = s * LENS_MESH_DIAMETER }
    end
    local head = controllers.getControllerLocation(2)
    local ocular = instance:getOcularLensComponent()
    if head == nil or ocular == nil then return end
    local l = ocular:K2_GetComponentLocation()
    local dx, dy, dz = l.X - head.X, l.Y - head.Y, l.Z - head.Z
    local d = math.max(MIN_EYE_DISTANCE, math.sqrt(dx * dx + dy * dy + dz * dz))
    local size = current.lens ~= nil and (scope.getParameter(current.sightID, "lens_size") or 1.0) or 1.0 -- manual scale is the total
    local radius = 0.5 * lens.diameter * size
    local m = current.zoom * (configui.getValue("ps_magnification") or 1.0)
    instance:setFOV(math.max(0.2, 2.0 * math.deg(math.atan((radius / d) / math.max(m, 0.01)))))
end

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    local now = os.clock()
    if now >= nextPoll then
        nextPoll = now + POLL_S
        local ok, err = pcall(update)
        if not ok then
            setStatus("Error: " .. tostring(err))
            logError(tostring(err))
        end
    end
    local instance = current.instance
    local displaying = instance ~= nil and instance:isDisplaying()
    if displaying and autoEnabled() then
        local ok, err = pcall(applyGameZoomFOV, instance)
        if not ok then logError("game zoom: " .. tostring(err)) end
    end
    -- game reticle over the PiP: scope glass hidden + reticle eye relief opened only while looking through
    local ok, err = pcall(showReticleCopy, displaying and gameReticleEnabled())
    if not ok then logError("game reticle: " .. tostring(err)) end
end)
configui.onUpdate("ps_game_reticle", function(value) current.weapon = nil end) -- rebuild: lens moves in front / behind

-- per-sight lens trims (saved for the sight currently equipped) and the auto toggle; applied on the next poll
local function onLensTrim(key)
    return function(value)
        local id = current.instance ~= nil and current.sightID or nil
        if id == nil then return end
        scope.setParameter(id, key, value)
    end
end
configui.onUpdate("ps_lens_offset", onLensTrim("lens_offset"))
configui.onUpdate("ps_lens_tilt", onLensTrim("lens_tilt"))
configui.onUpdate("ps_lens_size", onLensTrim("lens_size"))
configui.onUpdate("ps_reticle_depth", onLensTrim("reticle_depth"))
-- toggling the auto lens: rebuild so the manual (stored) ocular settings come back when it goes off
configui.onUpdate("ps_auto", function(value) current.weapon = nil end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    destroyScope()
    current.weapon, current.mesh, current.sightID, current.scoped = nil, nil, nil, false
end)

uevr.sdk.callbacks.on_script_reset(function()
    destroyScope()
end)
