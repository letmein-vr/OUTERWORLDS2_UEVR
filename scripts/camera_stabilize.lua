-- Camera stabilisation for The Outer Worlds 2 (2026-09-26).
--
-- The game shakes/bobs its first-person camera through four things, none of which belong in VR:
--   * IndianaGameUserSettings.bHeadbobbing            - walk/run head bob (the game's own option),
--   * CameraModifier_CameraShake                      - explosions, hits, ship fly-bys, melee impacts,
--   * CameraAnimationCameraModifier                   - camera animation sequences (melee swings etc.),
--   * CameraModifier_WeaponAction_C                   - weapon recoil / action camera kicks + weapon sway.
-- All four live on the PlayerCameraManager (OWPlayerCameraManager_BP_C ModifierList) or the user
-- settings object and are re-created per level / camera manager, so this script re-applies the
-- chosen state whenever the camera manager instance changes and once a second as a safety net.
-- Each one has its own checkbox in the "Camera Stabilize" panel; unticking re-enables it live.
--
-- The bob that survives all of the above is animation-driven: Pawn.FPVCamera (FPVCameraComponent) is
-- attached to Pawn.FPVMesh socket "Camera_BoneSocket", and the arms AnimBP (ARK_P1P_AnimBP_C,
-- CameraBobActive / CameraAnimWeightInv) animates that bone while walking, sprinting and swinging.
-- uevrlib's input.lua already replaces the camera POSITION with the pawn root (+ headOffset), but the
-- POV ROTATION still came from that animated socket. Fix: FPVCamera.bUsePawnControlRotation = true,
-- which makes the camera component take the pawn's control rotation instead of its parent socket's
-- (the game ships it false). A fallback "hard lock" overrides the VR view rotation directly with the
-- control rotation yaw (pitch/roll 0, matching what input.lua does in its own rotation modes).

local uevrUtils = require('libs/uevr_utils')
local configui  = require('libs/configui')

-- Section of the merged "Outer Worlds 2 VR" panel (see scripts/zz_ow2_vr_panel.lua)
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 4, label = "Camera Stabilize", layout = {
            { widgetType = "checkbox", id = "cs_headbob",     label = "Disable head bobbing (game setting)", initialValue = true },
            { widgetType = "checkbox", id = "cs_shake",       label = "Disable camera shakes", initialValue = true },
            { widgetType = "checkbox", id = "cs_camera_anim", label = "Disable camera animations (melee etc.)", initialValue = true },
            { widgetType = "checkbox", id = "cs_weapon_kick", label = "Disable weapon action camera kick / sway", initialValue = true },
            { widgetType = "checkbox", id = "cs_pawn_rot",    label = "FPV camera uses control rotation (kills anim bob)", initialValue = true },
            { widgetType = "checkbox", id = "cs_hard_lock",   label = "Hard-lock VR camera yaw to control rotation (fallback)", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", id = "cs_status", label = "Status: waiting for camera manager" },
}})

local MODIFIERS = {
    { id = "cs_shake",       class = "CameraModifier_CameraShake" },
    { id = "cs_camera_anim", class = "CameraAnimationCameraModifier" },
    { id = "cs_weapon_kick", class = "CameraModifier_WeaponAction_C" },
}

local lastManager = nil
local lastApplied = {}      -- widget id -> bool last applied
local nextRefresh = 0
local settingsObj = nil

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

local function getCameraManager()
    local pc = uevr.api:get_player_controller(0)
    if pc == nil then return nil end
    local ok, cm = pcall(function() return pc.PlayerCameraManager end)
    if ok and alive(cm) then return cm end
    return nil
end

local function getUserSettings()
    if alive(settingsObj) then return settingsObj end
    settingsObj = nil
    pcall(function()
        local cls = uevrUtils.get_class("Class /Script/Arkansas.IndianaGameUserSettings")
        if cls == nil then return end
        local list = UEVR_UObjectHook.get_objects_by_class(cls, false)
        if list ~= nil then
            for _, obj in ipairs(list) do
                if alive(obj) then settingsObj = obj break end
            end
        end
    end)
    return settingsObj
end

local function applyModifiers(cm, force)
    local applied = {}
    local ok, list = pcall(function() return cm.ModifierList end)
    if not ok or list == nil then return applied end
    for i = 1, #list do
        local mod = list[i]
        if alive(mod) then
            local cls = uevrUtils.getShortName(mod:get_class())
            for _, def in ipairs(MODIFIERS) do
                if cls == def.class then
                    local wantDisabled = configui.getValue(def.id) ~= false
                    if force or lastApplied[def.id] ~= wantDisabled then
                        pcall(function()
                            if wantDisabled then
                                mod:DisableModifier(true)
                                if def.class == "CameraModifier_CameraShake" and cm.StopAllCameraShakes ~= nil then
                                    cm:StopAllCameraShakes(true)
                                end
                            else
                                mod:EnableModifier()
                            end
                        end)
                    elseif wantDisabled then
                        -- the game can re-enable a modifier (EnableModifier on its own events); keep it down
                        pcall(function()
                            if mod.IsDisabled ~= nil and mod:IsDisabled() == false then mod:DisableModifier(true) end
                        end)
                    end
                    applied[def.id] = wantDisabled
                end
            end
        end
    end
    return applied
end

local function applyHeadbob(force)
    local want = configui.getValue("cs_headbob") ~= false
    if not force and lastApplied["cs_headbob"] == want then return end
    local s = getUserSettings()
    if s == nil then return end
    pcall(function()
        -- disabled = bHeadbobbing false; re-enabling restores the game's own value (true is its default)
        s.bHeadbobbing = not want
    end)
    lastApplied["cs_headbob"] = want
end

-- FPVCamera.bUsePawnControlRotation: re-checked every refresh because the game re-creates / re-inits
-- the component on respawn and perspective changes.
local function applyPawnControlRotation()
    local want = configui.getValue("cs_pawn_rot") ~= false
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local cam = pawn and pawn.FPVCamera
        if not alive(cam) or cam.bUsePawnControlRotation == nil then return end
        if cam.bUsePawnControlRotation ~= want then
            cam.bUsePawnControlRotation = want
        end
        lastApplied["cs_pawn_rot"] = want
    end)
end

local function refresh(force)
    applyPawnControlRotation()
    local cm = getCameraManager()
    if cm == nil then return end
    if cm ~= lastManager then
        lastManager = cm
        force = true
        lastApplied = {}
    end
    local applied = applyModifiers(cm, force)
    for k, v in pairs(applied) do lastApplied[k] = v end
    applyHeadbob(force)
    local parts = {}
    for _, def in ipairs(MODIFIERS) do
        table.insert(parts, def.class:gsub("CameraModifier_", ""):gsub("_C$", "") .. "=" .. (lastApplied[def.id] == true and "off" or (lastApplied[def.id] == false and "on" or "?")))
    end
    configui.setLabel("cs_status", "Status: headbob=" .. (lastApplied["cs_headbob"] == true and "off" or "on") .. " " .. table.concat(parts, " "))
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local now = os.clock()
    if now < nextRefresh then return end
    nextRefresh = now + 1.0
    local ok, err = pcall(refresh, false)
    if not ok then print("[camera_stabilize] " .. tostring(err)) end
end)

for _, def in ipairs(MODIFIERS) do
    configui.onUpdate(def.id, function(value) nextRefresh = 0 end)
end
configui.onUpdate("cs_headbob", function(value) nextRefresh = 0 end)
configui.onUpdate("cs_pawn_rot", function(value) nextRefresh = 0 end)

-- Fallback hard lock: runs in the "pre" stereo callback, i.e. after input.lua's early callback has
-- set the position, and replaces the view rotation with the control rotation (yaw only; pitch and
-- roll 0 as input.lua does for its own rotation modes, decoupled pitch handles the HMD pitch).
local function getControlYaw()
    local yaw = nil
    pcall(function()
        local pc = uevr.api:get_player_controller(0)
        if pc == nil or pc.GetControlRotation == nil then return end
        local r = pc:GetControlRotation()
        if r ~= nil then yaw = r.Yaw end
    end)
    return yaw
end

uevrUtils.registerPreCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if configui.getValue("cs_hard_lock") ~= true or rotation == nil then return end
    local yaw = getControlYaw()
    if yaw == nil then return end
    rotation.Pitch = 0
    rotation.Yaw = yaw
    rotation.Roll = 0
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    lastManager = nil
    lastApplied = {}
    settingsObj = nil
end)

print("[camera_stabilize] loaded")
