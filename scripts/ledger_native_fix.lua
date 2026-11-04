-- Native Stereo Fix off while a full-screen menu is open, for The Outer Worlds 2 (2026-11-02): the ledger (inventory),
-- the companion selection screen, the vendor (trading) screen (VendorClass = VendorWidget_BP_C) and the workbench
-- (NewWorkbenchClass = UpdatedWorkbenchWidget_BP_C) - both in the viewport at opacity 1 with the game paused while
-- open, MCP 2026-11-02.
--
-- Menu widget classes come from the HUD (IndianaUI) class properties below - no find_uobject, whose miss costs ~400 ms.
-- Both widgets are owned by the GameInstance (MCP 2026-11-02):
--   * the ledger (LedgerWidgetClass = Ledger_BP_C) is created once and then stays in the viewport: opening / closing
--     only fades its RenderOpacity between 0 and 1 (its Visibility and GetOpenState() never change);
--   * the companion selection screen (CompanionSelectionClass = CompanionSelectionWidget_BP_C) exists only while open
--     (destroyed on close), in the viewport at opacity 1.
-- Opacity alone is not a safe "open" signal: a widget that is not on screen (a fresh one keeps the default opacity 1, or
-- the previous level's copy after a death reload) can report > 0, which left Native Fix off in gameplay. The game is
-- always paused while these menus are open, so a menu counts as open only when
--   the game is paused  AND  one of its widgets is in the viewport with RenderOpacity > 0.
-- The pause menu pauses too but has no widget of these classes. Unpaused (gameplay) Native Fix is always put back.
-- If Native Fix is on when a menu opens it is switched off, and back on once it is closed (only if this script switched
-- it off).
--
-- _G.ow2IsMenuOpen() -> true while one of these menus is open (updated every pre-engine tick, whatever the Native Fix
-- setting), e.g. for controls.lua to give menus the plain flat-game buttons.

local uevrUtils = require('libs/uevr_utils')

local NATIVE_FIX = "VR_NativeStereoFix"
local MENU_CLASS_PROPERTIES = { "LedgerWidgetClass", "CompanionSelectionClass", "VendorClass", "NewWorkbenchClass" }

local menus = {}
local nextSearch = 0
local disabledByUs = false
local menuOpen = false

_G.ow2IsMenuOpen = function()
    return menuOpen
end

local function restore()
    if disabledByUs then
        disabledByUs = false
        uevr.params.vr.set_mod_value(NATIVE_FIX, "true")
    end
end

local function isPaused()
    local world = uevrUtils.get_world()
    return world ~= nil and Statics ~= nil and Statics:IsGamePaused(world) == true
end

-- UObjectHook's per-class registry (a map lookup). Never get_first_object_matching / get_objects_matching here: they
-- walk the whole object array (~576k objects) and hitch the frame.
local function findMenus()
    local found = {}
    local controller = uevr.api:get_player_controller(0)
    local hud = controller ~= nil and controller.MyHUD or nil
    if hud == nil then return found end
    for _, property in ipairs(MENU_CLASS_PROPERTIES) do
        local menuClass = hud[property]
        if menuClass ~= nil then
            for _, widget in ipairs(UEVR_UObjectHook.get_objects_by_class(menuClass, false) or {}) do
                table.insert(found, widget)
            end
        end
    end
    return found
end

local function isMenuOpen()
    local now = os.clock()
    if now >= nextSearch then
        nextSearch = now + 0.5
        menus = findMenus()
    end
    for _, menu in ipairs(menus) do
        if uevrUtils.getValid(menu) ~= nil and (menu.RenderOpacity or 0) > 0 and menu:IsInViewport() == true then
            return true
        end
    end
    return false
end

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    local ok, err = pcall(function()
        if not isPaused() then
            nextSearch = 0 -- look the menus up on the first paused tick
            menuOpen = false
            restore()
            return
        end
        menuOpen = isMenuOpen()
        if menuOpen then
            if not disabledByUs and uevrUtils.getUEVRParam_bool(NATIVE_FIX) then
                disabledByUs = true
                uevr.params.vr.set_mod_value(NATIVE_FIX, "false")
            end
        else
            restore()
        end
    end)
    if not ok then
        menuOpen = false
        restore()
        print("[ledger_native_fix] " .. tostring(err))
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    menus, nextSearch, menuOpen = {}, 0, false
    restore()
end)

uevr.sdk.callbacks.on_script_reset(function()
    restore()
end)
