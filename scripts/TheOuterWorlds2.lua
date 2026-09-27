local api = uevr.api
local vr = uevr.params.vr

local prevViewTarget = nil
local game_engine_class = uevr.api:find_uobject("Class /Script/Engine.GameEngine")

local classCache = {}
function get_class(name, clearCache)
	if clearCache or classCache[name] == nil then
		classCache[name] = uevr.api:find_uobject(name)
	end
    return classCache[name]
end


local config_filename = "TheOuterWorlds2.txt"
local config_data = nil
local config_changed = false
local normal_depth = 1.2
local normal_size = 1.2
local aiming_depth = 10
local aiming_size = 6.5
local conversation_depth = 0.4
local conversation_size = 0.35
local hud_state_far = true
local last_changed = os.clock() 
local forward_offset_multiplier = 3.6
local up_offset_multiplier = 0.2
local fov_max_trigger = 50
local current_fov = 0
local enable_fov_zoom = true
local enable_conv_fix = true
local enable_aim_distances = true
local target = nil
local aim_method = 2
local enable_conv_shadows = true
local conv_shadows_true_percentage = 40
local conv_shadows_false_percentage = 50
local shadows_current_value = 1
local was_conv_distance = false

local function write_config()
	config_data = "normal_depth=" .. tostring(normal_depth) .. "\n"   
    config_data = config_data .. "normal_size=" .. tostring(normal_size) .. "\n"        
    config_data = config_data .. "aiming_depth=" .. tostring(aiming_depth) .. "\n"             
    config_data = config_data .. "aiming_size=" .. tostring(aiming_size) .. "\n"     
    config_data = config_data .. "conversation_depth=" .. tostring(conversation_depth) .. "\n"             
    config_data = config_data .. "conversation_size=" .. tostring(conversation_size) .. "\n"     
    config_data = config_data .. "forward_offset_multiplier=" .. tostring(forward_offset_multiplier) .. "\n"   
    config_data = config_data .. "up_offset_multiplier=" .. tostring(up_offset_multiplier) .. "\n"        
    config_data = config_data .. "enable_fov_zoom=" .. tostring(enable_fov_zoom) .. "\n"             
    config_data = config_data .. "fov_max_trigger=" .. tostring(fov_max_trigger) .. "\n"  
    config_data = config_data .. "aim_method=" .. tostring(aim_method) .. "\n"  
    config_data = config_data .. "enable_conv_fix=" .. tostring(enable_conv_fix) .. "\n"             
    config_data = config_data .. "enable_aim_distances=" .. tostring(enable_aim_distances) .. "\n"             
    config_data = config_data .. "enable_conv_shadows=" .. tostring(enable_conv_shadows) .. "\n"             
    config_data = config_data .. "conv_shadows_true_percentage=" .. tostring(conv_shadows_true_percentage) .. "\n"             
    config_data = config_data .. "conv_shadows_false_percentage=" .. tostring(conv_shadows_false_percentage) .. "\n"             
                  
    fs.write(config_filename, config_data)
end

local function read_config()
    print("reading config")
    config_data = fs.read(config_filename)
    if config_data then -- Check if file was read successfully
        print("config read")
        for key, value in config_data:gmatch("([^=]+)=([^\n]+)\n?") do                       
            if key == "normal_depth" then
                normal_depth = tonumber(value) or 1.2          
            end  
            if key == "normal_size" then
                normal_size = tonumber(value) or 1.2           
            end                   
            if key == "aiming_depth" then
                aiming_depth = tonumber(value) or 10          
            end                   
            if key == "aiming_size" then
                aiming_size = tonumber(value) or 7       
            end       
            if key == "conversation_depth" then
                conversation_depth = tonumber(value) or 0.4           
            end  
            if key == "conversation_size" then
                conversation_size = tonumber(value) or 0.35           
            end                            
            if key == "forward_offset_multiplier" then
                forward_offset_multiplier = tonumber(value) or 3.2            
            end  
            if key == "up_offset_multiplier" then
                up_offset_multiplier = tonumber(value) or 0.8            
            end                   
            if key == "fov_max_trigger" then
                fov_max_trigger = tonumber(value) or 50            
            end   
            if key == "aim_method" then
                aim_method = tonumber(value) or 2
            end                   
            if key == "enable_fov_zoom" then
                if value == "false" then
                    enable_fov_zoom = false
                else
                    enable_fov_zoom = true
                end                    
            end    
            if key == "enable_conv_fix" then
                if value == "false" then
                    enable_conv_fix = false
                else
                    enable_conv_fix = true
                end                    
            end    
            if key == "enable_aim_distances" then
                if value == "false" then
                    enable_aim_distances = false
                else
                    enable_aim_distances = true
                end                    
            end    
            if key == "enable_conv_shadows" then
                if value == "false" then
                    enable_conv_shadows = false
                else
                    enable_conv_shadows = true
                end                    
            end    
            if key == "conv_shadows_true_percentage" then
                conv_shadows_true_percentage = tonumber(value) or 40            
            end   
            if key == "conv_shadows_false_percentage" then
                conv_shadows_false_percentage = tonumber(value) or 50            
            end   
        end
    else
        print("Error: Could not read config file.")
    end
end

read_config()

-- ---------------------------------------------------------------------------------------------
-- "UI & Conversations" section of the merged "Outer Worlds 2 VR" panel (built by
-- scripts/zz_ow2_vr_panel.lua). Settings live in configui (saved with the other sections in
-- data/ow2_vr_config.json); the locals above are mirrors, kept in sync through onUpdate so the tick code
-- below is unchanged. TheOuterWorlds2.txt is read once more only to migrate its values into the new
-- file. The old hand-written ImGui panel had two copy-paste bugs (the conversation distance and size
-- sliders wrote the aiming values); the bindings below are one-to-one.
-- ---------------------------------------------------------------------------------------------
local configui = require("libs/configui")

_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 5, label = "UI & Conversations", layout = {
    { widgetType = "text", label = "Aiming" },
    { widgetType = "checkbox", id = "ow2_conv_fix", label = "Rotation fix: switch to game aim in conversations and menus", initialValue = enable_conv_fix },
    { widgetType = "combo", id = "ow2_aim_method", label = "Aiming method when the fix is on", initialValue = aim_method, selections = {"Head / HMD", "Right Controller"} },
    { widgetType = "spacing" },
    { widgetType = "text", label = "Conversations" },
    { widgetType = "checkbox", id = "ow2_fov_zoom", label = "Conversation zoom (match the desktop framing)", initialValue = enable_fov_zoom },
    { widgetType = "text", id = "ow2_fov_label", label = "Current FOV: -" },
    { widgetType = "slider_float", id = "ow2_fov_max", label = "Zoom kicks in below FOV", initialValue = fov_max_trigger, range = {0.0, 150.0} },
    { widgetType = "slider_float", id = "ow2_fwd_mult", label = "Zoom forward offset multiplier", initialValue = forward_offset_multiplier, range = {0.0, 20.0} },
    { widgetType = "slider_float", id = "ow2_up_mult", label = "Zoom up offset multiplier", initialValue = up_offset_multiplier, range = {0.0, 10.0} },
    { widgetType = "checkbox", id = "ow2_conv_shadows", label = "High quality shadows in conversations (costs performance)", initialValue = enable_conv_shadows },
    { widgetType = "spacing" },
    { widgetType = "text", label = "UI distance and size" },
    { widgetType = "checkbox", id = "ow2_aim_dist", label = "Automatic: far when aiming, normal in menus, close in conversations", initialValue = enable_aim_distances },
    { widgetType = "slider_float", id = "ow2_normal_depth", label = "Normal distance", initialValue = normal_depth, range = {0.0, 10.0} },
    { widgetType = "slider_float", id = "ow2_normal_size", label = "Normal size", initialValue = normal_size, range = {0.0, 10.0} },
    { widgetType = "slider_float", id = "ow2_aiming_depth", label = "Aiming distance", initialValue = aiming_depth, range = {0.0, 10.0} },
    { widgetType = "slider_float", id = "ow2_aiming_size", label = "Aiming size", initialValue = aiming_size, range = {0.0, 10.0} },
    { widgetType = "slider_float", id = "ow2_conv_depth", label = "Conversation distance", initialValue = conversation_depth, range = {0.0, 10.0} },
    { widgetType = "slider_float", id = "ow2_conv_size", label = "Conversation size", initialValue = conversation_size, range = {0.0, 10.0} },
}})

-- values from TheOuterWorlds2.txt, copied into ow2_vr_config.json the first time the merged panel is built
_G.OW2_MIGRATION = _G.OW2_MIGRATION or {}
for k, v in pairs({
    ow2_conv_fix = enable_conv_fix, ow2_aim_method = aim_method, ow2_fov_zoom = enable_fov_zoom,
    ow2_fov_max = fov_max_trigger, ow2_fwd_mult = forward_offset_multiplier, ow2_up_mult = up_offset_multiplier,
    ow2_conv_shadows = enable_conv_shadows, ow2_aim_dist = enable_aim_distances,
    ow2_normal_depth = normal_depth, ow2_normal_size = normal_size, ow2_aiming_depth = aiming_depth,
    ow2_aiming_size = aiming_size, ow2_conv_depth = conversation_depth, ow2_conv_size = conversation_size,
}) do _G.OW2_MIGRATION[k] = v end

-- widget id -> mirror local (no side effects, used both for live edits and the startup sync)
local setters = {
    ow2_conv_fix     = function(v) enable_conv_fix = (v == true) end,
    ow2_aim_method   = function(v) aim_method = tonumber(v) or aim_method end,
    ow2_fov_zoom     = function(v) enable_fov_zoom = (v == true) end,
    ow2_fov_max      = function(v) fov_max_trigger = tonumber(v) or fov_max_trigger end,
    ow2_fwd_mult     = function(v) forward_offset_multiplier = tonumber(v) or forward_offset_multiplier end,
    ow2_up_mult      = function(v) up_offset_multiplier = tonumber(v) or up_offset_multiplier end,
    ow2_conv_shadows = function(v) enable_conv_shadows = (v == true) end,
    ow2_aim_dist     = function(v) enable_aim_distances = (v == true) end,
    ow2_normal_depth = function(v) normal_depth = tonumber(v) or normal_depth end,
    ow2_normal_size  = function(v) normal_size = tonumber(v) or normal_size end,
    ow2_aiming_depth = function(v) aiming_depth = tonumber(v) or aiming_depth end,
    ow2_aiming_size  = function(v) aiming_size = tonumber(v) or aiming_size end,
    ow2_conv_depth   = function(v) conversation_depth = tonumber(v) or conversation_depth end,
    ow2_conv_size    = function(v) conversation_size = tonumber(v) or conversation_size end,
}
for id, setter in pairs(setters) do
    configui.onUpdate(id, function(value) setter(value) end)
end
-- the aiming-method combo also applies immediately, as the old panel did (only on a user edit, never at startup)
configui.onUpdate("ow2_aim_method", function(value)
    uevr.params.vr.set_mod_value("VR_AimMethod", tonumber(value) or aim_method)
end)

-- The merged panel is created after this script loads, so pull the saved values in on the first tick
-- that has them (configui.getValue is nil until then).
local ow2PanelSynced = false
local function syncFromPanel()
    if ow2PanelSynced then return end
    if configui.getValue("ow2_normal_depth") == nil then return end
    for id, setter in pairs(setters) do
        local v = configui.getValue(id)
        if v ~= nil then setter(v) end
    end
    ow2PanelSynced = true
end
local nextFovLabel = 0
local function updatePanelReadout()
    syncFromPanel()
    local now = os.clock()
    if now >= nextFovLabel then
        nextFovLabel = now + 0.25
        configui.setLabel("ow2_fov_label", string.format("Current FOV: %.1f", current_fov or 0))
    end
end


local IsInMenu = false
local LedgerClass = nil
local BackDown = false
local BDown = false
local WasBackDown = false
local WasBDown = false

local function find_required_object(name)
    local obj = uevr.api:find_uobject(name)
    if not obj then
        return nil
    end

    return obj
end

local function OpenMenu()
    if IsInMenu == true then return end
    IsInMenu = true
    print("Calling open menu set IsInMenu true")
    
    if LedgerClass == nil then
        LedgerClass = find_required_object("Class /Script/Arkansas.IndianaPlayerController")
        if LedgerClass == nil then return end
    end
    
    local instance = LedgerClass:get_first_object_matching(true)
    if instance ~= nil then
        if instance.OpenLedger then
            instance:OpenLedger()
        end
    end
end

local function CloseMenu()
    if IsInMenu == false then return end
    IsInMenu = false
    print("Calling closemenu set IsInMenu false")
    if LedgerClass == nil then
        LedgerClass = find_required_object("Class /Script/Arkansas.IndianaPlayerController")
        if LedgerClass == nil then return end
    end
    
    local instance = LedgerClass:get_first_object_matching(true)
    if instance ~= nil then
        if instance.OpenLedger then
            instance:OpenLedger()
        end
    end

end

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)    
    if os.clock() - last_changed > 1 then
        if enable_aim_distances then        
            local gamepad = state.Gamepad
            local left_trigger_pressed = false    
            
            if (gamepad.bLeftTrigger > 220) then
                left_trigger_pressed = true
            elseif (gamepad.bLeftTrigger < 10) then
                left_trigger_pressed = false
            end

            local buttons = gamepad.wButtons                
            local menu_pressed = (buttons & XINPUT_GAMEPAD_START) ~= 0 or (buttons & XINPUT_GAMEPAD_BACK) ~= 0        

            if (menu_pressed) then            
                uevr.params.vr.set_mod_value("UI_Distance",normal_depth)
                uevr.params.vr.set_mod_value("UI_Size",normal_size)
                --last_changed = os.clock()                
            end
            if left_trigger_pressed then
                uevr.params.vr.set_mod_value("UI_Distance",aiming_depth)
                uevr.params.vr.set_mod_value("UI_Size",aiming_size)
                --last_changed = os.clock()                
            end                        
        end
    
        if state.Gamepad.wButtons & XINPUT_GAMEPAD_BACK == 0 then
            BackDown = false
        else
            BackDown = true
        end        
        
        if state.Gamepad.wButtons & XINPUT_GAMEPAD_B == 0 then
            BDown = false
        else
            BDown = true
        end        
        
        state.Gamepad.wButtons = state.Gamepad.wButtons & ~(XINPUT_GAMEPAD_BACK)
        
        if IsInMenu == true then
            state.Gamepad.wButtons = state.Gamepad.wButtons & ~(XINPUT_GAMEPAD_BACK)
            
            if (BackDown and not WasBackDown) or (BDown and not WasBDown) then                 
                CloseMenu()
            end
        else
            if (BackDown and not WasBackDown) then            
                OpenMenu()
            end
        end
        WasBackDown = BackDown
        WasBDown = BDown
    end
end)

-- run this every engine tick, *after* the world has been updated
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)   	    
    local game_engine       = UEVR_UObjectHook.get_first_object_by_class(game_engine_class)
    local player            = uevr.api:get_player_controller(0)
    if player then                                               
        local pawn = uevr.api:get_local_pawn(0)
        if pawn then            
            local playerController = pawn.Controller
            if playerController ~= nil then	
                local cameraManager = playerController.PlayerCameraManager                
                if cameraManager ~= nil then
                    target = cameraManager.ViewTarget.Target
                    current_fov = 0
                    if (cameraManager and cameraManager.ViewTarget and cameraManager.ViewTarget.POV and cameraManager.ViewTarget.POV.FOV) then
                        current_fov = cameraManager.ViewTarget.POV.FOV
                    end                                                   
                end
            end
        end
        updatePanelReadout()
        if current_fov>1 and current_fov<fov_max_trigger then                     
            if enable_aim_distances then
                was_conv_distance = true
                --also set UI to close
                uevr.params.vr.set_mod_value("UI_Distance",conversation_depth)
                uevr.params.vr.set_mod_value("UI_Size",conversation_size)
                last_changed = os.clock()          
            end
            if enable_conv_fix then
                uevr.params.vr.set_mod_value("VR_AimMethod",0)            
            end
            if enable_fov_zoom then
                --exclude terminals
                if current_fov <= 32.99 or current_fov >= 33.01 then
                    if enable_conv_shadows then
                        if shadows_current_value == 1 then
                            uevr.api:dispatch_custom_event("set_cvar", "r.Shadow.Virtual.Enable 0")                        
                            shadows_current_value = 0
                        end
                    end
                    --uevr.api:dispatch_custom_event("set_cvar", "r.ScreenPercentage " .. tostring(conv_shadows_true_percentage))
                    --uevr.api:dispatch_custom_event("set_cvar", "r.ScreenPercentage 33")
                    local forward = (fov_max_trigger-current_fov)*forward_offset_multiplier                            
                    if (forward > 0) then
                        uevr.params.vr.set_mod_value("VR_CameraForwardOffset",forward)
                    end

                    local up = (fov_max_trigger-current_fov)
                    if (up>0) then
                        up=up*up_offset_multiplier                                
                        uevr.params.vr.set_mod_value("VR_CameraUpOffset",up)
                    end
                end
            end
        else                     
            if enable_conv_fix then                
                if IsInMenu then
                    uevr.params.vr.set_mod_value("VR_AimMethod",0) 
                else
                    uevr.params.vr.set_mod_value("VR_AimMethod",aim_method)            
                end
            end
            if enable_fov_zoom then
                if enable_conv_shadows then
                    if shadows_current_value == 0 then
                        uevr.api:dispatch_custom_event("set_cvar", "r.Shadow.Virtual.Enable 1")
                        shadows_current_value = 1
                    end
                end
                --uevr.api:dispatch_custom_event("set_cvar", "r.ScreenPercentage " .. tostring(conv_shadows_false_percentage))
                --uevr.api:dispatch_custom_event("set_cvar", "r.ScreenPercentage 100")
                uevr.params.vr.set_mod_value("VR_CameraForwardOffset",0)
                uevr.params.vr.set_mod_value("VR_CameraUpOffset",0)                        
            end
            if enable_aim_distances and was_conv_distance then                
                uevr.params.vr.set_mod_value("UI_Distance",normal_depth)
                uevr.params.vr.set_mod_value("UI_Size",normal_size)                          
                was_conv_distance = false
            end
        end                            
    end        
end)
