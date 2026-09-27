-- Builds the single user-facing "Outer Worlds 2 VR" panel in the UEVR overlay.
--
-- Every game script registers its settings as a section in _G.OW2_SECTIONS ({ order, label, layout })
-- instead of creating its own panel; this file loads LAST (UEVR loads scripts in name order, case-
-- insensitive, hence the zz_ prefix) and turns the sections into one panel with a collapsible tree node
-- per section. Widget ids are global in configui, so the owning scripts keep using configui.getValue /
-- onUpdate / setLabel exactly as before. All values are saved together in data/ow2_vr_config.json.
--
-- First run: the previous per-script save files (hands_mode_config, two_handed_config,
-- physical_melee_config, camera_stabilize_config) and the values TheOuterWorlds2.lua migrated from
-- TheOuterWorlds2.txt (_G.OW2_MIGRATION) are merged into the new file so nothing tuned is lost.

local configui = require('libs/configui')

local PANEL_LABEL = "Outer Worlds 2 VR"
local SAVE_FILE   = "ow2_vr_config"

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

local sections = _G.OW2_SECTIONS or {}
table.sort(sections, function(a, b) return (a.order or 99) < (b.order or 99) end)

local layout = {}
if #sections == 0 then
    table.insert(layout, { widgetType = "text", label = "No sections registered (scripts/*.lua load order?)" })
end
for i, section in ipairs(sections) do
    table.insert(layout, { widgetType = "tree_node", id = "ow2_section_" .. i, label = section.label or ("Section " .. i), initialOpen = (i == 1) })
    for _, item in ipairs(section.layout or {}) do
        table.insert(layout, item)
    end
    table.insert(layout, { widgetType = "spacing" })
    table.insert(layout, { widgetType = "tree_pop" })
end

configui.create({
    {
        panelLabel = PANEL_LABEL,
        saveFile = SAVE_FILE,
        layout = layout,
    }
})

print("[ow2 panel] '" .. PANEL_LABEL .. "' built with " .. #sections .. " sections")
