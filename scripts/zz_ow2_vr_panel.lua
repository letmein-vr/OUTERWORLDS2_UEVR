-- Builds the single user-facing "Outer Worlds 2 VR" panel in the UEVR overlay.
--
-- Every game script registers its settings as a section in _G.OW2_SECTIONS ({ order, label, layout })
-- instead of creating its own panel; this file loads LAST (UEVR loads scripts in name order, case-
-- insensitive, hence the zz_ prefix) and builds one panel from them. Widget ids are global in configui, so the
-- owning scripts keep using configui.getValue / onUpdate / setLabel exactly as before. All values are saved
-- together in data/ow2_vr_config.json.
--
-- Layout (xaero 2026-11-12, "more player friendly"): the player options listed in MAIN sit at the top of the
-- panel, in that order, with a few group headings; every other widget stays with its section under a collapsed
-- "Dev Config" node (one sub-node per section). _G.OW2_DEV_CONFIG = false hides Dev Config entirely.
--
-- First run: the previous per-script save files (hands_mode_config, two_handed_config,
-- physical_melee_config, camera_stabilize_config) and the values TheOuterWorlds2.lua migrated from
-- TheOuterWorlds2.txt (_G.OW2_MIGRATION) are merged into the new file so nothing tuned is lost.

local configui = require('libs/configui')

local PANEL_LABEL = "Outer Worlds 2 VR"
local SAVE_FILE   = "ow2_vr_config"
local HEADING_COLOR = "#E8C060FF" -- #RRGGBBAA

-- one-time migration of the old per-panel files
if json.load_file(SAVE_FILE .. ".json") == nil then
    local merged = {}
    for _, old in ipairs({ "hands_mode_config", "two_handed_config", "physical_melee_config", "camera_stabilize_config" }) do
        local t = json.load_file(old .. ".json")
        if type(t) == "table" then
            for k, v in pairs(t) do merged[k] = v end
        end
    end
    if type(_G.OW2_MIGRATION) == "table" then
        for k, v in pairs(_G.OW2_MIGRATION) do merged[k] = v end
    end
    if next(merged) ~= nil then
        json.dump_file(SAVE_FILE .. ".json", merged, 4)
        print("[ow2 panel] migrated " .. "the old" .. " settings into " .. SAVE_FILE .. ".json")
    end
end

-- 2026-11-12: the melee mode checkbox pm_contact_mode (true = contact) became the combo pm_melee_type
-- (1 = contact, 2 = fire on swing peak); carry a saved "off" over once
pcall(function()
    local saved = json.load_file(SAVE_FILE .. ".json")
    if type(saved) == "table" and saved.pm_melee_type == nil and saved.pm_contact_mode ~= nil then
        saved.pm_melee_type = (saved.pm_contact_mode == false) and 2 or 1
        json.dump_file(SAVE_FILE .. ".json", saved, 4)
    end
end)

-- The main panel, top to bottom. { id = ..., label = ... } pulls that widget out of its section (label = a
-- friendlier display name; the id and saved value are unchanged); { heading = ... } adds a group heading;
-- { indent = true } / { unindent = true } indent the widgets between them.
local MAIN = {
    { id = "hands_mode", label = "Hands mode" },
    { id = "th_enabled", label = "Two-handed aiming" },
    { id = "th_ads", label = "Aim down sights (ADS) while two-handing" },
    { id = "ow2_recoil_enabled", label = "Weapon recoil" },
    { id = "ow2_recoil_two_handed", label = "Weapon recoil while two-handing" },
    { id = "hz_enabled", label = "Holsters (right grip at hips / shoulders = weapons, left grip at the face = flashlight)" },
    { id = "ps_enabled", label = "PiP scopes" },

    { heading = "Physical Melee" },
    { id = "pm_enabled", label = "Physical melee (swing = attack)" },
    { indent = true },
    { id = "pm_melee_type", label = "Melee type" },
    { id = "pm_hit_buffer", label = "Hit forgiveness (cm)" },
    { unindent = true },

    { heading = "UI & Conversations" },
    { id = "ow2_aim_method", label = "Aiming method (menus and conversations)" },
    { id = "ow2_fov_zoom", label = "Conversation zoom" },
    { id = "ow2_normal_depth", label = "UI distance" },
    { id = "ow2_normal_size", label = "UI size" },
    { id = "ow2_aiming_depth", label = "UI distance while aiming" },
    { id = "ow2_aiming_size", label = "UI size while aiming" },
    { id = "ow2_conv_depth", label = "UI distance in conversations" },
    { id = "ow2_conv_size", label = "UI size in conversations" },

    { heading = "Weapon Reticule" },
    { id = "ret_enabled", label = "VR weapon reticule (off = the game's HUD crosshair)" },
    { id = "ret_brightness", label = "Reticule brightness" },

    { heading = "Interaction Pointer" },
    { id = "ip_enabled", label = "Left-hand interaction pointer" },
    { id = "ip_style", label = "Pointer style" },
    { id = "ip_reticle_size", label = "Pointer size" },
    { id = "ip_color", label = "Pointer colour" },
    { id = "ip_rot_pitch", label = "Pointer pitch (up / down)" },
    { id = "ip_rot_yaw", label = "Pointer yaw (left / right)" },
}

local sections = _G.OW2_SECTIONS or {}
table.sort(sections, function(a, b) return (a.order or 99) < (b.order or 99) end)

-- widget id -> item, and the ids MAIN takes out of the sections
local byId, wanted = {}, {}
for _, section in ipairs(sections) do
    for _, item in ipairs(section.layout or {}) do
        if item.id ~= nil then byId[item.id] = item end
    end
end
for _, entry in ipairs(MAIN) do
    if entry.id ~= nil then wanted[entry.id] = true end
end

local layout = {}
if #sections == 0 then
    table.insert(layout, { widgetType = "text", label = "No sections registered (scripts/*.lua load order?)" })
end

for _, entry in ipairs(MAIN) do
    if entry.heading ~= nil then
        table.insert(layout, { widgetType = "spacing" })
        table.insert(layout, { widgetType = "text_colored", label = entry.heading, color = HEADING_COLOR })
    elseif entry.indent then
        table.insert(layout, { widgetType = "indent", width = 20 })
    elseif entry.unindent then
        table.insert(layout, { widgetType = "unindent", width = 20 })
    else
        local item = byId[entry.id]
        if item ~= nil then -- a widget whose script did not load is left out
            if entry.label ~= nil then item.label = entry.label end
            table.insert(layout, item)
        end
    end
end
table.insert(layout, { widgetType = "spacing" })

-- everything else, per section, under Dev Config
if _G.OW2_DEV_CONFIG ~= false then
    local devLayout = {}
    for i, section in ipairs(sections) do
        local rest = {}
        for _, item in ipairs(section.layout or {}) do
            if item.id == nil or not wanted[item.id] then table.insert(rest, item) end
        end
        -- a section left with only spacing / unlabelled filler has nothing to show
        local useful = false
        for _, item in ipairs(rest) do
            if item.widgetType ~= "spacing" then useful = true break end
        end
        if useful then
            table.insert(devLayout, { widgetType = "tree_node", id = "ow2_dev_section_" .. i, label = section.label or ("Section " .. i), initialOpen = false })
            for _, item in ipairs(rest) do table.insert(devLayout, item) end
            table.insert(devLayout, { widgetType = "spacing" })
            table.insert(devLayout, { widgetType = "tree_pop" })
        end
    end
    if #devLayout > 0 then
        table.insert(layout, { widgetType = "tree_node", id = "ow2_dev_config", label = "Dev Config", initialOpen = false })
        for _, item in ipairs(devLayout) do table.insert(layout, item) end
        table.insert(layout, { widgetType = "tree_pop" })
    end
end

configui.create({
    {
        panelLabel = PANEL_LABEL,
        saveFile = SAVE_FILE,
        layout = layout,
    }
})

print("[ow2 panel] '" .. PANEL_LABEL .. "' built with " .. #sections .. " sections")
