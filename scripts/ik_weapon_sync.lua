-- IK Arms: weapon / IK hand lock for The Outer Worlds 2 (2026-10-10).
-- Port of Stalker2-Win64-Shipping/scripts/stalker2/ik_weapon_sync.lua (rig-relative version, confirmed there).
--
-- Problem: in IK Arms mode the gun and the hand holding it are posed at different points of a frame.
--   * the rig solves in the engine tick callback (libs/ik.lua) and its bones reach the renderer in the rig
--     component's own tick, so the arm drawn in frame N was solved against the controller as it stood BEFORE
--     frame N's world tick, i.e. where frame N-1 left it;
--   * the weapon is placed afterwards, in the stereo view calculation (UObjectHook motion controller state from
--     weaponhook.lua, plus two_handed.lua's pivot), from frame N's controller pose.
-- The gun was therefore always one frame of hand motion ahead of the hand: the grip slid whenever the gun moved
-- or turned. In Hands mode the glove is driven by the same controller pose as the gun, so it never showed there.
--
-- Hellraiser fixes this by parenting the gun to the rig's hand bone. Here the gun stays on UObjectHook
-- (two_handed.lua's pivot relies on the hook re-placing it every stereo view), so the same result is reached
-- from the other side: the weapon is DRAWN where the visible arm pose holds it.
--   * post stereo (priority -1000, after two_handed.lua has pivoted the gun): the gun's pose is remembered as the
--     true pose, and the component is moved to the recorded rig-relative pose (below) on the rig mesh as it
--     stands now - exactly what a child of the hand bone would do;
--   * when the rig solves (pre engine tick, priority 1000 = before the solve), the true pose is recorded RELATIVE
--     TO THE RIG MESH. The solved arm is a set of bones in that mesh's space, so this is where the hand holds the
--     gun no matter how the rig moves afterwards. The component is also put back on the true pose first, so the
--     game's own tick (shots, traces, OW2AimFix, animation) and the IK solve (two-handing targets the left hand at
--     the gun) see exactly what they saw before this module existed.
-- The relative pose matters: the rig rides the pawn, so a world-space "previous frame" pose would leave the gun a
-- whole frame of walking / turning behind the arms.
-- With Enhanced Stabilization the rig solves in the POST engine tick and those bones are drawn in the next frame,
-- so the pose recorded there is used one frame later (libs/ik.lua getTickPhase).
-- Everything attached to the weapon (mods, scope, reticule) follows it as before. Cost: the gun is drawn one
-- frame later than the controller, like the IK arms themselves.

local uevrUtils   = require('libs/uevr_utils')
local configui    = require('libs/configui')
local attachments = require('libs/attachments')
local ik          = require('libs/ik')

local HANDS_MODE_IK = 2
local CAPTURE_PRIORITY = 1000 -- engine tick callbacks: ahead of the rig's solve (libs/ik.lua registers at priority 0)
local LATE_PRIORITY = -1000   -- post stereo: after two_handed.lua (default priority) has placed / pivoted the gun
local SAME_POSE_EPSILON = 0.0005

local tickSerial = 0
-- { address, truePose = world pose this frame, rendered = world pose written for drawing,
--   relative = pose on the rig mesh for the arm pose being drawn, pending = the same for the next frame }
local entry = nil

local function isEnabled()
	return configui.getValue("ik_weapon_lock") ~= false and _G.getHandsMode ~= nil and _G.getHandsMode() == HANDS_MODE_IK and ik.exists()
end

local function readPose(component)
	local loc, rot = component:K2_GetComponentLocation(), component:K2_GetComponentRotation()
	if loc == nil or rot == nil then return nil end
	return { X = loc.X, Y = loc.Y, Z = loc.Z, Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }
end

local function writePose(component, pose)
	component:K2_SetWorldLocationAndRotation(uevrUtils.vector(pose.X, pose.Y, pose.Z),
		uevrUtils.rotator(pose.Pitch, pose.Yaw, pose.Roll), false, reusable_hit_result, false)
end

local function samePose(a, b)
	return math.abs(a.X - b.X) < SAME_POSE_EPSILON and math.abs(a.Y - b.Y) < SAME_POSE_EPSILON
		and math.abs(a.Z - b.Z) < SAME_POSE_EPSILON and math.abs(a.Pitch - b.Pitch) < SAME_POSE_EPSILON
		and math.abs(a.Yaw - b.Yaw) < SAME_POSE_EPSILON and math.abs(a.Roll - b.Roll) < SAME_POSE_EPSILON
end

-- rigid transform (unit scale) of a pose table
local function makeTransform(pose)
	return kismet_math_library:MakeTransform(uevrUtils.vector(pose.X, pose.Y, pose.Z),
		uevrUtils.rotator(pose.Pitch, pose.Yaw, pose.Roll), uevrUtils.vector(1, 1, 1))
end

local function transformPose(transform, pose)
	local loc = kismet_math_library:TransformLocation(transform, uevrUtils.vector(pose.X, pose.Y, pose.Z))
	local rot = kismet_math_library:TransformRotation(transform, uevrUtils.rotator(pose.Pitch, pose.Yaw, pose.Roll))
	return { X = loc.X, Y = loc.Y, Z = loc.Z, Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }
end

local function getRigPose()
	local rig = ik.getCurrentMesh()
	if rig == nil or rig.K2_GetComponentLocation == nil then return nil end
	return readPose(rig)
end

-- a world pose in the rig mesh's space, with the rig mesh where it is now
local function worldToRelative(pose)
	local rigPose = getRigPose()
	if rigPose == nil or pose == nil then return nil end
	return transformPose(kismet_math_library:InvertTransform(makeTransform(rigPose)), pose)
end

-- a rig-relative pose back in world space, with the rig mesh where it is now
local function relativeToWorld(relative)
	local rigPose = getRigPose()
	if rigPose == nil then return nil end
	return transformPose(makeTransform(rigPose), relative)
end

-- the right-hand weapon mesh weaponhook.lua has on the controller hook
local function getWeapon()
	return attachments.getCurrentGrippedAttachment(Handed.Right)
end

-- Post stereo, gun at its true pose for this view (UObjectHook + two-handed pivot): remember it and draw the gun
-- where the arm pose being drawn holds it. Runs for every view; UObjectHook re-places the gun before each one.
local function place(weapon)
	local address = weapon:get_address()
	if entry == nil or entry.address ~= address then
		entry = { address = address }
	end
	local pose = readPose(weapon)
	if pose == nil then return end
	if entry.tick ~= tickSerial then
		entry.tick = tickSerial
	elseif entry.rendered ~= nil and samePose(pose, entry.rendered) then
		-- called again in the same frame and UObjectHook has not re-placed the gun since our write: this is the
		-- rendering pose, not a new sample
		return
	end
	entry.truePose = pose

	if entry.relative ~= nil then
		local render = relativeToWorld(entry.relative)
		if render ~= nil then
			writePose(weapon, render)
			entry.rendered = render
		end
	end
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index)
	if not isEnabled() then entry = nil return end
	local ok = pcall(function()
		local weapon = getWeapon()
		if weapon ~= nil then
			place(weapon)
		else
			entry = nil
		end
	end)
	if not ok then entry = nil end
end, LATE_PRIORITY)

-- pre engine tick, before the rig solves: the gun back on its true pose, then (rig solving in this tick) record
-- where the arm pose that is about to be solved holds it
uevrUtils.registerPreEngineTickCallback(function(engine, delta)
	tickSerial = tickSerial + 1
	if entry == nil then return end
	if not isEnabled() then entry = nil return end
	local ok = pcall(function()
		local weapon = getWeapon()
		if weapon == nil or weapon:get_address() ~= entry.address then error("weapon changed") end
		if entry.rendered ~= nil and entry.truePose ~= nil then writePose(weapon, entry.truePose) end
		entry.rendered = nil
		if ik.getTickPhase() == "post" then
			entry.relative = entry.pending -- solved after the previous world tick, drawn in this frame
		else
			entry.relative = worldToRelative(entry.truePose)
		end
	end)
	if not ok then entry = nil end
end, CAPTURE_PRIORITY)

-- Enhanced Stabilization: the rig solves here, for the next frame
uevrUtils.registerPostEngineTickCallback(function(engine, delta)
	if entry == nil or ik.getTickPhase() ~= "post" then return end
	local ok = pcall(function()
		entry.pending = worldToRelative(entry.truePose)
	end)
	if not ok then entry = nil end
end, CAPTURE_PRIORITY)

uevrUtils.registerPreLevelChangeCallback(function(level)
	entry = nil
end)

print("[ik_weapon_sync] loaded")
