-- VR tutorial (2026-11-16): image pages explaining the VR controls, the Cronos profile's vr_tutorial.lua (Cronos 1.7
-- rules, itself a port of Hellraiser's) ported to The Outer Worlds 2. libs/tutorial.lua = the Cronos copy (jbusfield's
-- Atomic Heart lib + gate option, gestureCloses, setCompleted, pageOffset, slot-0 guard).
-- Pages: data/tutorial/intro.png + 1.png .. N.png (counted at runtime), icons data/tutorial/buttons/. They are rendered
-- from the repo art (media/outerworlds2vr.png) by UnrealVRMod\0. Outer Worlds 2 Tutorial\make_pages.ps1.
--
--   * Startup: shown once real gameplay is reached (never in the main menu or the character creator, see inGameplay),
--     unless the panel option "Show it when gameplay starts" (tut_startup) is off, at every start until the player
--     closes it once (B or the gesture). After that only the gesture opens it. Also stops when the player finishes it
--     ("Done" on the last page) or turns on "Hide at startup" (Y). data/tutorial_state.json remembers that, the
--     gesture and the last page; it is never shipped, so a fresh install shows the tutorial again.
--   * Any time: left controller up to the eyes + left TRIGGER opens it again at the saved page (libs/gestures
--     EYESCRATCH: within 15 cm in front of the HMD, trigger > 128). The trigger has to be PULLED there: a trigger that
--     is already held when the hand passes the eyes never opens it. Read from the physical pad at priority 100002, so
--     before holsters (25), the hand poses (10), two-handing (5) and the LB<->LT swap (controls.lua, 1); buttonswitch.lua
--     and TheOuterWorlds2.lua are raw UEVR callbacks registered after the uevr_utils dispatcher, so they run after it.
--     Not during cutscenes / disabled input (libs/ui.lua), while two-handing, in the full-screen menus (ledger,
--     companions, vendor, workbench: _G.ow2IsMenuOpen) or while paused. A refused pull reaches the game as usual.
--     The left GRIP at the face is the flashlight (holsters.lua), so the two never collide.
--   * While open: every button is kept from the game and the other scripts (A next / start / done, X back, B close,
--     Y hide at startup; physical buttons, before buttonswitch's X<->B swap) and the game is paused (panel option).
--     The open gesture closes it again on any page (gestureCloses), the same as B.
--   * UI placement: OW2 keeps UEVR's UI head-locked (config UI_FollowView=true), and libs/ui.lua runs here, so the lib's
--     ui.lua view lock / controller-mouse states are off (lockView / disableControllerMouse = false): clearing the
--     lock on close would hand UEVR's follow-view to ui.lua's default. The page stays head-locked where
--     UI_X_Offset / UI_Y_Offset 0.213 / 0 put it (the shipped HUD offsets, so normally no shift); the offsets are never
--     written, the page moves inside its own widget instead (pageOffset).
-- Panel: "VR Tutorial" heading in the Outer Worlds 2 VR panel (zz_ow2_vr_panel.lua MAIN list).

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local controllers = require('libs/controllers')
local tutorial = require('libs/tutorial')

_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 8, label = "VR Tutorial", layout = {
	{ widgetType = "button", id = "tut_show", label = "Show the VR tutorial", size = {220, 24} },
	{ widgetType = "checkbox", id = "tut_startup", label = "Show it when gameplay starts (until closed once)", initialValue = true },
	{ widgetType = "checkbox", id = "tut_gesture", label = "Open it with the left trigger at your eyes", initialValue = true },
	{ widgetType = "checkbox", id = "tut_pause", label = "Pause the game while it is open", initialValue = true },
	{ widgetType = "button", id = "tut_reset", label = "Show it again at the next start", size = {260, 24} },
	{ widgetType = "text", id = "tut_status", label = "" },
}})

local function enabled(id)
	return configui.getValue(id) ~= false -- nil until the panel exists: the initial value (true)
end

-- Rising edge of the PHYSICAL left trigger, read before the tutorial's gesture check (priority 100001) and every other
-- handler. gestures.lua's face detector uses the same threshold (> 128).
local TRIGGER_THRESHOLD = 128
local leftTriggerWasDown = false
local leftTriggerPulled = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, userIndex, state)
	if userIndex ~= nil and userIndex ~= 0 then return end
	local down = state.Gamepad.bLeftTrigger > TRIGGER_THRESHOLD
	leftTriggerPulled = down and not leftTriggerWasDown
	leftTriggerWasDown = down
end, 100002)

-- full-screen menus, pause, or input handed to the game (cutscenes, non-player pawns: libs/ui.lua + uevrmenus.lua)
local function isBlocked()
	local ok, result = pcall(function()
		if _G.ow2IsMenuOpen ~= nil and _G.ow2IsMenuOpen() then return true end
		if uevrUtils.isInCutscene() then return true end
		if uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_input_disabled") == true then return true end
		local world = uevrUtils.get_world()
		return world ~= nil and Statics ~= nil and Statics:IsGamePaused(world) == true
	end)
	return ok and result == true
end

-- false while the left trigger near the eyes belongs to something else (asked only once the gesture is detected)
local function gestureAllowed()
	if not enabled("tut_gesture") then return false end
	if not leftTriggerPulled then return false end
	if _G.isTwoHandingActive == true then return false end
	if isBlocked() then return false end
	return true
end

-- Where the page appears, in UEVR UI offset metres (see the header)
local PAGE_UI_OFFSET_X = 0.213
local PAGE_UI_OFFSET_Y = 0.0

-- UEVR moves the whole UI quad by UI_X_Offset / UI_Y_Offset metres along its right / up axes, and the quad is UI_Size
-- metres tall for the full viewport height. So moving the page by (target - current) metres is (target - current) /
-- UI_Size viewport heights inside the widget (Slate y points down, UEVR's up axis up). Read at every page layout.
local function pageOffset()
	local ok, x, y = pcall(function()
		local vr = uevr.params.vr
		local currentX = tonumber(vr:get_mod_value("UI_X_Offset")) or 0
		local currentY = tonumber(vr:get_mod_value("UI_Y_Offset")) or 0
		local size = tonumber(vr:get_mod_value("UI_Size")) or 0
		if size <= 0 or WidgetLayoutLibrary == nil then return 0, 0 end
		local world = uevrUtils.get_world()
		local viewport = WidgetLayoutLibrary:GetViewportSize(world)
		local scale = WidgetLayoutLibrary:GetViewportScale(world)
		if viewport == nil or scale == nil or scale <= 0 then return 0, 0 end
		local height = viewport.Y / scale
		return (PAGE_UI_OFFSET_X - currentX) / size * height, -(PAGE_UI_OFFSET_Y - currentY) / size * height
	end)
	if not ok then return 0, 0 end
	return x or 0, y or 0
end

-- true while the tutorial on screen is the automatic startup one: closing that one stops the startup show
local startupShow = false
-- true until the startup tutorial has been shown in gameplay this session (see inGameplay below)
local startupPending = false

local t = tutorial.new({
	imageSize = 1536,
	pauseGame = enabled("tut_pause"),
	lockView = false,
	disableControllerMouse = false,
	buttons = { start = "A", next = "A", done = "A", back = "X", close = "B", skip = "B", hideAtStartup = "Y" },
	labels = { close = "Close (or gesture)" },
	openGestureCondition = gestureAllowed,
	gestureCloses = true, -- the open gesture is a toggle: it closes the tutorial on any page too
	pageOffset = pageOffset,
	-- once per session: which loaded Widget Blueprint class libs/widget borrowed for the host (it must not be one of
	-- data/ui_parameters.json's widgetlist classes, although ui.ignoreWidget keeps ui.lua off it anyway)
	onOpen = function(self)
		if self.hostClassLogged then return end
		self.hostClassLogged = true
		pcall(function()
			uevr.params.functions.log_info("[vr_tutorial] host widget class: " .. self.host:get_class():get_full_name())
		end)
	end,
	onClose = function(self, reason)
		if reason == "level_change" then
			-- closed without the player choosing to: the startup tutorial comes back in the next gameplay
			if startupShow then startupPending = true end
			startupShow = false
			return
		end
		if startupShow and (reason == "closed" or reason == "skipped") then self:setCompleted(true) end
		startupShow = false
	end,
})

-- The startup tutorial waits for real gameplay:
--   * the pawn is the player character (IndianaPlayerCharacter_BP_C; the main menu has OwMainMenuPawn_BP_C, the
--     character creator a plain DefaultPawn)
--   * the player controller is the game's (IndianaPlayerController)
--   * the motion controller components exist (libs/gestures reads the cached left controller and HMD)
--   * none of isBlocked (menus, pause, cutscenes, disabled input)
-- held for STARTUP_HOLD_S, so a level that is still streaming in or a cutscene about to start does not get it.
-- Classes are matched by name up the class chain, so the /Script/ module they live in does not matter.
local function isA(object, classNames)
	if object == nil then return false end
	local class = object:get_class()
	while class ~= nil do
		local name = class:get_fname():to_string()
		for _, wanted in ipairs(classNames) do
			if name == wanted then return true end
		end
		class = class:get_super_struct()
	end
	return false
end

local PLAYER_PAWN = { "IndianaPlayerCharacter_BP_C", "IndianaPlayerCharacter" }
local PLAYER_CONTROLLER = { "IndianaPlayerController" }

local function inGameplay()
	local ok, result = pcall(function()
		if not isA(uevr.api:get_local_pawn(0), PLAYER_PAWN) then return false end
		if not isA(uevr.api:get_player_controller(0), PLAYER_CONTROLLER) then return false end
		if not controllers.controllerExists(Handed.Left) or not controllers.hmdControllerExists() then return false end
		return not isBlocked()
	end)
	return ok and result == true
end

startupPending = not t:isCompleted()
local STARTUP_POLL_S = 0.5
local STARTUP_HOLD_S = 2.0
local startupPollTimer = 0
local gameplayFor = 0
uevrUtils.registerPreEngineTickCallback(function(engine, delta)
	if not startupPending or t:isOpen() then return end
	startupPollTimer = startupPollTimer + (tonumber(delta) or 0)
	if startupPollTimer < STARTUP_POLL_S then return end
	local elapsed = startupPollTimer
	startupPollTimer = 0
	if t:isCompleted() then startupPending = false return end
	if not enabled("tut_startup") then gameplayFor = 0 return end -- option off: keep waiting in case it is turned back on
	if not inGameplay() then gameplayFor = 0 return end
	gameplayFor = gameplayFor + elapsed
	if gameplayFor < STARTUP_HOLD_S then return end
	gameplayFor = 0
	startupPending = false
	startupShow = t:showOnce()
end)

uevrUtils.registerPreLevelChangeCallback(function()
	gameplayFor = 0
end)

local function updateStatus()
	configui.setLabel("tut_status", t:isCompleted() and "Shown at start: no (closed, finished or hidden)" or "Shown at start: yes")
end

-- Panel buttons run while UEVR draws its overlay: widgets are made on the next engine tick instead
local pending = nil
configui.onUpdate("tut_show", function() pending = "show" end)
configui.onUpdate("tut_reset", function() pending = "reset" end)
configui.onCreateOrUpdate("tut_pause", function(value) t.options.pauseGame = value ~= false end)

uevrUtils.registerPreEngineTickCallback(function()
	if pending == nil then return end
	local action = pending
	pending = nil
	if action == "show" then
		startupShow = false
		t:show(t:getSavedPage() or 1)
	elseif action == "reset" then
		startupShow = false
		t:resetCompleted()
		t:resetInteraction()
		t:resetSavedPage()
	end
	updateStatus()
end)

uevrUtils.setTimeout(1000, updateStatus)
