-- Per-weapon IK hand offset for The Outer Worlds 2 (2026-11-01, IK half of the Borderlands 4 per-attachment hand offset).
--
-- The attachments panel's "IK: Hand Position Offset" / "IK: Hand Rotation Offset" of the weapon held in the right hand are
-- added to the right-hand IK solver's end bone offset / rotation (the solver driven by the right controller in
-- data/ik_parameters.json): effective offset = saved + location, effective rotation = ComposeRotators(rotation, saved) -
-- the same formula the glove hands use for their hand joint (libs/hands.lua getJointTransform). The gun rides the
-- controller, so only the hand moves on the grip. Runtime only (ik.setSolverRuntimeParameter): ik_parameters.json is
-- never written. Re-applied whenever the rig is rebuilt (level load, suit change, mode switch), the weapon changes or an
-- offset is edited.
--
-- _G.ow2IKRightHandRest() -> solverId, offset {x,y,z}, rotation {p,y,r}: the effective (weapon-adjusted) right-hand
-- target, for scripts that override the solver temporarily (weapon_recoil.lua) and put it back afterwards.

local uevrUtils   = require('libs/uevr_utils')
local attachments = require('libs/attachments')
local ik          = require('libs/ik')

local HANDS_MODE_IK = 2

local saved = nil      -- { solverId, offset, rotation } from ik_parameters.json (re-read per rig)
local effective = nil  -- { solverId, offset, rotation } last pushed to the rig
local appliedKey = nil
local appliedAt, nextPush = 0, 0
local offsetVersion = 0

local function readSavedSolver()
    local result = nil
    pcall(function()
        local params = json.load_file("ik_parameters.json")
        local profileName = params and params["_profileState"] and params["_profileState"]["currentEditingProfile"] or "default"
        local profile = params and (params[profileName] or params["default"])
        for id, solver in pairs(profile and profile["solvers"] or {}) do
            if solver["end_control_type"] == 1 then -- ik.ControllerType.RIGHT_CONTROLLER
                result = { solverId = id, offset = solver["end_bone_offset"] or { 0, 0, 0 }, rotation = solver["end_bone_rotation"] or { 0, 0, 0 } }
            end
        end
    end)
    return result
end

local function computeEffective(base, id)
    local loc, rot = attachments.getAttachmentHandOffset(id, true)
    loc, rot = loc or { 0, 0, 0 }, rot or { 0, 0, 0 }
    local o, r = base.offset, base.rotation
    local composed = kismet_math_library:ComposeRotators(uevrUtils.rotator(rot[1], rot[2], rot[3]), uevrUtils.rotator(r[1], r[2], r[3]))
    return {
        solverId = base.solverId,
        offset = { o[1] + loc[1], o[2] + loc[2], o[3] + loc[3] },
        rotation = { composed.Pitch, composed.Yaw, composed.Roll },
    }
end

_G.ow2IKRightHandRest = function()
    local e = effective or saved or readSavedSolver()
    if e == nil then return nil end
    return e.solverId, e.offset, e.rotation
end

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    if _G.getHandsMode == nil or _G.getHandsMode() ~= HANDS_MODE_IK then appliedKey, effective = nil, nil return end
    local ok, err = pcall(function()
        local rig = ik.getCurrentMesh()
        if rig == nil then appliedKey, effective = nil, nil return end
        local id = attachments.getActiveAttachmentID(Handed.Right) or ""
        local key = tostring(rig:get_address()) .. "|" .. id .. "|" .. offsetVersion
        local now = os.clock()
        if key == appliedKey then
            -- a fresh rig's solver may not be active yet (ik.lua retries setActive after 1 s) and ignores parameters until
            -- then: push again a few times shortly after each change, then stay quiet (weapon_recoil.lua drives the
            -- solver per frame while kicking)
            if effective == nil or now - appliedAt > 3.0 or now < nextPush then return end
            nextPush = now + 0.5
            ik.setSolverRuntimeParameter(effective.solverId, "end_bone_offset", effective.offset)
            ik.setSolverRuntimeParameter(effective.solverId, "end_bone_rotation", effective.rotation)
            return
        end
        if appliedKey == nil or not string.find(appliedKey, tostring(rig:get_address()), 1, true) then
            saved = readSavedSolver() -- new rig: it was built from the saved values
        end
        if saved == nil then return end
        effective = computeEffective(saved, id)
        ik.setSolverRuntimeParameter(effective.solverId, "end_bone_offset", effective.offset)
        ik.setSolverRuntimeParameter(effective.solverId, "end_bone_rotation", effective.rotation)
        appliedKey, appliedAt, nextPush = key, now, now + 0.5
    end)
    if not ok then print("[ik_hand_offset] " .. tostring(err)) end
end)

-- IK offset edited in the attachments panel (draw thread): just bump the version, the tick above re-applies
attachments.registerHandOffsetChangeCallback(function(id, isIK)
    if isIK == true then offsetVersion = offsetVersion + 1 end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    appliedKey, effective = nil, nil
end)

print("[ik_hand_offset] loaded")
