-- Swaps Right controller "X" with Left Controller "B"


local api = uevr.api
local params = uevr.params
local callbacks = params.sdk.callbacks

local block_x = false
local block_b = false

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    if (state ~= nil) then
        if state.Gamepad.wButtons & 0x4000 ~= 0 and block_b == false then
            block_x = true
            state.Gamepad.wButtons = state.Gamepad.wButtons & ~(XINPUT_GAMEPAD_X)
            state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_B
            --print("X to B Button")
        else
            block_x = false
        end

        if state.Gamepad.wButtons & 0x2000 ~= 0 and block_x == false then
            block_b = true
            state.Gamepad.wButtons = state.Gamepad.wButtons & ~(XINPUT_GAMEPAD_B)
            state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_X
            --print("B to X Button")
        else
            block_b = false
        end
    end
end)