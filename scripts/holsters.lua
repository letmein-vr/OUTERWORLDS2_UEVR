-- Holsters / gesture zones for The Outer Worlds 2 (2026-11-02, from the Hellraiser profile's holsters.lua).
-- A grip press that STARTS with the hand in a zone runs the zone's action:
--   left grip,  left hand at the HMD (in front of the face) -> d-pad up tap   flashlight (L in the flat game)
--   right grip, right hand at the right hip                 -> weapon slot 1  ('1' in the flat game)
--   right grip, right hand at the right shoulder            -> weapon slot 2  ('2')
--   right grip, right hand at the left shoulder             -> weapon slot 3  ('3')
--   right grip, right hand at the left hip                  -> weapon slot 4  ('4')
--
-- Weapon slots call the game's own PlayerEquipment:EquipWeaponFromSlot(index 0-3, false, false) (MCP 2026-11-02: index 1
-- queued the slot-2 SMG with the normal equip animation; slot 0 = the first weapon) instead of faking the number keys: an
-- injected keyboard key needs the input-device switch dance Stalker 2 needed (the first key after gamepad input is spent
-- switching device), the function call does not. It runs on the next pre-engine tick, not inside the input poll.
-- Zones: boxes around the head in the HMD's yaw-only frame - origin = HMD position, yaw = HMD yaw (pitch / roll ignored,
-- so looking down at a hip does not move the zones). X forward, Y right, Z up, cm. Measured with libs/controllers.lua.
-- The grip that started a zone action is kept from the game (and from the hand poses / two-handing / the LB-LT swap,
-- which all run after this at lower priority) until it is released. A short haptic pulse when a hand enters a zone.
-- Off in full-screen menus (_G.ow2IsMenuOpen), while paused and while input is disabled (cutscenes, libs/ui.lua).

local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require('libs/configui')

local vr = uevr.params.vr

local BTN_LB = 0x0100 -- XINPUT_GAMEPAD_LEFT_SHOULDER  (the left grip)
local BTN_RB = 0x0200 -- XINPUT_GAMEPAD_RIGHT_SHOULDER (the right grip)
local BTN_UP = 0x0001 -- XINPUT_GAMEPAD_DPAD_UP
local TAP_POLLS = 3
local TAP_MAX_S = 0.25

-- id, hand, label, action, default centre (cm, body frame)
local ZONES = {
    { id = "face", hand = Handed.Left,  label = "Face, left hand (flashlight)", button = BTN_UP, x = 10.0, y = 0.0, z = -3.0 },
    { id = "rhip", hand = Handed.Right, label = "Right hip (slot 1)",           slot = 0, x = 0.0,   y = 22.0,  z = -65.0 },
    { id = "rsh",  hand = Handed.Right, label = "Right shoulder (slot 2)",      slot = 1, x = -12.0, y = 20.0,  z = -10.0 },
    { id = "lsh",  hand = Handed.Right, label = "Left shoulder (slot 3)",       slot = 2, x = -12.0, y = -20.0, z = -10.0 },
    { id = "lhip", hand = Handed.Right, label = "Left hip (slot 4)",            slot = 3, x = 0.0,   y = -22.0, z = -65.0 },
}

local layout = {
    { widgetType = "checkbox", id = "hz_enabled", label = "Holsters: right grip at hips / shoulders = weapon slots 1-4, left grip at the face = flashlight", initialValue = true },
    { widgetType = "checkbox", id = "hz_haptic", label = "Haptic pulse when a hand enters a zone", initialValue = true },
    { widgetType = "slider_float", id = "hz_size", label = "Body zone size (cm, half width of each box)", initialValue = 16.0, range = {6.0, 35.0}, speed = 0.5 },
    { widgetType = "slider_float", id = "hz_face_size", label = "Face zone size (cm, half width)", initialValue = 12.0, range = {6.0, 35.0}, speed = 0.5 },
    { widgetType = "text", id = "hz_status", label = "Hands: -" },
    { widgetType = "text", label = "Zone centres (cm from the HMD: forward / right / up, body facing)" },
}
for _, z in ipairs(ZONES) do
    table.insert(layout, { widgetType = "drag_float3", id = "hz_" .. z.id, label = z.label, initialValue = { z.x, z.y, z.z }, range = {-120, 120}, speed = 0.5 })
end
_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 2.7, label = "Holsters", layout = layout })

local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

-- configui drag_float3 values come back as vectors (X/Y/Z) or arrays
local function zoneCentre(z)
    local v = configui.getValue("hz_" .. z.id)
    if type(v) == "table" or type(v) == "userdata" then
        local ok, x, y, zz = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
        if ok and type(x) == "number" and type(y) == "number" and type(zz) == "number" then return x, y, zz end
    end
    return z.x, z.y, z.z
end

local function blocked()
    if _G.ow2IsMenuOpen ~= nil and _G.ow2IsMenuOpen() then return true end
    if uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_input_disabled") == true then return true end
    local world = uevrUtils.get_world()
    return world ~= nil and Statics ~= nil and Statics:IsGamePaused(world) == true
end

-- a hand in the zone frame: returns local x, y, z (cm) or nil
local function handLocal(hand)
    local pos = controllers.getControllerLocation(hand)
    local head = controllers.getControllerLocation(2)
    if pos == nil or head == nil then return nil end
    local headRot = controllers.getControllerRotation(2)
    local yaw = math.rad((headRot and headRot.Yaw) or 0)
    local dx, dy, dz = pos.X - head.X, pos.Y - head.Y, pos.Z - head.Z
    local c, s = math.cos(yaw), math.sin(yaw)
    return dx * c + dy * s, -dx * s + dy * c, dz
end

local function zoneAt(hand, x, y, z)
    local bodySize, faceSize = cfgNum("hz_size", 16.0), cfgNum("hz_face_size", 12.0)
    for _, zone in ipairs(ZONES) do
        if zone.hand == hand then
            local h = zone.id == "face" and faceSize or bodySize
            local cx, cy, cz = zoneCentre(zone)
            if math.abs(x - cx) <= h and math.abs(y - cy) <= h and math.abs(z - cz) <= h then return zone end
        end
    end
    return nil
end

local function haptic(hand, duration, amplitude)
    pcall(function()
        local source = hand == Handed.Left and vr.get_left_joystick_source() or vr.get_right_joystick_source()
        vr.trigger_haptic_vibration(0, duration, 1.0, amplitude, source)
    end)
end

-- per hand: grip button, zone the hand is in, grip edge, swallow flag
local hands = {
    [Handed.Left]  = { grip = BTN_LB, current = nil, gripWasDown = false, swallow = false },
    [Handed.Right] = { grip = BTN_RB, current = nil, gripWasDown = false, swallow = false },
}
local tap = { button = 0, polls = 0, deadline = 0 }
local pendingSlot = nil
local nextStatusAt = 0

local function runZone(hand, zone)
    haptic(hand, 0.08, 1.0)
    if zone.slot ~= nil then
        pendingSlot = zone.slot
    elseif tap.polls <= 0 then
        tap.button, tap.polls, tap.deadline = zone.button, TAP_POLLS, os.clock() + TAP_MAX_S
    end
    print("[holsters] " .. zone.label)
end

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    local enabled = configui.getValue("hz_enabled") ~= false and not blocked()
    local status = {}
    for hand, h in pairs(hands) do
        local grip = uevrUtils.isButtonPressed(state, h.grip)
        local pressed = grip and not h.gripWasDown
        h.gripWasDown = grip
        if h.swallow and not grip then h.swallow = false end

        if enabled then
            local ok, err = pcall(function()
                local x, y, z = handLocal(hand)
                local zone = x ~= nil and zoneAt(hand, x, y, z) or nil
                if zone ~= h.current then
                    h.current = zone
                    if zone ~= nil and configui.getValue("hz_haptic") ~= false then haptic(hand, 0.03, 0.4) end
                end
                if pressed and zone ~= nil then
                    h.swallow = true
                    runZone(hand, zone)
                end
                if x ~= nil then
                    table.insert(status, string.format("%s %.0f / %.0f / %.0f %s", hand == Handed.Left and "L" or "R", x, y, z, zone and zone.label or "-"))
                end
            end)
            if not ok then print("[holsters] " .. tostring(err)) end
        elseif h.current ~= nil then
            h.current = nil
        end

        if h.swallow and grip then state.Gamepad.wButtons = state.Gamepad.wButtons & ~h.grip end
    end

    -- status line at most 5x a second
    if #status > 0 and os.clock() >= nextStatusAt then
        nextStatusAt = os.clock() + 0.2
        configui.setLabel("hz_status", "Hands: " .. table.concat(status, "  |  "))
    end

    if tap.polls > 0 then
        if os.clock() > tap.deadline then
            tap.polls = 0
        else
            state.Gamepad.wButtons = state.Gamepad.wButtons | tap.button
            tap.polls = tap.polls - 1
        end
    end
end, 25) -- before physical_melee (20), the hand poses (10), two_handed (5), the LB/LT swap (1) and remap (0)

uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    if pendingSlot == nil then return end
    local slot = pendingSlot
    pendingSlot = nil
    local ok, err = pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local equipment = pawn ~= nil and pawn.PlayerEquipment or nil
        if equipment ~= nil then equipment:EquipWeaponFromSlot(slot, false, false) end
    end)
    if not ok then print("[holsters] equip slot " .. tostring(slot + 1) .. ": " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    for _, h in pairs(hands) do h.current, h.swallow = nil, false end
    tap.polls, pendingSlot = 0, nil
end)
