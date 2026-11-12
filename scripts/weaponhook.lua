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
        -- and the depth pass (a hide path that was switched off - e.g. the gun caught by the arms hide while
        -- parented to FPVMesh - would otherwise leave it drawing without depth)
        if component.bRenderInDepthPass == false and component.SetRenderInDepthPass ~= nil then
            component:SetRenderInDepthPass(true)
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

-- Real arms mesh (Pawn.FPVMesh) visibility. Normally hidden (VR hands / IK rig replace it), but a montage
-- rule (Montage Config: "Pawn Arms Visibility" or "Pawn Body Visibility" = Visible - both point at
-- FPVMesh in this profile) can ask for it during that montage. Hiding uses the render-pass flags plus
-- HideBoneByName on the arm chain, never bVisible/bHiddenInGame (melee damage gate, see below).
local ARM_BONES = {
    "l_shoulder_JNT", "l_scapula_JNT", "l_upperArm_JNT", "l_lowerArm_JNT", "l_wrist_JNT",
    "r_shoulder_JNT", "r_scapula_JNT", "r_upperArm_JNT", "r_lowerArm_JNT", "r_wrist_JNT",
}
local function setArmBonesHidden(mesh, hidden)
    for _, bone in ipairs(ARM_BONES) do
        pcall(function()
            if hidden then
                mesh:HideBoneByName(uevrUtils.fname_from_string(bone), 0)
            else
                mesh:UnHideBoneByName(uevrUtils.fname_from_string(bone))
            end
        end)
    end
end
local function montageWantsArmsVisible()
    -- (value, priority) callbacks; false = "Visible" was requested by an active montage
    local arms = uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_pawn_arms_hidden")
    local body = uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_pawn_body_hidden")
    return arms == false or body == false
end
local armsShown = false
local skeletalMeshClass = nil -- resolved lazily (class lookups can fail while scripts load at game start)

-- Weapon mesh hiding for montages (Montage Config: "Weapon Visibility" = Hide). Render passes + shadow only,
-- never bVisible: an invisible mesh can stop updating its bones, and OW2AimFix reads the muzzle socket.
-- Original flags are remembered per component (address) and restored when the montage ends.
local weaponHiddenOriginals = {}   -- address -> { main, depth, shadow }
local weaponHidden = false
local function forEachInTree(component, fn)
    if component == nil then return end
    pcall(fn, component)
    pcall(function()
        local children = component.AttachChildren
        if children ~= nil then
            for i = 1, #children do forEachInTree(children[i], fn) end
        end
    end)
end
-- Owner actor address of a component, nil if unknown.
-- The game's weapon parts (the mesh and every mod mesh under it) are owned by the player character. Components the mod
-- attaches to the weapon (the PiP scope's ocular lens and scene capture, pip_scope.lua / libs/scope.lua) are owned by
-- their own spawned actors and manage their own visibility: forcing them visible every frame kept a PiP shown that
-- scope.lua had switched off by distance (2026-11-02, MCP: the mods' owner = IndianaPlayerCharacter, the scope parts' =
-- Actor_*). Only the game's parts are touched below.
local function ownerAddress(c)
    local ok, address = pcall(function()
        local owner = c:GetOwner()
        return owner ~= nil and owner:get_address() or nil
    end)
    return ok and address or nil
end

local function hideWeaponTree(mesh)
    local weaponOwner = ownerAddress(mesh)
    forEachInTree(mesh, function(c)
        if c.SetRenderInMainPass == nil then return end
        if c ~= mesh and ownerAddress(c) ~= weaponOwner then return end -- not a game part (see ownerAddress)
        local key = c:get_address()
        if weaponHiddenOriginals[key] == nil then
            weaponHiddenOriginals[key] = { main = c.bRenderInMainPass, depth = c.bRenderInDepthPass, shadow = c.CastShadow, visible = c.bVisible }
        end
        -- The weapon's static-mesh parts (body, blade, grip mods) are Nanite and ignore the render-pass flags
        -- (confirmed 2026-09-28: flags read false, blade still drawn; the Niagara glow obeyed them). Children
        -- are therefore hidden through bVisible as well. The skeletal root keeps the flag-only method so it
        -- never goes invisible (bone/socket updates for OW2AimFix).
        if c ~= mesh and c.bVisible == true and c.SetVisibility ~= nil then c:SetVisibility(false, false) end
        -- the foreground pass draws a component even with bRenderInMainPass=false (that is how the game
        -- draws its weapon mods), so it has to be off too
        if c.bForeground == true and c.SetForeground ~= nil then c:SetForeground(false) end
        if c.bRenderInMainPass == true then c:SetRenderInMainPass(false) end
        if c.bRenderInDepthPass == true then c:SetRenderInDepthPass(false) end
        if c.CastShadow == true and c.SetCastShadow ~= nil then c:SetCastShadow(false) end
    end)
end
local function restoreWeaponTree(mesh)
    local weaponOwner = ownerAddress(mesh)
    forEachInTree(mesh, function(c)
        if c.SetRenderInMainPass == nil then return end
        if c ~= mesh and ownerAddress(c) ~= weaponOwner then return end -- not a game part (see ownerAddress)
        local key = c:get_address()
        local o = weaponHiddenOriginals[key]
        if o == nil then return end
        if o.main == true and c.bRenderInMainPass == false then c:SetRenderInMainPass(true) end
        if o.depth == true and c.bRenderInDepthPass == false then c:SetRenderInDepthPass(true) end
        if o.shadow == true and c.SetCastShadow ~= nil then c:SetCastShadow(true) end
        if o.visible == true and c.bVisible == false and c.SetVisibility ~= nil then c:SetVisibility(true, false) end
        weaponHiddenOriginals[key] = nil
    end)
end
local function montageWantsWeaponHidden()
    return uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_weapon_hidden") == true
end

hands.onCreatedCallback(function(hand, component, componentName)
    clearForeground(component, true)
end)

local current_weapon_name = ""
local last_pawn = nil
local should_reattach = false
local next_attach_retry = 0 -- os.clock() time before which a failed weapon attach is not retried
-- Retry interval for a weapon whose mesh/asset is not ready yet or whose attach did not register. The asset usually
-- arrives a frame or two after GetCurrentWeapon() switches, so a long wait here is a visible "not in hand yet" gap
-- on every swap (0.5 s was noticeable). A retry is only a few property reads.
local ATTACH_RETRY_S = 0.05

-- UEVR_UObjectHook.get_motion_controller_state THROWS ("caught (...) exception") on the current backend build even for an
-- attached object (found on Hellraiser 2026-10-09: every attach looked failed and was redone every retry interval forever).
-- Right after our own attach, get_or_add returns the existing state (nothing is added), so it is the fallback here.
local function getAttachedHookState(mesh)
    local ok, st = pcall(function() return UEVR_UObjectHook.get_motion_controller_state(mesh) end)
    if ok then return st end
    local ok2, st2 = pcall(function() return UEVR_UObjectHook.get_or_add_motion_controller_state(mesh) end)
    return ok2 and st2 or nil
end

-- never probe the previous level's weapon meshes after a load (their memory may already be reclaimed)
uevrUtils.registerPreLevelChangeCallback(function(level)
    attached_weapon_mesh = nil
    attached_tpv_mesh = nil
    weaponHidden = false
    weaponHiddenOriginals = {}
end)
local weapon_was_reloading = false
local cached_weapon_mesh = nil
-- the mesh actually attached to the VR hand; unlike cached_weapon_mesh it survives GetCurrentWeapon()
-- going nil (interaction montages holster the weapon while the mesh stays on the hand)
local attached_weapon_mesh = nil
-- the third-person weapon mesh (on the body mesh's WeaponPoint socket); interaction montages can show it
local attached_tpv_mesh = nil

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
            setArmBonesHidden(mesh, true)
            armsShown = false
            -- The game keeps FPVMesh invisible (bVisible=false) but flips it visible for 1-3 ticks on every
            -- weapon swap (MCP watch, 2026-09-26), which showed the full arms for a frame.
            -- 2026-09-28: NEVER hide this mesh through bVisible or bHiddenInGame. The game's melee damage
            -- window (AnimNotifyState_MeleeDamage on the FPV montages) checks the arms mesh's visibility and
            -- silently skips the hit while either flag hides it (bisected: melee did no damage for as long as
            -- libs/pawn cleared bVisible, and again with SetHiddenInGame(true) here). Taking the mesh out of
            -- the main and depth render passes hides it just as well and leaves IsVisible() true.
            -- Children (the weapon mesh) are not affected by the render-pass flags.
            pcall(function() mesh:SetRenderInMainPass(false) end)
            pcall(function() mesh:SetRenderInDepthPass(false) end)
            print("Hid arm bones")
        end
    end

    local weapon_name = weapon:get_full_name()
    if current_weapon_name == weapon_name then return end
    if os.clock() < next_attach_retry then return end -- throttle attach retries (see the verify after attaching)

    -- Weapon changed
    current_weapon_name = weapon_name
    weapon_was_reloading = false
    cached_weapon_mesh = nil
    print("Weapon changed: " .. weapon_name)

    -- Hide TPV mesh
    if weapon.GetTPVMeshComponent then
        local tpv_mesh = weapon:GetTPVMeshComponent()
        if tpv_mesh then tpv_mesh:SetVisibility(false, true) end
        attached_tpv_mesh = tpv_mesh -- re-hidden during "Weapon Visibility = Hide" montages (post-tick)
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

    -- mesh component exists but its asset is not assigned yet (first frames after a level load): the attachment
    -- ID would be derived from the component's numbered name (no saved offsets, junk panel entry) - wait for it
    if attach_mesh ~= nil then
        local hasAsset = false
        pcall(function() hasAsset = (attach_mesh.SkinnedAsset or attach_mesh.SkeletalMesh) ~= nil end)
        if not hasAsset then
            print("[weaponhook] weapon mesh has no asset yet; retrying")
            current_weapon_name = ""
            next_attach_retry = os.clock() + ATTACH_RETRY_S
            return
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
        attached_weapon_mesh = attach_mesh
        print("[weaponhook] attachToRawController called")
        -- Verify it took. After a level load the attach used to be skipped silently (fresh mesh not yet adopted
        -- by UObjectHook) and, with the weapon already marked as handled, never retried: gun left on the game's
        -- hidden arms. No motion-controller state -> forget the weapon so the whole block runs again in 0.5 s.
        if getAttachedHookState(attach_mesh) == nil then
            current_weapon_name = ""
            next_attach_retry = os.clock() + ATTACH_RETRY_S
            print("[weaponhook] attach did not take; retrying")
        end
    else
        print("[weaponhook] No mesh found for weapon: " .. weapon_name)
        -- visuals not spawned yet (e.g. first ticks after a load): retry instead of giving up on this weapon
        current_weapon_name = ""
        next_attach_retry = os.clock() + ATTACH_RETRY_S
    end

    -- Fix weapon FOV
    if pawn.WeaponFOV then
        pawn:WeaponFOV(90.0, false)
    end
end)

-- -------------------------------------------------------------------------
-- ATTACHMENTS INIT
-- -------------------------------------------------------------------------
-- Attachments stays in developer mode - the mode this profile was built and confirmed in (attachments.init(false)
-- left hands / IK arms not appearing, 2026-10-12). Its "Attachments Config Dev" panel is hidden for the release layout;
-- comment the line out to show it again for tuning (per-weapon offsets, the left-hand gadget prop in left_gadget.lua).
-- attachments.setDeveloperPanelHidden(true)
attachments.init(true, nil, {0,0,0}, {0,-90,0})

-- -------------------------------------------------------------------------
-- POST-TICK: visibility override
-- -------------------------------------------------------------------------
local visfix_frame = 0
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta_time)
    visfix_frame = visfix_frame + 1

    local pawn = api:get_local_pawn()
    if pawn == nil then return end

    -- Montage "Weapon Visibility = Hide": applied to the mesh on the hand BEFORE the weapon checks below,
    -- because interaction montages clear GetCurrentWeapon() while the mesh is still attached.
    local hideWeapon = montageWantsWeaponHidden()
    local held = attached_weapon_mesh
    if held ~= nil then
        local ok, alive = pcall(function() return held:get_full_name() ~= nil end)
        if not (ok and alive) then held = nil attached_weapon_mesh = nil end
    end
    if held ~= nil then
        if hideWeapon then
            hideWeaponTree(held)
        elseif weaponHidden then
            restoreWeaponTree(held)
            clearForeground(held, true)
        end
    end
    local tpv = attached_tpv_mesh
    if tpv ~= nil then
        local ok, alive = pcall(function() return tpv:get_full_name() ~= nil end)
        if not (ok and alive) then tpv = nil attached_tpv_mesh = nil end
    end
    if tpv ~= nil then
        if hideWeapon then
            hideWeaponTree(tpv)
        elseif weaponHidden then
            restoreWeaponTree(tpv) -- render flags only; its bVisible stays whatever the game set
        end
    end
    weaponHidden = hideWeapon and (held ~= nil or tpv ~= nil)

    if pawn.GetCurrentWeapon == nil then return end
    local weapon = pawn:GetCurrentWeapon()
    if weapon == nil then return end

    -- The SAME mesh the attachments system holds: weapon.FPVCurrentVisuals.WeaponMesh (the pre-tick attaches that
    -- one). GetFPVMeshComponent() is a different lookup that does not always return the attached component, so the
    -- per-tick visibility / foreground / montage-hide work landed on the wrong mesh and the one on the hand stayed
    -- hidden by the game after a weapon swap (2026-09-29). GetFPVMeshComponent() is only a fallback.
    local mesh = nil
    pcall(function() mesh = weapon.FPVCurrentVisuals.WeaponMesh end)
    if mesh == nil and weapon.GetFPVMeshComponent ~= nil then mesh = weapon:GetFPVMeshComponent() end
    if mesh == nil then return end

    if mesh.SetVisibility then
        if mesh.bVisible == false then mesh:SetVisibility(true, false) end -- root
        if not hideWeapon then
            -- the game's own parts under it (mods); a part the game left hidden after a swap is shown again. Not the
            -- mod's own components (PiP lens / scene capture): they keep the visibility they set (see ownerAddress).
            -- Was SetVisibility(true, true), which propagated to those too.
            local weaponOwner = nil
            forEachInTree(mesh, function(c)
                if c ~= mesh and c.bVisible == false and c.SetVisibility ~= nil then
                    weaponOwner = weaponOwner or ownerAddress(mesh)
                    if ownerAddress(c) == weaponOwner then c:SetVisibility(true, false) end
                end
            end)
        end
    end
    mesh.bHiddenInGame = false

    -- keep the weapon mesh (and its attached mod meshes) out of the foreground pass,
    -- unless an active montage hides the weapon (clearForeground would put it back in the main pass)
    if hideWeapon then
        hideWeaponTree(mesh) -- no-op if it is the held mesh already handled above
    else
        if next(weaponHiddenOriginals) ~= nil then restoreWeaponTree(mesh) end
        clearForeground(mesh, true)
    end
end)

-- Arms (+ prosthetic) render passes and the VR hands' foreground flag. Separate post-tick callback so it runs
-- with NO weapon equipped too (the weapon callback above returns early when GetCurrentWeapon() is nil, which
-- left a prosthetic limb permanently drawn and the "Pawn Arms Visible" montage rule weapon-only).
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta_time)
    local pawn = api:get_local_pawn()
    if pawn == nil then return end

    -- keep the real arms mesh out of the render passes (see the pawn-change block above: bVisible /
    -- bHiddenInGame must stay untouched or melee stops doing damage) unless an active montage rule asks
    -- to show it; cheap flag reads per tick. When shown it also leaves the foreground pass (breaks AFW).
    local arms = nil
    pcall(function() arms = pawn.FPVMesh end)
    if arms ~= nil then
        local show = montageWantsArmsVisible()
        if show ~= armsShown then
            setArmBonesHidden(arms, not show)
            armsShown = show
        end
        -- same treatment for skeletal-mesh children of the arms (prosthetic limbs: a separate component that
        -- follows FPVMesh via leader pose and is drawn in the foreground pass)
        local function applyArmsPass(c)
            if show then
                if c.bForeground == true then pcall(function() c:SetForeground(false) end) end
                if c.bRenderInMainPass == false then pcall(function() c:SetRenderInMainPass(true) end) end
                if c.bRenderInDepthPass == false then pcall(function() c:SetRenderInDepthPass(true) end) end
            else
                if c.bRenderInMainPass == true then pcall(function() c:SetRenderInMainPass(false) end) end
                if c.bRenderInDepthPass == true then pcall(function() c:SetRenderInDepthPass(false) end) end
                if c ~= arms and c.bForeground == true then pcall(function() c:SetForeground(false) end) end -- foreground ignores bRenderInMainPass
            end
        end
        applyArmsPass(arms)
        if skeletalMeshClass == nil then
            skeletalMeshClass = uevrUtils.get_class("Class /Script/Engine.SkeletalMeshComponent")
        end
        local children = nil
        pcall(function() children = arms.AttachChildren end)
        for i = 1, (children and #children or 0) do
            -- per child: reading a missing property (e.g. SkinnedAsset on the FPVCameraComponent, the first
            -- child) throws, and a single pcall around the loop silently skipped the prosthetic behind it
            pcall(function()
                local c = children[i]
                -- prosthetics only (asset folder /Prosthetics/): some weapons (the pistol) parent their FPV
                -- weapon mesh to FPVMesh as well, and a plain skeletal-child test hid the gun with the arms
                if c ~= nil and c:is_a(skeletalMeshClass)
                    and string.find(c.SkinnedAsset:get_full_name(), "/Prosthetics/", 1, true) ~= nil then
                    applyArmsPass(c)
                end
            end)
        end
        if arms.bHiddenInGame == true then pcall(function() arms:SetHiddenInGame(false, false) end) end
    end

    -- keep the VR hands out of the foreground pass
    clearForeground(hands.getHandComponent(Handed.Left), true)
    clearForeground(hands.getHandComponent(Handed.Right), true)
end)
