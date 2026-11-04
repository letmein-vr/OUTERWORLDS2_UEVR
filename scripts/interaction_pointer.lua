-- Left-hand interaction pointer for The Outer Worlds 2 (2026-09-29).
--
-- OW2 picks its interaction target (pickup/loot/door prompt) natively in PlayerInteractionComponent along
-- the camera view, and the camera takes the pawn's control rotation (camera_stabilize.lua sets
-- FPVCamera.bUsePawnControlRotation). With the pointer on, a laser is drawn from the left controller; while it
-- is on an INTERACTABLE actor within range, the control rotation is aimed from the camera at the laser's hit
-- point, so the game's own targeting selects what the laser points at and X interacts as normal (prompt,
-- hold-to-interact, steal checks all stay the game's). On anything else the camera is left alone.
--
-- input.lua normally writes the control rotation from the HMD every tick (aim method HEAD); while steering it
-- is told to stand down with setOverrideAimMethod(UEVR), the same mechanism montage.lua uses. Weapon aim is
-- unaffected (OW2AimFix aims from the weapon). While steering, the game camera (so HUD markers) and the
-- walking direction follow the pointed direction; that is why steering is limited to interactables.

local uevrUtils   = require('libs/uevr_utils')
local configui    = require('libs/configui')
local controllers = require('libs/controllers')
local input       = require('libs/input')

-- Section of the merged "Outer Worlds 2 VR" panel (see scripts/zz_ow2_vr_panel.lua)
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 7, label = "Interaction Pointer", layout = {
            { widgetType = "checkbox", id = "ip_enabled", label = "Left-hand interaction pointer", initialValue = false },
            { widgetType = "checkbox", id = "ip_show_laser", label = "Show pointer", initialValue = true },
            { widgetType = "combo", id = "ip_style", label = "Pointer style", initialValue = 1, selections = {"Laser", "Reticule", "Laser + reticule"} },
            { widgetType = "slider_float", id = "ip_reticle_size", label = "Reticule size", initialValue = 0.5, range = {0.1, 2.0} },
            { widgetType = "combo", id = "ip_color", label = "Pointer colour", initialValue = 1, selections = {"Blue", "Red", "White"} },
            { widgetType = "slider_float", id = "ip_line_thickness", label = "Line thickness (brighter)", initialValue = 0.0, range = {0.0, 5.0} },
            { widgetType = "slider_float", id = "ip_range", label = "Pointer range (cm)", initialValue = 500.0, range = {100.0, 2000.0} },
            { widgetType = "text", id = "ip_status", label = "Status: off" },
            { widgetType = "spacing" },
            { widgetType = "text", label = "-- Pointer angle / position (relative to the left controller; laser and targeting both follow)" },
            { widgetType = "slider_float", id = "ip_rot_pitch", label = "Pitch (up/down)", initialValue = 0.0, range = {-90.0, 90.0} },
            { widgetType = "slider_float", id = "ip_rot_yaw", label = "Yaw (left/right)", initialValue = 0.0, range = {-90.0, 90.0} },
            { widgetType = "slider_float", id = "ip_rot_roll", label = "Roll", initialValue = 0.0, range = {-180.0, 180.0} },
            { widgetType = "slider_float", id = "ip_off_x", label = "Offset forward (cm)", initialValue = 0.0, range = {-20.0, 20.0} },
            { widgetType = "slider_float", id = "ip_off_y", label = "Offset right (cm)", initialValue = 0.0, range = {-20.0, 20.0} },
            { widgetType = "slider_float", id = "ip_off_z", label = "Offset up (cm)", initialValue = 0.0, range = {-20.0, 20.0} },
}})

-- pointer colour (panel "Pointer colour"); a change rebuilds the laser/reticule, since ShapeColor only reaches
-- the renderer when the component's render state is rebuilt
local POINTER_COLORS = { "#30A0FFFF", "#FF3030FF", "#FFFFFFFF" } -- blue, red, white
local LASER_COLOR = POINTER_COLORS[1]
local appliedColorIndex = nil
local appliedThickness = nil -- line thickness applied to the current laser/reticule (ShapeComponent.SetLineThickness)

-- colours are 8-bit and white is already 255: thicker lines are what makes the pointer read brighter
local function applyLineThickness(component)
    local t = configui.getValue("ip_line_thickness") or 0.0
    pcall(function() component:SetLineThickness(t) end)
end
local MAX_TRACE   = 3000.0

-- The laser is a thin CapsuleComponent owned by this script. It is NOT built with libs/laser: that lib
-- gates every call on uevrUtils.getValid (UEVR_UObjectHook.exists), which rejects freshly created components
-- on OW2 for a while (deferred adoption), so its attach/length/visibility/destroy calls silently did nothing
-- and the old "is it still valid?" check here recreated (and leaked) a capsule + actor every tick.
local capsule = nil         -- laser component (direct reference, never exists()-gated)
local capsuleParent = nil   -- address of the controller component it is attached to
local steering = false      -- we currently own the control rotation (input.lua override set)
local lastStatus = nil

-- per-tick work is kept to the trace + controller pose; everything else only runs on change or at a low rate
local LENGTH_EPSILON = 0.5          -- cm of half-length change before the capsule is resized (resize rebuilds its render state)
local ACTOR_RESOLVE_INTERVAL = 0.1  -- s between BreakHitResult calls (hit actor lookup)
local AIM_METHOD_POLL_INTERVAL = 0.25
local appliedHalf = nil             -- capsule half-length last applied
local appliedOffsetKey = nil        -- slider offset last applied to the capsule
local appliedVisible = nil          -- capsule visibility last applied
local nextActorResolve = 0
local resolvedActor = nil           -- hit actor from the last resolve (only its address is used between resolves)
local resolvedActorAddress = nil
local resolvedActorName = nil
local nextAimMethodPoll = 0
local aimMethodOverridden = false

local function status(text)
    if text ~= lastStatus then
        lastStatus = text
        pcall(function() configui.setLabel("ip_status", "Status: " .. text) end)
    end
end

local function stopSteering()
    if steering then
        steering = false
        pcall(function() input.setOverrideAimMethod(nil) end)
    end
end

-- Reticule: a small wire SphereComponent (same shape rendering and colour as the laser capsule) placed in
-- WORLD space at the hit point, radius scaled with distance so it keeps the same apparent size. Same rules as
-- the capsule: created once, direct reference, never exists()-gated.
local reticle = nil
local reticleVisible = nil
local reticleRadius = nil

local function destroyReticle()
    if reticle ~= nil then
        local r = reticle
        pcall(function() uevrUtils.destroyComponent(r, true, false) end)
    end
    reticle = nil
    reticleVisible = nil
    reticleRadius = nil
end

local function destroyPointer()
    if capsule ~= nil then
        local c = capsule
        pcall(function() c:DetachFromParent(false, false) end)
        pcall(function() uevrUtils.destroyComponent(c, true, false) end) -- destroys the owner actor too
    end
    capsule = nil
    capsuleParent = nil
    appliedHalf = nil
    appliedOffsetKey = nil
    appliedVisible = nil
    destroyReticle()
end

local function ensureReticle()
    if reticle ~= nil then return reticle end
    local ok, r = pcall(function() return uevrUtils.create_component_of_class("Class /Script/Engine.SphereComponent") end)
    if not ok or r == nil then return nil end
    pcall(function()
        r:SetGenerateOverlapEvents(false)
        r:SetCollisionEnabled(0)
        r:SetRenderInMainPass(true)
        r.bRenderInDepthPass = true
        r.ShapeColor = uevrUtils.hexToColor(LASER_COLOR)
        r:SetSphereRadius(1.0, false)
        applyLineThickness(r)
        r:SetVisibility(false, false)
        r:SetHiddenInGame(false, false)
    end)
    reticle = r
    reticleVisible = false
    reticleRadius = 1.0
    return reticle
end

local function setReticleVisible(visible)
    if reticle == nil or reticleVisible == visible then return end
    pcall(function() reticle:SetVisibility(visible, false) end)
    reticleVisible = visible
end

-- place the reticule 1 cm in front of the hit surface (towards the pointer origin) so it is not buried in it
local function updateReticle(origin, target)
    local r = ensureReticle()
    if r == nil then return end
    local dist = uevrUtils.vectorDistance(origin, target)
    if dist < 1.0 then return end
    local back = 1.0 / dist
    local pos = uevrUtils.vector(target.X + (origin.X - target.X) * back, target.Y + (origin.Y - target.Y) * back, target.Z + (origin.Z - target.Z) * back)
    pcall(function() r:K2_SetWorldLocation(pos, false, reusable_hit_result, true) end)
    local radius = math.max(0.3, dist * (configui.getValue("ip_reticle_size") or 0.5) * 0.01)
    if reticleRadius == nil or math.abs(radius - reticleRadius) > reticleRadius * 0.05 then -- resize rebuilds render state
        pcall(function() r:SetSphereRadius(radius, false) end)
        reticleRadius = radius
    end
    setReticleVisible(true)
end

-- created once per controller; only a controller change (level change / rebuild) replaces it
local function addressOf(obj)
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or nil
end

local function ensurePointer(controller)
    local parentAddress = addressOf(controller)
    if capsule ~= nil and parentAddress ~= nil and capsuleParent == parentAddress then return capsule end
    destroyPointer()
    local ok, c = pcall(function() return uevrUtils.create_component_of_class("Class /Script/Engine.CapsuleComponent") end)
    if not ok or c == nil then return nil end
    pcall(function()
        c:SetCapsuleSize(0.1, 0, true)
        c:SetGenerateOverlapEvents(false)
        c:SetCollisionEnabled(0)
        c:SetRenderInMainPass(true)
        c.bRenderInDepthPass = true
        c.ShapeColor = uevrUtils.hexToColor(LASER_COLOR)
        c:SetCapsuleHalfHeight(25, false)
        applyLineThickness(c)
        c:K2_AttachTo(controller, uevrUtils.fname_from_string(""), 0, false)
        c.RelativeRotation = uevrUtils.rotator(90, 0, 0) -- capsule axis (Z) along the controller's forward (X)
        c.RelativeLocation = uevrUtils.vector(25, 0, 0)
        c:SetVisibility(true, false)
        c:SetHiddenInGame(false, false)
    end)
    capsule = c
    capsuleParent = parentAddress
    return capsule
end

-- user offset of the pointer relative to the left controller (panel sliders)
local function getPointerOffset()
    local rot = uevrUtils.rotator(configui.getValue("ip_rot_pitch") or 0, configui.getValue("ip_rot_yaw") or 0, configui.getValue("ip_rot_roll") or 0)
    local loc = uevrUtils.vector(configui.getValue("ip_off_x") or 0, configui.getValue("ip_off_y") or 0, configui.getValue("ip_off_z") or 0)
    return loc, rot
end

-- world-space pointer origin/direction: the controller transform with the user offset applied
local function getPointerRay(controllerLocation, controllerRotation)
    local offsetLoc, offsetRot = getPointerOffset()
    local f = kismet_math_library:GetForwardVector(controllerRotation)
    local r = kismet_math_library:GetRightVector(controllerRotation)
    local u = kismet_math_library:GetUpVector(controllerRotation)
    local ox, oy, oz = offsetLoc.X, offsetLoc.Y, offsetLoc.Z
    local origin = uevrUtils.vector(
        controllerLocation.X + f.X * ox + r.X * oy + u.X * oz,
        controllerLocation.Y + f.Y * ox + r.Y * oy + u.Y * oz,
        controllerLocation.Z + f.Z * ox + r.Z * oy + u.Z * oz)
    local worldRot = kismet_math_library:ComposeRotators(offsetRot, controllerRotation) -- offset in controller space
    return origin, kismet_math_library:GetForwardVector(worldRot)
end

-- The capsule's axis is its local Z: (90,0,0) turns it onto X, then the user offset rotation is applied, and it is
-- centred half its length along the offset forward from the offset origin.
-- Resizing a capsule rebuilds its render state, so it only happens when the length really changes, and the
-- relative transform only when the length or the slider offset changes. The transform goes through
-- K2_SetRelativeLocationAndRotation so it is applied immediately, not only when the parent next moves.
local function setPointerLength(c, length)
    local half = math.max(length * 0.5, 1.0)
    local offsetLoc, offsetRot = getPointerOffset()
    local offsetKey = string.format("%.2f,%.2f,%.2f,%.2f,%.2f,%.2f", offsetLoc.X, offsetLoc.Y, offsetLoc.Z, offsetRot.Pitch, offsetRot.Yaw, offsetRot.Roll)
    local lengthChanged = appliedHalf == nil or math.abs(half - appliedHalf) >= LENGTH_EPSILON
    if not lengthChanged and offsetKey == appliedOffsetKey then return end
    pcall(function()
        if lengthChanged then
            c:SetCapsuleHalfHeight(half, false)
            appliedHalf = half
        end
        local h = appliedHalf
        local f = kismet_math_library:GetForwardVector(offsetRot)
        local relLoc = uevrUtils.vector(offsetLoc.X + f.X * h, offsetLoc.Y + f.Y * h, offsetLoc.Z + f.Z * h)
        local relRot = kismet_math_library:ComposeRotators(uevrUtils.rotator(90, 0, 0), offsetRot)
        c:K2_SetRelativeLocationAndRotation(relLoc, relRot, false, reusable_hit_result, false)
        appliedOffsetKey = offsetKey
    end)
end

local function setPointerVisible(c, visible)
    if appliedVisible == visible then return end
    pcall(function() c:SetVisibility(visible, false) end)
    appliedVisible = visible
end

-- OW2 pickups use the "ItemPickup" collision profile: object type PhysicsBody, IGNORE on every trace channel
-- (Visibility, Camera, all custom trace channels), so a by-channel line trace passes straight through them to
-- the wall behind (the game finds interactables through its own octree, not collision traces). An object-type
-- trace would work but UEVR Lua cannot pass the TArray<EObjectTypeQuery> ("Invalid argument type for
-- ArrayProperty"), so trace BY PROFILE: "BlockAllDynamic" traces as a WorldDynamic object, and ItemPickup
-- BLOCKS WorldDynamic (walls do too, so it still stops at walls). Thin sphere sweep so small items are easy.
local TRACE_PROFILE = "BlockAllDynamic"
local SWEEP_RADIUS = 4.0
local pointerHitResult = nil
local traceProfileName = nil
local traceFailed = false

local function pointerTrace(origin, direction, pawn)
    local endLocation = uevrUtils.vector(origin.X + direction.X * MAX_TRACE, origin.Y + direction.Y * MAX_TRACE, origin.Z + direction.Z * MAX_TRACE)
    local world = uevrUtils.get_world()
    if world == nil then return nil, endLocation end
    if pointerHitResult == nil then
        pointerHitResult = uevrUtils.get_reuseable_struct_object("ScriptStruct /Script/Engine.HitResult")
    end
    local hit = false
    local ok, err = pcall(function()
        if traceProfileName == nil then traceProfileName = uevrUtils.fname_from_string(TRACE_PROFILE) end
        -- bTraceComplex: level props (lockers, shelves) use simple box collision that fills their open interior,
        -- so a simple trace stops at an invisible box in front of items inside them; complex = visible polygons
        hit = kismet_system_library:SphereTraceSingleByProfile(world, origin, endLocation, SWEEP_RADIUS, traceProfileName,
            true, { pawn }, 0, pointerHitResult, true, zero_color, zero_color, 0.0)
    end)
    if not ok then
        traceFailed = true -- fall back to a Visibility line trace (walls/doors only, no pickups)
        local fallbackOk, fallbackHit, fallbackEnd = pcall(uevrUtils.getLineTraceHitResult, origin, direction, 0, false, { pawn }, nil, MAX_TRACE)
        if fallbackOk then return fallbackHit, fallbackEnd or endLocation end
        return nil, endLocation
    end
    if hit then return pointerHitResult, uevrUtils.vector(pointerHitResult.Location) end
    return nil, endLocation
end

-- Steering moves the game camera (HUD markers etc. follow it), so only steer while the laser is on something
-- the game can interact with: an actor implementing InteractionInterface (pickups, interactable actors) or
-- carrying an InteractableComponent (doors, containers, terminals). Cached per actor address.
local interactionInterface = nil
local interactableComponentClass = nil
local interactableCache = {}   -- address -> bool
local interactableCacheSize = 0

local function isInteractable(actor)
    if actor == nil then return false end
    local address = addressOf(actor)
    if address == nil then return false end
    local cached = interactableCache[address]
    if cached ~= nil then return cached end

    if interactionInterface == nil then interactionInterface = uevrUtils.get_class("Class /Script/Arkansas.InteractionInterface") end
    if interactableComponentClass == nil then interactableComponentClass = uevrUtils.get_class("Class /Script/Arkansas.InteractableComponent") end
    local result = false
    pcall(function()
        if interactionInterface ~= nil and kismet_system_library:DoesImplementInterface(actor, interactionInterface) then result = true end
    end)
    if not result then
        pcall(function()
            if interactableComponentClass ~= nil and actor:GetComponentByClass(interactableComponentClass) ~= nil then result = true end
        end)
    end

    if interactableCacheSize > 512 then interactableCache = {}; interactableCacheSize = 0 end
    interactableCache[address] = result
    interactableCacheSize = interactableCacheSize + 1
    return result
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if configui.getValue("ip_enabled") ~= true then
        stopSteering()
        if capsule ~= nil then destroyPointer() end
        status("off")
        return
    end

    local pawn = uevr.api:get_local_pawn(0)
    local pc = uevr.api:get_player_controller(0)
    local controller = controllers.getController(Handed.Left, true)
    if pawn == nil or pc == nil or uevrUtils.getValid(controller) == nil then
        stopSteering()
        status("waiting for pawn/controller")
        return
    end

    -- left hand is on the weapon (two_handed.lua): no laser, no steering
    if _G.isTwoHandingActive == true then
        stopSteering()
        if capsule ~= nil then setPointerVisible(capsule, false) end
        setReticleVisible(false)
        status("hidden (two-handing)")
        return
    end

    -- a montage (interactables, conversations) currently owns the aim method: stay out of its way
    local now = os.clock()
    if now >= nextAimMethodPoll then
        nextAimMethodPoll = now + AIM_METHOD_POLL_INTERVAL
        aimMethodOverridden = uevrUtils.getUEVRParam_int("VR_AimMethod", 0) ~= 0
    end
    if aimMethodOverridden then
        stopSteering()
        if capsule ~= nil then setPointerVisible(capsule, false) end
        setReticleVisible(false)
        status("paused (montage aim override)")
        return
    end

    local colorIndex = configui.getValue("ip_color") or 1
    if POINTER_COLORS[colorIndex] == nil then colorIndex = 1 end
    if colorIndex ~= appliedColorIndex then
        if appliedColorIndex ~= nil then destroyPointer() end -- rebuilt below with the new colour
        LASER_COLOR = POINTER_COLORS[colorIndex]
        appliedColorIndex = colorIndex
    end
    local thickness = configui.getValue("ip_line_thickness") or 0.0
    if thickness ~= appliedThickness then
        if capsule ~= nil then applyLineThickness(capsule) end
        if reticle ~= nil then applyLineThickness(reticle) end
        appliedThickness = thickness
    end

    local p = ensurePointer(controller)
    local controllerLocation = controllers.getControllerLocation(Handed.Left)
    local controllerRotation = controllers.getControllerRotation(Handed.Left)
    if controllerLocation == nil or controllerRotation == nil then
        stopSteering()
        return
    end
    local origin, direction = getPointerRay(controllerLocation, controllerRotation)

    local hit, endLocation = pointerTrace(origin, direction, pawn)
    local target = hit ~= nil and uevrUtils.vector(hit.Location) or endLocation

    -- style: 1 laser, 2 reticule, 3 both ("Show pointer" off hides whichever is selected)
    local showPointer = configui.getValue("ip_show_laser") ~= false
    local style = configui.getValue("ip_style") or 1
    local showLaser = showPointer and style ~= 2
    local showReticle = showPointer and style ~= 1
    if p ~= nil then
        setPointerVisible(p, showLaser)
        if showLaser and target ~= nil then setPointerLength(p, uevrUtils.vectorDistance(origin, target)) end
    end
    if showReticle and hit ~= nil and target ~= nil then
        updateReticle(origin, target)
    else
        setReticleVisible(false)
    end

    -- Which actor was hit (BreakHitResult) is resolved at ~10 Hz; between resolves only the cached address and
    -- name are used, never the actor object itself (it may have been picked up and destroyed meanwhile).
    local interactable = false
    if hit == nil then
        resolvedActor, resolvedActorAddress, resolvedActorName = nil, nil, nil
        nextActorResolve = 0 -- resolve immediately when the laser lands on something again
    else
        if now >= nextActorResolve then
            nextActorResolve = now + ACTOR_RESOLVE_INTERVAL
            local details = uevrUtils.getCleanHitResult(hit)
            resolvedActor = details ~= nil and details.Actor or nil
            resolvedActorAddress = resolvedActor ~= nil and addressOf(resolvedActor) or nil
            resolvedActorName = nil
            if resolvedActor ~= nil and isInteractable(resolvedActor) then
                pcall(function() resolvedActorName = resolvedActor:get_full_name():match("[^%.]+$"):gsub("_UAID_.*$", "") end)
            end
            resolvedActor = nil -- keep only the address/name past this point
        end
        interactable = resolvedActorAddress ~= nil and interactableCache[resolvedActorAddress] == true
    end

    local cm = pc.PlayerCameraManager
    local camLocation = cm ~= nil and cm:GetCameraLocation() or nil
    local range = configui.getValue("ip_range") or 500.0
    if interactable and camLocation ~= nil and uevrUtils.vectorDistance(camLocation, target) <= range then
        local look = kismet_math_library:FindLookAtRotation(camLocation, target)
        look.Roll = 0
        if not steering then
            steering = true
            input.setOverrideAimMethod(input.AimMethod.UEVR)
        end
        pc:SetControlRotation(look)
        status("pointing at " .. tostring(resolvedActorName or "?"))
    else
        stopSteering()
        status((interactable and "on (interactable out of range)" or (hit ~= nil and "on (not interactable)" or "on (no target)"))
            .. (traceFailed and " [trace fallback: pickups not detectable]" or ""))
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    stopSteering()
    destroyPointer()
    interactableCache = {}
    interactableCacheSize = 0
    resolvedActor, resolvedActorAddress, resolvedActorName = nil, nil, nil
end)

uevr.params.sdk.callbacks.on_script_reset(function()
    stopSteering()
    destroyPointer()
end)
