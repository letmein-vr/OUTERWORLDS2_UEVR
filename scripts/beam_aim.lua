-- Beam weapons fire their beam effect down the barrel (2026-11-21).
--
-- The Kinetic Beam Caster's shot already goes along the barrel (OW2AimFix.dll: the last shot's end point and the fire
-- mode's target location both lie on the barrel line), but its beam EFFECT does not. The effect is a Niagara component
-- (NS_PlasmaBeam) attached to the FPV weapon mesh at socket VFX_Muzzle, and the weapon visuals Blueprint gives it its own
-- relative rotation that aims it from the muzzle at the game's crosshair - camera forward, i.e. where the head looks.
-- MCP 2026-11-21, gun held ~45 deg left of the view: barrel yaw 136.3, beam yaw -165.8, camera / control yaw -167.8,
-- beam relative rotation (P 1.0, Y 57.9, R -0.7). VFX_Muzzle itself points down the barrel (same rotation as
-- MuzzleFlashSocket and the fire mode's muzzle direction), so the beam lines up with the barrel at relative rotation 0.
--
-- Once per frame, after the world tick has run the visuals Blueprint (first post-stereo view), every Niagara component on
-- the held weapon's FPV mesh that hangs on a "muzzle" socket and whose system name says "beam" gets its relative
-- rotation put back to zero. The beam's other effects (NS_SpinbeamDomePlasma on VFX_Dome) are left alone.

local uevrUtils = require('libs/uevr_utils')

local niagaraClass = nil
local loggedFix = {}

local function lower(fname)
    local ok, s = pcall(function() return fname:to_string() end)
    return ok and s and s:lower() or ""
end

local function fixBeams()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return end
    local weapon = nil
    pcall(function() weapon = pawn:GetCurrentWeapon() end)
    if weapon == nil then return end
    local mesh = nil
    pcall(function() mesh = weapon.FPVWeaponMesh end)
    if mesh == nil then return end
    if niagaraClass == nil then niagaraClass = uevrUtils.get_class("Class /Script/Niagara.NiagaraComponent") end
    if niagaraClass == nil then return end
    local children = mesh.AttachChildren
    if children == nil then return end
    for i = 1, #children do
        local c = children[i]
        pcall(function()
            if c == nil or not c:is_a(niagaraClass) then return end
            if not lower(c.AttachSocketName):find("muzzle", 1, true) then return end
            local asset = c.Asset
            if asset == nil or not lower(asset:get_fname()):find("beam", 1, true) then return end
            local r = c.RelativeRotation
            if math.abs(r.Pitch) < 0.01 and math.abs(r.Yaw) < 0.01 and math.abs(r.Roll) < 0.01 then return end
            local name = asset:get_fname():to_string()
            if not loggedFix[name] then
                loggedFix[name] = true
                uevr.params.functions.log_info(string.format("[beam_aim] %s on %s: game aim (P %.1f, Y %.1f, R %.1f) -> barrel",
                    name, c.AttachSocketName:to_string(), r.Pitch, r.Yaw, r.Roll))
            end
            c:K2_SetRelativeRotation(uevrUtils.rotator(0, 0, 0), false, reusable_hit_result, true)
        end)
    end
end

local ranThisFrame = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisFrame = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ranThisFrame then return end
    ranThisFrame = true
    local ok, err = pcall(fixBeams)
    if not ok then print("[beam_aim] " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level) niagaraClass = nil end)

print("[beam_aim] loaded")
