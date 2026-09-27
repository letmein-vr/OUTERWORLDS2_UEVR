local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require("libs/configui")
local reticule = require("libs/reticule")
local hands = require('libs/hands')
local attachments = require('libs/attachments')
local accessories = require('libs/accessories')
local input = require('libs/input')
local pawnModule = require('libs/pawn')
local animation = require('libs/animation')
local montage = require('libs/montage')
local interaction = require('libs/interaction')
local ui = require('libs/ui')
local remap = require('libs/remap')
local gestures = require('libs/gestures')

-- Release layout: developer mode OFF. This hides the library dev panels (Input/UI/Pawn/Reticule/Remap/
-- Montage/Interaction Dev Config and the IK dev panel); the remaining overlay panels are TheOuterWorlds2,
-- Hands Mode, Two-Handed, Physical Melee, Camera Stabilize and Attachments Config Dev (weaponhook.lua
-- initialises attachments with the developer flag explicitly). Set this to true again for tuning
-- sessions - it brings the dev panels back without other changes.
uevrUtils.setDeveloperMode(false)

-- VR hands wizard ("Hand Config" panel). Disabled for release: the saved data/hands_parameters.json is
-- what scripts/hands.lua builds from. Re-enable only to re-capture hand poses (and see
-- uevr-hands-wizard-leak-bug / the wizard-regenerates-hands.lua trap before doing so).
-- hands.enableConfigurationTool()

-- Full-arm IK rig (libs/ik), used when the "Hands Mode" panel (scripts/hands.lua) is set to "IK arms".
-- The library is always loaded (its dev panel only appears when developer mode is on); whether a rig
-- is auto-created follows the mode. scripts/hands.lua drives this through _G.setIKEnabled / _G.ikRebuild (it loads first, so the
-- mode getter already exists here). The mesh-created callback keeps the rig meshes OUT of the game's
-- foreground pass (see weaponhook.lua for why).
local ik = require('libs/ik')
ik.registerOnMeshCreatedCallback(function(meshList, rig)
    for _, mesh in ipairs(meshList or {}) do
        if mesh ~= nil and mesh.SetForeground ~= nil then
            pcall(function() mesh:SetForeground(false) end)
        end
    end
    -- same as the glove path: a fresh rig starts in the open pose until an input edge; re-assert the
    -- current weapon grip/trigger state (scripts/hands.lua owns the helper)
    if _G.refreshWeaponPoses ~= nil then pcall(_G.refreshWeaponPoses) end
end)
ik.init(false, LogLevel.Warning) -- no IK dev panel in the release layout; Warning keeps solver failures in log.txt without per-tick debug noise

local function ikWanted()
    return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end
_G.setIKEnabled = function(enabled)
    ik.setAutoCreateArms(enabled == true) -- the 1 s auto-create builds the rig from ik_parameters.json + hands_parameters.json
    if not enabled and ik.exists() then ik.destroyAll() end
end
_G.ikRebuild = function()
    -- suit / armor change: drop the rig, auto-create rebuilds it (with the new arms mesh) within a second
    if ik.exists() then ik.destroyAll() end
end
ik.setAutoCreateArms(ikWanted())

ui.init()
montage.init()
interaction.init()
reticule.init()
pawnModule.init()
remap.init()
input.init()
accessories.init()
