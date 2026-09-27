local uevrUtils = require('libs/uevr_utils')
local hands = require('libs/hands')
local controllers = require('libs/controllers')
local configui = require('libs/configui')

-- ---------------------------------------------------------------------------------------------
-- Hands mode: glove hands (this file) OR the full-arm IK rig (libs/ik, driven from uevrmenus.lua).
-- They are mutually exclusive on purpose: both register the same animation ids (left_arms /
-- right_arms) with hands_animation, so whichever registers last owns the finger poses and destroying
-- one strips the other's poses. uevrmenus.lua exposes _G.setIKEnabled(bool) and _G.ikRebuild();
-- this file only calls them when they exist (it loads before uevrmenus.lua).
-- ---------------------------------------------------------------------------------------------
local HANDS_MODE_GLOVES = 1
local HANDS_MODE_IK     = 2
-- Section of the merged "Outer Worlds 2 VR" panel (built by scripts/zz_ow2_vr_panel.lua once every
-- script has registered its section; values are saved in data/ow2_vr_config.json)
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 1, label = "Hands", layout = {
			{ widgetType = "combo", id = "hands_mode", label = "Hands", initialValue = HANDS_MODE_GLOVES, selections = {"Hands", "IK Arms"} },
			{ widgetType = "text", id = "hands_mode_status", label = "Status: -" },
}})
local function getHandsMode()
	local v = configui.getValue("hands_mode")
	return v == HANDS_MODE_IK and HANDS_MODE_IK or HANDS_MODE_GLOVES
end
_G.getHandsMode = getHandsMode
local function setIK(enabled)
	if _G.setIKEnabled ~= nil then pcall(_G.setIKEnabled, enabled) end
end

-- Why this is not the plain wizard template (2026-09-26, log-verified):
--  * On a real level load the controllers library forgets its controller actors (pre-level reset) and
--    controllers.createController() then "restores" whatever MotionControllerComponent find_all_of
--    returns first - which is the stale pair from the PREVIOUS world (main menu). Hands built on those
--    never render. After a script reset there is no stale pair, so a fresh one is made and it works,
--    which is exactly the "hands only appear after Reset Scripts" symptom.
--  * The pair also has to be built after the pawn's FPVMesh exists (the menu level has no pawn; the
--    library's 1 s auto-create just fails there every second).
-- So: hold auto-create off, wait for a valid pawn arms mesh, make sure the controllers live in the
-- pawn's world (rebuild them if not), then build the hands. Auto-create is re-enabled afterwards as a
-- fallback for a pair that dies later.

local paramsFile = 'hands_parameters' -- found in the [game profile]/data directory
local configName = 'Main' -- the name you gave your config
local animationName = 'Shared' -- the name you gave your animation

local FIRST_DELAY_MS = 2000   -- after the level-change event
local RETRY_MS       = 1000   -- while waiting for the pawn / arms mesh
local MAX_TRIES      = 90

local levelToken = 0
local lastArmsSignature = nil   -- set by buildHands, compared by the suit-change poll below

local function log(text)
	pcall(function() uevrUtils.print("[hands boot] " .. tostring(text), LogLevel.Info) end)
end

local function alive(obj)
	if obj == nil then return false end
	local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
	return ok and r
end

-- "/Game/Maps/.../0201_PI_P.0201_PI_P.PersistentLevel." part of a full object name
local function worldPrefix(obj)
	if not alive(obj) then return nil end
	local name = obj:get_full_name()
	return name and name:match("%s(.-PersistentLevel%.)") or nil
end

local function getArmsMesh()
	local pawn = uevr.api:get_local_pawn(0)
	if pawn == nil then return nil, nil end
	local ok, mesh = pcall(function() return pawn.FPVMesh end)
	if ok and alive(mesh) then return pawn, mesh end
	return pawn, nil
end

-- true if both hand controllers exist and belong to the pawn's world
local function controllersAreCurrent(pawn)
	local want = worldPrefix(pawn)
	for id = 0, 1 do
		local c = controllers.getController(id, true)
		if not alive(c) then return false, "controller " .. id .. " missing" end
		local have = worldPrefix(c)
		if want ~= nil and have ~= nil and have ~= want then
			return false, "controller " .. id .. " is from another world (" .. have .. ")"
		end
	end
	return true
end

-- After a rebuild the new hand components start in the open pose: hands_animation only re-applies the
-- per-weapon grip pose on a grip-animation change or an input edge, and animation.lua's per-id state
-- still says "grip on", so nothing lerps until the player presses grip. Force the state refresh the
-- attachment-change path uses, a little after creation (and once more after the hide re-applies).
function refreshWeaponPoses()
	for _, ms in ipairs({300, 1200}) do
		uevrUtils.setTimeout(ms, function()
			pcall(function()
				hands.updateAnimationState(Handed.Right)
				hands.updateAnimationState(Handed.Left)
			end)
		end)
	end
end
_G.refreshWeaponPoses = refreshWeaponPoses

local function buildHands(token, tries)
	if token ~= levelToken then return end -- another level change happened meanwhile
	local pawn, arms = getArmsMesh()
	if getHandsMode() == HANDS_MODE_IK then
		-- IK mode: no glove pair; hand the arms over to the rig (its own auto-create builds it)
		hands.setAutoCreateHands(false)
		hands.destroyHands()
		setIK(true)
		if arms ~= nil then lastArmsSignature = armsSignature(arms) end
		configui.setLabel("hands_mode_status", "Status: IK Arms")
		log("IK mode: glove hands disabled, rig enabled")
		return
	end
	setIK(false)
	if arms == nil then
		if tries < MAX_TRIES then
			uevrUtils.setTimeout(RETRY_MS, function() buildHands(token, tries + 1) end)
		else
			log("gave up waiting for the pawn arms mesh; auto-create re-enabled")
			hands.setAutoCreateHands(true)
		end
		return
	end

	-- Create (or let the library restore) the controllers first, THEN verify they live in the pawn's
	-- world. libs/controllers.lua's finder now ignores components from a previous world, so a rebuild
	-- here is only the safety net.
	controllers.createController(0)
	controllers.createController(1)
	controllers.createController(2)
	local ok, why = controllersAreCurrent(pawn)
	if not ok then
		log("controllers are stale after create (" .. tostring(why) .. "); rebuilding")
		controllers.destroyControllers()
		controllers.createController(0)
		controllers.createController(1)
		controllers.createController(2)
		local ok2, why2 = controllersAreCurrent(pawn)
		if not ok2 then log("controllers STILL stale after rebuild: " .. tostring(why2)) end
	end

	hands.destroyHands() -- destroys any previous pair; hands.reset() only forgets it (leaks live components)
	hands.createFromConfig(paramsFile, configName, animationName)
	hands.setAutoCreateHands(true)
	lastArmsSignature = armsSignature(arms)
	refreshWeaponPoses() -- new components start in the open pose; re-assert the current weapon grip/trigger state
	configui.setLabel("hands_mode_status", "Status: Hands")
	local c0 = controllers.getController(0, true)
	log("hands created (try " .. tries .. ", controllers " .. (ok and "ok" or "rebuilt") .. ", left controller " .. (alive(c0) and c0:get_full_name() or "nil") .. ", arms " .. tostring(lastArmsSignature) .. ")")
end

-- ---------------------------------------------------------------------------------------------
-- Suit / armor change -> rebuild the hands (they are copies of the arms mesh and its materials).
-- MCP watches 2026-09-27: changing a suit swaps Pawn.FPVMesh.SkeletalMesh (e.g. SK_ARK_PlayerSuit_TP_Arms_001_M
-- -> SK_ARK_AC_Clean_FP_Arms_001_M) and replaces FPVMesh.OverrideMaterials in the same tick, one tick after
-- PlayerAppearance.CurrentBody changes. No appearance UFunction fires (RefreshFullAppearance etc. saw
-- zero calls), so the mesh component is polled. Mesh asset + material identities form a signature.
-- ---------------------------------------------------------------------------------------------
local POLL_MS          = 500
local REBUILD_DELAY_MS = 400    -- let the game finish assigning materials before we copy them
local nextPoll = 0
local rebuildPending = false

function armsSignature(arms)
	local sig = nil
	pcall(function()
		local mesh = arms.SkeletalMesh
		sig = mesh and mesh:get_full_name() or "nil"
		local mats = arms.OverrideMaterials
		if mats ~= nil then
			for i = 1, #mats do
				local m = mats[i]
				sig = sig .. "|" .. (m and tostring(m:get_full_name()) or "nil")
			end
		end
	end)
	return sig
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local now = os.clock()
	if now < nextPoll or rebuildPending then return end
	nextPoll = now + POLL_MS / 1000
	local ikMode = getHandsMode() == HANDS_MODE_IK
	if not ikMode and not hands.exists() then return end
	local _, arms = getArmsMesh()
	if arms == nil then return end
	local sig = armsSignature(arms)
	if lastArmsSignature == nil then lastArmsSignature = sig return end -- first sample after a mode switch
	if sig == nil or sig == lastArmsSignature then return end
	log("arms mesh changed -> rebuilding " .. (ikMode and "IK rig" or "hands") .. ": " .. tostring(sig))
	lastArmsSignature = sig
	rebuildPending = true
	local token = levelToken
	uevrUtils.setTimeout(REBUILD_DELAY_MS, function()
		rebuildPending = false
		if token ~= levelToken then return end
		if ikMode then
			if _G.ikRebuild ~= nil then pcall(_G.ikRebuild) end
		else
			buildHands(token, 1)
		end
	end)
end)

-- Switching the mode at runtime: tear down the current setup and build the other one in place.
configui.onUpdate("hands_mode", function(value)
	uevrUtils.setTimeout(1, function() -- configui callbacks run on the draw thread; build on the game thread
		levelToken = levelToken + 1
		local token = levelToken
		lastArmsSignature = nil
		buildHands(token, 1)
	end)
end)

function on_level_change(level)
	hands.setAutoCreateHands(false)
	hands.destroyHands()
	levelToken = levelToken + 1
	local token = levelToken
	uevrUtils.setTimeout(FIRST_DELAY_MS, function() buildHands(token, 1) end)
end

-- Input handling is automatic (libs/hands_animation.lua). Do NOT add on_xinput_get_state + hands.handleInput(state, false, ...):
-- it overrides the per-attachment weapon poses with the generic grip/trigger poses.
