-- Controller options for The Outer Worlds 2 (2026-09-29).
--
-- "Swap left grip and left trigger": the game sees the left grip (LB) as the left trigger (LT, aim)
-- and the left trigger as the left grip. Only what reaches the game is swapped: the callback runs at
-- priority 1, after hands_animation (10) and two_handed (5), so the hand finger poses and the
-- two-handed "Grab button" option keep following the PHYSICAL buttons; remap (0) and the game see
-- the swapped state. Not applied while a full-screen menu (ledger, companion selection) is open: menus get the plain
-- flat-game buttons (_G.ow2IsMenuOpen from scripts/ledger_native_fix.lua).

local uevrUtils = require('libs/uevr_utils')
local configui  = require('libs/configui')

-- Section of the merged "Outer Worlds 2 VR" panel (see scripts/zz_ow2_vr_panel.lua)
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 6, label = "Controls", layout = {
            { widgetType = "checkbox", id = "ctl_swap_left_grip_trigger", label = "Swap left grip and left trigger", initialValue = false },
            { widgetType = "checkbox", id = "ctl_disable_ads_zoom", label = "Disable ADS zoom (keep aiming, no FOV change)", initialValue = true },
}})

local TRIGGER_PRESSED = 30 -- XINPUT_GAMEPAD_TRIGGER_THRESHOLD

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    if configui.getValue("ctl_swap_left_grip_trigger") ~= true then return end
    if _G.ow2IsMenuOpen ~= nil and _G.ow2IsMenuOpen() then return end

    local gripDown    = uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
    local triggerDown = (state.Gamepad.bLeftTrigger or 0) > TRIGGER_PRESSED

    state.Gamepad.bLeftTrigger = gripDown and 255 or 0
    if triggerDown then
        uevrUtils.pressButton(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
    else
        uevrUtils.unpressButton(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
    end
end, 1) -- after hands_animation (10) and two_handed (5), before remap (0) and the game

-- "Disable ADS zoom" (2026-09-30). ADS ("fine aim") zooms by lowering the camera FOV (59 -> ~40 on the
-- Mobility AR). The zoom comes from the sight's SightData DATA ASSET (shared by every weapon using that
-- sight): AimingFOVMagnification / AimingFOVAdjustment (+ the Idle pair for hip). RangedMode (fire mode)
-- has its own FineAimFovAdjustment / FineAimMagnification, used by weapons without a sight override.
-- Neither the FPVCamera FieldOfView nor the "fov" console lock is involved. These values only drive the
-- camera FOV: spread reduction, ADS pose/animation and aim stay the game's. Re-applied every 2 s so newly
-- loaded sight assets (weapon swaps, level loads) are covered; originals are kept to restore on untick.
local FOV_FIELDS = {
    SightData  = { AimingFOVAdjustment = 0.0, AimingFOVMagnification = 1.0, IdleFOVAdjustment = 0.0, IdleFOVMagnification = 1.0 },
    RangedMode = { FineAimFovAdjustment = 0.0, FineAimMagnification = 1.0 },
}
local fovClasses = nil
local fovOriginals = {} -- address -> { obj = object, values = { field = original } }
local playerModeCache = {} -- RangedMode address -> true (player's) / false (NPC/CDO); name checked once per object

-- The originals are also kept on disk (data/ads_zoom_originals.json), keyed by a stable name: the sight asset's full
-- name, or the fire mode's path below the inventory with the instance numbers removed. The in-memory table alone lost
-- them on a script reset or a level change while the objects kept the neutral values, so a later "restore" (and
-- pip_scope.lua's game zoom, 2026-11-12) only ever saw 1.0. A value is recorded the first time it is seen non-neutral,
-- i.e. once per game start for each sight.
local ORIGINALS_FILE = "ads_zoom_originals.json"
local savedOriginals = {}
pcall(function() savedOriginals = json.load_file(ORIGINALS_FILE) or {} end)
local function originalsKey(obj)
    local ok, name = pcall(function() return obj:get_full_name() end)
    if not ok or name == nil then return nil end
    local below = name:match("%.Inventory%.(.+)$")
    if below ~= nil then return (below:gsub("_%d%d%d%d%d+", "")) end -- fire mode: weapon class + mode, no instance numbers
    return name -- sight asset: its full name is stable
end

local function neutraliseObject(obj, fields)
    local ok, address = pcall(function() return obj:get_address() end)
    if not ok or address == nil then return end
    local entry = fovOriginals[address]
    local key, dirty = nil, false
    for field, neutral in pairs(fields) do
        pcall(function()
            local current = obj[field]
            if current ~= nil and current ~= neutral then
                if entry == nil then entry = { obj = obj, values = {} }; fovOriginals[address] = entry end
                if entry.values[field] == nil then entry.values[field] = current end
                key = key or originalsKey(obj)
                if key ~= nil then
                    savedOriginals[key] = savedOriginals[key] or {}
                    if savedOriginals[key][field] ~= current then savedOriginals[key][field] = current dirty = true end
                end
                obj[field] = neutral
            end
        end)
    end
    if dirty then pcall(function() json.dump_file(ORIGINALS_FILE, savedOriginals, 4) end) end
end

-- The game's own value of a zoom field on a sight / fire mode, even while "Disable ADS zoom" holds it neutral:
-- the saved original, else the live value (= the original when it was never neutralised).
_G.ow2OriginalZoomValue = function(obj, field)
    if obj == nil then return nil end
    local key = originalsKey(obj)
    local saved = key ~= nil and savedOriginals[key] or nil
    if saved ~= nil and saved[field] ~= nil then return saved[field] end
    local value = nil
    pcall(function() value = obj[field] end)
    return value
end

local function restoreFovValues()
    for address, entry in pairs(fovOriginals) do
        if UEVR_UObjectHook.exists(entry.obj) then
            for field, value in pairs(entry.values) do
                pcall(function() entry.obj[field] = value end)
            end
        end
    end
    fovOriginals = {}
    -- objects neutralised before a script reset / level change are no longer in fovOriginals: use the saved originals
    for _, kind in ipairs({ "SightData", "RangedMode" }) do
        local class = fovClasses ~= nil and fovClasses[kind] or nil
        for _, obj in ipairs(class ~= nil and UEVR_UObjectHook.get_objects_by_class(class, false) or {}) do
            local key = originalsKey(obj)
            for field, value in pairs(key ~= nil and savedOriginals[key] or {}) do
                if FOV_FIELDS[kind][field] ~= nil then pcall(function() obj[field] = value end) end
            end
        end
    end
end

local function ensureFovClasses()
    if fovClasses == nil then
        fovClasses = {
            SightData  = uevrUtils.get_class("Class /Script/Arkansas.SightData"),
            RangedMode = uevrUtils.get_class("Class /Script/Arkansas.RangedMode"),
        }
    end
end

-- sights: every loaded SightData asset (a handful, one per sight type); these load when a weapon is equipped
local function applyNoAdsZoomSights()
    ensureFovClasses()
    local sights = fovClasses.SightData ~= nil and UEVR_UObjectHook.get_objects_by_class(fovClasses.SightData, false) or nil
    for _, sight in ipairs(sights or {}) do neutraliseObject(sight, FOV_FIELDS.SightData) end
end

-- fire modes: only the player's own weapons (NPC fire modes never drive the player camera); these exist in the
-- inventory long before a weapon is equipped, so a slow scan is enough
local function applyNoAdsZoomModes()
    ensureFovClasses()
    local modes = fovClasses.RangedMode ~= nil and UEVR_UObjectHook.get_objects_by_class(fovClasses.RangedMode, false) or nil
    for _, mode in ipairs(modes or {}) do
        local ok, address = pcall(function() return mode:get_address() end)
        if ok and address ~= nil then
            local isPlayers = playerModeCache[address]
            if isPlayers == nil then
                isPlayers = false
                pcall(function() isPlayers = mode:get_full_name():find("IndianaPlayerCharacter", 1, true) ~= nil end)
                playerModeCache[address] = isPlayers
            end
            if isPlayers then neutraliseObject(mode, FOV_FIELDS.RangedMode) end
        end
    end
end

local adsZoomWasDisabled = false
-- The values are read live every frame, so the only gap is noticing a newly loaded sight: sights are scanned
-- every 250 ms, the player's fire modes every 2 s (every 8th tick, and on the first tick after enabling).
local modeCacheTicks = 0
local modeScanTicks = 0
uevrUtils.setInterval(250, function()
    modeCacheTicks = modeCacheTicks + 1
    if modeCacheTicks >= 120 then -- 30 s: addresses of dead NPC fire modes get reused
        modeCacheTicks = 0
        playerModeCache = {}
    end
    local want = configui.getValue("ctl_disable_ads_zoom") ~= false
    if want then
        pcall(applyNoAdsZoomSights)
        if modeScanTicks <= 0 or not adsZoomWasDisabled then
            modeScanTicks = 8
            pcall(applyNoAdsZoomModes)
        end
        modeScanTicks = modeScanTicks - 1
    elseif adsZoomWasDisabled then
        pcall(restoreFovValues)
    end
    adsZoomWasDisabled = want
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    fovOriginals = {} -- objects of the old world are gone; addresses may be reused
    playerModeCache = {}
end)
