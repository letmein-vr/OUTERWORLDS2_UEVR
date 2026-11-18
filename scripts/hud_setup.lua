-- HUD tool (libs/hud.lua): hides game HUD pieces or shows them as world widgets on the controllers, HMD,
-- hand bones or pawn sockets. Guide: 0. HUD Tool\HUD_TOOL_GUIDE.md. Same set-up as Cronos / Hellraiser (2026-11-16).
--   "HUD Dev" tab: build elements (pick a game widget / part, mode, target, placement); its Save button writes
--                  data/hud_parameters.json, which ships with the mod. Hidden unless DEVELOPER_MODE is true.
--   "HUD" tab:     players' on/off, size and opacity per element (data/hud_player_config.json).
-- "Immersive HUD" in the Outer Worlds 2 VR panel switches every element on (the saved attachments) or off (the game's
-- own flat HUD, untouched).
-- OW2 notes (HUD tool port 2026-10-15/16):
--   * the whole HUD is ONE top-level widget, /Game/UI/HUD/HUD_BP.HUD_BP_C (HudContents: PlayerStatsDisplay,
--     AmmoReadout, MinimapWidget, QuestLog, InteractionPrompt, ...), so pieces are Region elements on it plus a
--     regionRest element for the rest of the HUD.
--   * the game's UI manager (IndianaUI) tracks HUD_BP_C natively: removing it from the viewport crashed the game. The lib
--     shares widgets instead (confirmed on OW2 2026-10-16), so this is safe.
--   * auto-exposure is not pinned here (unbound global post-process volume), so the "postprocess" exposure source has
--     nothing to read: exposure stays "none".

local configui = require("libs/configui")
local hud = require("libs/hud")

local DEVELOPER_MODE = false -- true shows the HUD Dev tab for building / editing elements; false for release
local PLAYER_TAB = "HUD"    -- "HUD" shows the per-element player tab; false hides it (elements use their saved defaults)

hud.setup({
    developerMode = DEVELOPER_MODE,
    playerTab = PLAYER_TAB,
    logFile = "hud_log.txt",
    logLevel = LogLevel.Warning,
})

_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 2.9, label = "Immersive HUD", layout = {
    { widgetType = "checkbox", id = "ow2_immersive_hud", label = "Immersive HUD (health, map and companions on the left hand, ammo on the gun, rest of the HUD in view)", initialValue = true },
}})

-- configui.getValue is nil until the panel exists (zz_ow2_vr_panel.lua), so nil = the initial value (on)
configui.onCreateOrUpdate("ow2_immersive_hud", function(value)
    hud.setEnabled(value ~= false)
end)
