local api = uevr.api
local vr = uevr.params.vr
local uevrUtils = require('libs/uevr_utils')

-- Monkey patch getShortName to fix JBusfield to_string() bug AND getValid() strictness
uevrUtils.getShortName = function(object)
    if object == nil then return "" end
    if type(object) == "userdata" and object.get_fname ~= nil then
        local ok, name = pcall(function() return tostring(object:get_fname()) end)
        if ok and name ~= nil then 
            -- Make the UI cleaner by renaming the Inventory component
            if name == "Inventory" then return "Wpn" end
            return name 
        end
    end
    return ""
end

local attachments = require('libs/attachments')
local hands = require('libs/hands')

-- The Outer Worlds 2 renders its first-person meshes (FPVMesh arms, FPV weapon mesh) through a
-- dedicated "foreground" pass (PrimitiveComponent.bForeground, SetForeground()). That pass breaks
-- the AFW render method in UEVR, so BOTH the VR hand copies and the attached weapon mesh (plus its
-- child mod meshes) must be kept OUT of it: bForeground = false, at all times. The game re-flags its
-- weapon mesh on equip/visual changes, so this is enforced from the post-tick loop below, not only
-- at creation. Only the setter is called when the flag is actually true, so the steady-state cost
-- is a handful of property reads per frame.
local function clearForeground(component, includeChildren)
    if component == nil or component.SetForeground == nil then return end
    pcall(function()
        if component.bForeground == true then
            component:SetForeground(false)
        end
        -- The game draws the weapon mods (magazine etc.) only in its foreground pass, so once that is
        -- cleared they must be put into the main pass, or only their depth-pass silhouette remains
        -- (solid black block, seen on the pistol magazine 2026-09-26).
        if component.bRenderInMainPass == false and component.SetRenderInMainPass ~= nil then
            component:SetRenderInMainPass(true)
        end
        if includeChildren then
            local children = component.AttachChildren
            if children ~= nil then
                for i = 1, #children do
                    clearForeground(children[i], true)
                end
            end
        end
    end)
end

hands.onCreatedCallback(function(hand, component, componentName)
    clearForeground(component, true)
end)

local current_weapon_name = ""
local last_pawn = nil
local should_reattach = false
local weapon_was_reloading = false
local cached_weapon_mesh = nil

-- -------------------------------------------------------------------------
-- PRE-TICK: weapon detection, reload fix, bone hiding
-- -------------------------------------------------------------------------
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta_time)
    local pawn = api:get_local_pawn()
    if pawn == nil then return end

    if pawn.GetCurrentWeapon == nil then return end
    local weapon = pawn:GetCurrentWeapon()
    if weapon == nil then
        -- No weapon — unregister
        if current_weapon_name ~= "" then
            current_weapon_name = ""
            cached_weapon_mesh = nil
        end
        return
    end

    -- -------------------------------------------------------------------------
    -- RELOAD FIX
    -- -------------------------------------------------------------------------
    if weapon.IsReloading then
        local is_reloading = weapon:IsReloading()
        if weapon_was_reloading and not is_reloading then
            if weapon.GetAmmoPool then
                local pool = weapon:GetAmmoPool()
                if pool and pool.GetMissingAmmo then
                    local missing = pool:GetMissingAmmo()
                    if missing and missing > 0 then
                        print("[reloadfix] Reload ended with " .. tostring(missing) .. " ammo missing — calling RefillAmmo")
                        if pool.RefillAmmo then
                            local ok = pool:RefillAmmo(missing, true)
                            print("[reloadfix] RefillAmmo result: " .. tostring(ok))
                        end
                    end
                end
            end
        end
        weapon_was_reloading = is_reloading
    end

    -- Re-hide bones if pawn changed (level reload, death, etc.)
    if pawn ~= last_pawn and pawn.FPVMesh then
        should_reattach = true
        last_pawn = pawn
        weapon_was_reloading = false
        local mesh = pawn.FPVMesh
        if mesh ~= nil then
            mesh:HideBoneByName(uevrUtils.fname_from_string("l_shoulder_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("l_scapula_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("l_upperArm_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("l_lowerArm_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("l_wrist_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("r_shoulder_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("r_scapula_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("r_upperArm_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("r_lowerArm_JNT"), 0)
            mesh:HideBoneByName(uevrUtils.fname_from_string("r_wrist_JNT"), 0)
            -- The game keeps FPVMesh invisible (bVisible=false) but flips it visible for 1-3 ticks on every
            -- weapon swap (MCP watch, 2026-09-26), which showed the full arms for a frame. bHiddenInGame is
            -- not touched by that swap code, so it is the flag that reliably keeps the arms off screen.
            -- Children (the weapon mesh) are not propagated to and keep rendering.
            mesh:SetHiddenInGame(true, false)
            print("Hid arm bones")
        end
    end

    local weapon_name = weapon:get_full_name()
    if current_weapon_name == weapon_name then return end

    -- Weapon changed
    current_weapon_name = weapon_name
    weapon_was_reloading = false
    cached_weapon_mesh = nil
    print("Weapon changed: " .. weapon_name)

    -- Hide TPV mesh
    if weapon.GetTPVMeshComponent then
        local tpv_mesh = weapon:GetTPVMeshComponent()
        if tpv_mesh then tpv_mesh:SetVisibility(false, true) end
    end

    -- DETECT MELEE STATUS
    local is_melee = false
    local melee_tag = ""
    local ok_cat, category = pcall(function() return weapon.WeaponCategory end)
    if ok_cat and category ~= nil then
        local ok_tag, tag = pcall(function() return category.TagName end)
        if ok_tag and tag ~= nil then
            local ok_str, tag_str = pcall(function() return tostring(tag) end)
            if ok_str and tag_str ~= nil then
                melee_tag = tag_str
                if string.find(tag_str, "Melee") then
                    is_melee = true
                end
            end
        end
    end

    local short_name = "Unknown"
    local ok_short, s = pcall(function() return uevrUtils.getShortName(weapon) end)
    if ok_short and s ~= "" then
        short_name = s
    end

    print("[weaponhook] " .. tostring(short_name) .. " melee tag: " .. (melee_tag ~= "" and melee_tag or "none") .. " (is melee: " .. tostring(is_melee) .. ")")

    -- Find FPV weapon mesh
    local attach_mesh = nil

    -- Primary: FPVCurrentVisuals.WeaponMesh (confirmed working path)
    local ok, fpv = pcall(function() return weapon.FPVCurrentVisuals end)
    if ok and fpv then
        local ok2, wm = pcall(function() return fpv.WeaponMesh end)
        if ok2 and wm then
            attach_mesh = wm
            print("[weaponhook] FPVCurrentVisuals.WeaponMesh: " .. wm:get_full_name())
        end
    end

    -- Fallback: GetFPVMeshComponent
    if attach_mesh == nil and weapon.GetFPVMeshComponent then
        local mesh = weapon:GetFPVMeshComponent()
        if mesh then
            attach_mesh = mesh
            print("[weaponhook] GetFPVMeshComponent: " .. mesh:get_full_name())
        end
    end

    cached_weapon_mesh = attach_mesh

    -- ATTACH to right controller
    if attach_mesh then
        local options = {
            detachFromOriginOnGrip = true,
            maintainWorldPositionOnDetachFromOrigin = false,
            detachFromParentOnRelease = true,
            maintainWorldPositionOnDetachFromParent = false,
            reattachToOriginOnRelease = false,
            -- permanent: keep the UObjectHook-applied hand transform on the game thread.
            -- Non-permanent states get restored to their original (identity) transform right
            -- after each stereo pass, so the game (and any aim plugin) would see the gun at
            -- the world origin when computing shots.
            restoreTransformToOriginOnReattach = true,
            allowChildVisibilityHandling = true,
            allowChildHiddenInGameHandling = true,
            allowRenderInMainPassHandling = true,
            melee = is_melee
        }
        attachments.attachToRawController(attach_mesh, Handed.Right, options)
        print("[weaponhook] attachToRawController called")
    else
        print("[weaponhook] No mesh found for weapon: " .. weapon_name)
    end

    -- Fix weapon FOV
    if pawn.WeaponFOV then
        pawn:WeaponFOV(90.0, false)
    end
end)

-- -------------------------------------------------------------------------
-- ATTACHMENTS INIT
-- -------------------------------------------------------------------------
-- Release layout: global developer mode is OFF (uevrmenus.lua), which hides every library dev panel.
-- The attachments panel ("Attachments Config Dev") is the one users still need for per-weapon offsets,
-- so it is initialised with the developer flag passed explicitly. The old "Dev Tools" panel (weapon
-- name / melee tag readout) is gone; the same information goes to the log on weapon change.
attachments.init(true, nil, {0,0,0}, {0,-90,0})

-- -------------------------------------------------------------------------
-- POST-TICK: visibility override
-- -------------------------------------------------------------------------
local visfix_frame = 0
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta_time)
    visfix_frame = visfix_frame + 1

    local pawn = api:get_local_pawn()
    if pawn == nil then return end

    if pawn.GetCurrentWeapon == nil then return end
    local weapon = pawn:GetCurrentWeapon()
    if weapon == nil then return end

    if weapon.GetFPVMeshComponent == nil then return end
    local mesh = weapon:GetFPVMeshComponent()
    if mesh == nil then return end

    if mesh.SetVisibility then
        mesh:SetVisibility(true, true)
    end
    mesh.bHiddenInGame = false

    -- keep the real arms mesh hidden-in-game (see the pawn-change block above); cheap flag read per tick
    local arms = pawn.FPVMesh
    if arms ~= nil and arms.bHiddenInGame == false then
        pcall(function() arms:SetHiddenInGame(true, false) end)
    end

    -- keep the weapon mesh (and its attached mod meshes) and the VR hands out of the foreground pass
    clearForeground(mesh, true)
    clearForeground(hands.getHandComponent(Handed.Left), true)
    clearForeground(hands.getHandComponent(Handed.Right), true)
end)
