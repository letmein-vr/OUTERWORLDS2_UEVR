-- Manual reload, step 1: automatic per-weapon reload analysis (2026-11-19).
--
-- Learns everything manual reload needs from the game's own reload animation instead of hand tuning. Each gun's
-- first native TACTICAL reload and first native EMPTY reload are recorded frame by frame (the magazine's motion only
-- exists in a live reload - playing the montages by themselves does not move it, MCP 2026-11-19); the profile is
-- computed when the reload ends and saved to data/manual_reload_auto.json, keyed by weapon mesh + magazine part
-- (mods that change the magazine get their own profile). Ship that file and players never see a native reload.
--
-- Per gun it finds (all in the weapon mesh's component space = the FPVMesh weapon socket frame):
--   * the carried item: the weapon bone a hand carries at a constant offset while both move relative to the gun
--     (steady-grip window), its bone subtree, and the visual part on it (leader-posed skeletal mod mesh, or a static
--     mod mesh on a socket of an item bone); or a prop the game attaches to the arms' l_hand_Prop_Socket;
--   * which hand carries it (right-hand guns get mirrored onto the left hand by manual reload) + the grip
--     (hand in item frame) + that hand's finger pose (fingers in hand frame);
--   * the seat pose (item rest), the approach pose (the last stretch of the game's insert path) and its depth;
--   * when ammo lands (one burst = magazine-style, a +1 per insert = round by round, a fast stream = pour);
--   * the rack part (empty reload): a bone that slides out from rest and returns (slide / lever / bolt), its axis,
--     travel, whether it is locked back while empty, a lift rotation (bolt handle) and the hand pose on it;
--   * mechanisms: every other part that opens and closes (cylinder hinge, break barrel, gates, locks, clamps).
-- Guns with both a prop reload and a magazine reload (Plasma SMG: cell pour when partial, mag swap when empty) use
-- the magazine (2026-11-19: "mag swap always").
--
-- API for manual reload: _G.ow2ReloadAnalyzer = { getProfile(weapon), keyFor(weapon), isRecording(), relearn() }.
-- Panel: section "Manual Reload" (Dev Config): status line + "Re-learn this gun" + detail logging.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')

local PROFILE_FILE = "manual_reload_auto.json"
local RTS_COMPONENT = 2
local END_TAIL = 0.35          -- s without reload state before a recording ends
local REST_REFRESH = 0.5       -- s between idle rest-pose snapshots
local FINGER_EVERY = 0.08      -- s between finger snapshots while recording
local MAX_FRAMES = 900
-- dev: write every recording's raw frames to data/reload_frames_<tactical|empty>.json (OFF for release)
local DUMP_FRAMES = false
-- cm: a carried item leaves the gun (probe 2026-11-19: speedloader 29, mags 35-167, rounds/rockets 60+), while
-- rack parts the hand rides stay on it (slide 7.7, bolt 8.6, AR lever 10.1) - 5 cm picked the pistol slide
local ITEM_MIN_TRAVEL = 15.0
local RACK_MIN_TRAVEL = 2.0    -- cm
local RACK_MIN_DEG = 20.0      -- rotary rack (charging handle swinging about a pivot)
local PROP_MAX_GRIP = 15.0     -- cm: a prop farther from the hand than this is parked, not held
local CRANK_MIN_DEG = 200.0    -- crank: a part wound past half a turn in one go (Anti-Matter Plasma Rifle 446 deg)
local MECH_MIN_DEG = 15.0
local MECH_MIN_CM = 1.0
local SEATED_CM = 0.3
local APPROACH_MAX_CM = 12.0
local POUR_GAP = 0.12          -- s: ammo steps closer than this are a pour, not separate inserts

_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 2.81, label = "Manual Reload - Analysis", layout = {
    { widgetType = "text", id = "mr_auto_status", label = "Reload analysis: -" },
    { widgetType = "button", id = "mr_auto_relearn", label = "Re-learn this gun (next native reloads)", size = {280, 24} },
    { widgetType = "checkbox", id = "mr_auto_log", label = "Detailed analysis log (log.txt)", initialValue = false },
}})

local function info(s)
    pcall(function() uevr.params.functions.log_info("[reload_analyzer] " .. s) end)
end
local function detail(s)
    if configui.getValue("mr_auto_log") == true then info(s) end
end

-- -------------------------------------------------------------------------------------------------------------------
-- math (tables {X,Y,Z} / {X,Y,Z,W}; UE quaternion convention)
-- -------------------------------------------------------------------------------------------------------------------
local function qmul(a, b)
    return {
        X = a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y,
        Y = a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X,
        Z = a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W,
        W = a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z,
    }
end
local function qconj(q) return { X = -q.X, Y = -q.Y, Z = -q.Z, W = q.W } end
local function qrot(q, v)
    local p = qmul(qmul(q, { X = v.X, Y = v.Y, Z = v.Z, W = 0 }), qconj(q))
    return { X = p.X, Y = p.Y, Z = p.Z }
end
local function qangle(a, b)
    local d = math.abs(a.X * b.X + a.Y * b.Y + a.Z * b.Z + a.W * b.W)
    if d > 1 then d = 1 end
    return math.deg(2 * math.acos(d))
end
local function vsub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function vlen(v) return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
local function dist(a, b) return vlen(vsub(a, b)) end
local function vnorm(v)
    local l = vlen(v)
    if l < 1e-6 then return { X = 0, Y = 0, Z = 0 } end
    return { X = v.X / l, Y = v.Y / l, Z = v.Z / l }
end
-- b expressed in a's frame (both {loc, q} in the same space)
local function relT(a, b)
    local inv = qconj(a.q)
    return { loc = qrot(inv, vsub(b.loc, a.loc)), q = qmul(inv, b.q) }
end
local function copyT(t)
    return {
        loc = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
        q = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W },
    }
end
local function r3(n) return math.floor(n * 1000 + 0.5) / 1000 end
local function packT(t)
    if t == nil then return nil end
    return { loc = { X = r3(t.loc.X), Y = r3(t.loc.Y), Z = r3(t.loc.Z) },
             q = { X = r3(t.q.X), Y = r3(t.q.Y), Z = r3(t.q.Z), W = r3(t.q.W) } }
end
local function fmtV(v) return string.format("(%.2f,%.2f,%.2f)", v.X, v.Y, v.Z) end

-- -------------------------------------------------------------------------------------------------------------------
-- profiles
-- -------------------------------------------------------------------------------------------------------------------
local profiles = {}

-- the profile's mechanisms come from the main record (the tactical one for a magazine gun), but a rack is learned from the
-- empty record only: parts the rack owns were openers in the tactical record (2026-11-20, Anti-Matter Plasma Rifle: the
-- crank, wing nut, gears and rotator became openers, so every reload waited at "flick the gun to close it"). Drop them.
local function rackMechanisms(mechs, rack)
    if type(mechs) ~= "table" or type(rack) ~= "table" then return mechs end
    local own = {}
    if rack.bone then own[rack.bone] = true end
    if type(rack.lift) == "table" and rack.lift.bone then own[rack.lift.bone] = true end
    for _, n in ipairs(rack.linked or {}) do own[n] = true end
    local out = {}
    for _, m in ipairs(mechs) do if not own[m.bone] then out[#out + 1] = m end end
    return out
end

pcall(function()
    local p = json.load_file(PROFILE_FILE)
    if type(p) == "table" then profiles = p end
end)
for _, p in pairs(profiles) do
    if type(p) == "table" then p.mechanisms = rackMechanisms(p.mechanisms, p.rack) end
end
local function saveProfiles()
    pcall(function() json.dump_file(PROFILE_FILE, profiles, 1) end)
end

local function shortName(obj)
    if obj == nil then return "-" end
    local ok, s = pcall(function() return obj:get_fname():to_string() end)
    return ok and s or "-"
end
local function fullName(obj)
    if obj == nil then return "-" end
    local ok, s = pcall(function() return obj:get_full_name() end)
    return ok and s or "-"
end
local function meshAsset(comp)
    local a = nil
    pcall(function() a = comp.SkeletalMesh end)
    if a == nil then pcall(function() a = comp.SkinnedAsset end) end
    if a == nil then pcall(function() a = comp.StaticMesh end) end
    return a
end
local function className(obj)
    local ok, s = pcall(function() return obj:get_class():get_fname():to_string() end)
    return ok and s or "?"
end
local function children(comp)
    local out = {}
    pcall(function()
        local c = comp.AttachChildren
        for i = 1, #c do if c[i] ~= nil then out[#out + 1] = c[i] end end
    end)
    return out
end

local MAG_WORDS = { "mag", "clip", "cell", "battery", "breech", "cylinder", "speedloader", "canister", "bag", "drum" }
-- a leader-posed skeletal mod part only stands for the carried item when its name says magazine: "breech" (rocket
-- pistol: MOD_P_Breech_Base is the whole breech block), "cylinder" and "bag" parts carry more than the item.
-- Items without such a part are copied bone-level from all of the gun's skeletal meshes (manual_reload.lua).
local PART_WORDS = { "mag", "clip", "cell", "battery", "drum", "canister", "speedloader" }
local function partIsItem(s)
    s = (s or ""):lower()
    for _, w in ipairs(PART_WORDS) do if s:find(w, 1, true) then return true end end
    return false
end

local function magLike(s)
    s = (s or ""):lower()
    for _, w in ipairs(MAG_WORDS) do if s:find(w, 1, true) then return true end end
    return false
end

-- the mod part that holds the magazine (it decides the profile key): a leader-posed skeletal mod mesh with a
-- magazine-like asset name, else a static mesh on a magazine-like socket.
-- Game parts only: engine assets (/Engine/...) and socketless static meshes are our own add-ons - the PiP scope's
-- lens is /Engine/BasicShapes/Cylinder attached without a socket, "cylinder" is magazine-like (revolvers), and the
-- Volted Sniper's key flipped to "|Cylinder" once the scope had spawned (2026-11-19). Every game static mag part sits
-- on a named socket (Magazine_Socket, MagCore_Socket).
local function findMagPart(wmesh)
    local staticPick = nil
    for _, c in ipairs(children(wmesh)) do
        local cls = className(c)
        local asset = shortName(meshAsset(c))
        local full = fullName(meshAsset(c)) or ""
        local socket = "None"
        pcall(function() socket = c.AttachSocketName:to_string() end)
        local engineAsset = full:find(" /Engine/", 1, true) ~= nil or full:sub(1, 8) == "/Engine/"
        if engineAsset then
            -- not a game part
        elseif cls:find("SkeletalMesh", 1, true) and magLike(asset) then
            return c
        elseif staticPick == nil and cls:find("StaticMesh", 1, true) and socket ~= "None" and (magLike(socket) or magLike(asset)) and socket ~= "Mod_Socket" then
            staticPick = c
        end
    end
    return staticPick
end

local function displayName(weapon)
    local s = nil
    pcall(function()
        local lib = uevrUtils.find_default_instance("Class /Script/OEIText.OEITextLibrary")
        local t = lib:GetLocStringText(weapon.Name)
        if type(t) == "string" then s = t
        elseif t ~= nil and t.to_string ~= nil then s = t:to_string() end
    end)
    if s ~= nil then s = s:gsub("%z", "") end -- the FText string carries a trailing NUL (cut log lines short)
    if s == nil or s == "" then s = shortName(weapon:get_class()) end
    return s
end

local keyCache = {}   -- weapon address -> key
local function keyFor(weapon)
    if weapon == nil then return nil end
    local addr = nil
    pcall(function() addr = weapon:get_address() end)
    if addr ~= nil and keyCache[addr] ~= nil then return keyCache[addr] end
    local wmesh = nil
    pcall(function() wmesh = weapon.FPVWeaponMesh end)
    if wmesh == nil then return nil end
    local key = shortName(meshAsset(wmesh)) .. "|" .. shortName(meshAsset(findMagPart(wmesh)))
    if addr ~= nil then keyCache[addr] = key end
    return key
end

-- the visual part riding the item bone(s) - the same rule the learn uses (analyse: "the visual part on the item")
local function itemPartOf(wmesh, item)
    if wmesh == nil or item == nil or item.bone == nil then return nil end
    local set = {}
    for _, b in ipairs(item.bones or { item.bone }) do set[b] = true end
    for _, c in ipairs(children(wmesh)) do
        local cls = className(c)
        local socket = "None"
        pcall(function() socket = c.AttachSocketName:to_string() end)
        local asset = meshAsset(c)
        local onItem = false
        if socket ~= "None" then
            pcall(function() onItem = set[wmesh:GetSocketBoneName(c.AttachSocketName):to_string()] == true end)
        elseif cls:find("SkeletalMesh", 1, true) and partIsItem(shortName(asset)) then
            onItem = true
        end
        if onItem then return { asset = fullName(asset), cls = cls, socket = socket } end
    end
    return nil
end

-- magazine variants (2026-11-19): the key is "<gun mesh>|<mag part>", so every mod that swaps the magazine was a
-- new, unlearned gun. The reload montages belong to the gun mesh (same skeleton, same item bone path), only the
-- magazine mesh differs - an unlearned variant borrows the learned profile of the same gun mesh with the live
-- magazine part swapped in. A re-learn on the variant records its own profile, which then wins.
local variantCache = {}   -- variant key -> derived profile, or false when no profile of the same mesh is learned
local function meshOfKey(k) return k:match("^(.*)|") end
local function baseProfileFor(k)
    local mesh = meshOfKey(k)
    if mesh == nil then return nil end
    local best, bestKey, bestScore = nil, nil, -1
    for pk, p in pairs(profiles) do
        if pk ~= k and type(p) == "table" and p.item ~= nil and meshOfKey(pk) == mesh then
            local r = p.recorded or {}
            local score = (r.tactical and 1 or 0) + (r.empty and 1 or 0)
            if score > bestScore or (score == bestScore and pk < bestKey) then best, bestKey, bestScore = p, pk, score end
        end
    end
    return best, bestKey
end

local function variantProfile(weapon, k)
    local v = variantCache[k]
    if v ~= nil then return v or nil end
    local base, baseKey = baseProfileFor(k)
    if base == nil then variantCache[k] = false return nil end
    v = {}
    for f, x in pairs(base) do v[f] = x end
    v.item = {}
    for f, x in pairs(base.item) do v.item[f] = x end
    v.variantOf = baseKey
    if base.item.prop == nil then
        local wmesh = nil
        pcall(function() wmesh = weapon.FPVWeaponMesh end)
        v.item.part = itemPartOf(wmesh, base.item)
    end
    -- the magazine decides the capacity (round-by-round + break-action "full" checks)
    pcall(function() v.poolSize = weapon:GetAmmoPool().PoolSize end)
    variantCache[k] = v
    info("variant " .. k .. " uses the profile of " .. baseKey .. (v.item.part and (" with part " .. v.item.part.asset) or " (bone copy)"))
    return v
end

local function getProfile(weapon)
    local k = keyFor(weapon)
    if k == nil then return nil end
    local p = profiles[k]
    if p ~= nil and p.item ~= nil then return p end
    return variantProfile(weapon, k)
end

-- -------------------------------------------------------------------------------------------------------------------
-- live state
-- -------------------------------------------------------------------------------------------------------------------
local cur = nil       -- current weapon context
local rec = nil       -- active recording
local clock = 0
local relearnKey = nil

local function setStatus(text) pcall(function() configui.setLabel("mr_auto_status", "Reload analysis: " .. text) end) end

local function profileSummary(p)
    if p == nil then return "not learned yet - do a normal reload (one with rounds left, one from empty)" end
    local parts = {}
    parts[#parts + 1] = p.style or "?"
    parts[#parts + 1] = (p.hand or "?") .. " hand"
    if p.item and p.item.bone then parts[#parts + 1] = "item " .. p.item.bone end
    if p.item and p.item.prop then parts[#parts + 1] = "prop " .. tostring(p.item.prop.asset) end
    if p.rack then parts[#parts + 1] = "rack " .. p.rack.bone end
    parts[#parts + 1] = "learned: " .. (p.recorded and p.recorded.tactical and "tactical " or "") ..
        (p.recorded and p.recorded.empty and "empty" or "")
    if p.recorded and (not p.recorded.tactical or (not p.recorded.empty and p.hasEmptyReload == true)) then
        parts[#parts + 1] = "(still to learn: " .. (not p.recorded.tactical and "tactical " or "") ..
            ((not p.recorded.empty and p.hasEmptyReload) and "empty" or "") .. ")"
    end
    return table.concat(parts, ", ")
end

local function updateStatus()
    if cur == nil then setStatus("no gun") return end
    if rec ~= nil then setStatus(cur.display .. ": recording the reload...") return end
    local p = profiles[cur.key]
    local v = (p == nil or p.item == nil) and variantProfile(cur.weapon, cur.key) or nil
    if v ~= nil then
        setStatus(cur.display .. ": magazine variant of " .. tostring(v.variantOf) .. " - " .. profileSummary(v))
        return
    end
    setStatus(cur.display .. ": " .. profileSummary(p))
end

local function findSocket(pawn, weapon, arms)
    local socket = nil
    pcall(function()
        local o = weapon.FPVCurrentVisuals.OverrideAttachSocket
        if o ~= nil and o:to_string() ~= "None" and arms:DoesSocketExist(o) then socket = o end
    end)
    if socket == nil then pcall(function() socket = pawn.PlayerEquipmentComponent.WeaponAttachSocketFPV end) end
    return socket
end

local armsCache = { arms = nil }  -- per arms mesh: hand bones + finger lists
local function armsInfo(arms)
    if armsCache.arms == arms and armsCache.l ~= nil then return armsCache end
    local c = { arms = arms, fingers = { l = {}, r = {} } }
    pcall(function()
        local n = arms:GetNumBones()
        for i = 0, n - 1 do
            local f = arms:GetBoneName(i)
            local s = f:to_string()
            if s == "l_hand_JNT" then c.l = f elseif s == "r_hand_JNT" then c.r = f end
        end
        for i = 0, n - 1 do
            local f = arms:GetBoneName(i)
            local s = f:to_string()
            -- real finger bones only (skip IK goals, attach / prop sockets, virtual bones)
            local finger = s:sub(1, 3) ~= "VB " and not s:find("IK", 1, true) and not s:find("_Att", 1, true)
                and not s:find("Socket", 1, true) and not s:find("shield", 1, true) and not s:find("Prop", 1, true)
            if finger and c.l ~= nil and f ~= c.l and arms:BoneIsChildOf(f, c.l) then c.fingers.l[#c.fingers.l + 1] = { name = s, f = f } end
            if finger and c.r ~= nil and f ~= c.r and arms:BoneIsChildOf(f, c.r) then c.fingers.r[#c.fingers.r + 1] = { name = s, f = f } end
        end
    end)
    armsCache = c
    return c
end

local function readBones(wmesh, bones)
    local out = {}
    for i, b in ipairs(bones) do
        pcall(function() out[i] = copyT(wmesh:GetSocketTransform(b.f, RTS_COMPONENT)) end)
    end
    return out
end

local function setupWeapon(pawn, weapon)
    local wmesh, arms = nil, nil
    pcall(function() wmesh = weapon.FPVWeaponMesh end)
    pcall(function() arms = pawn.FPVMesh end)
    if wmesh == nil or arms == nil then cur = nil return end
    cur = { weapon = weapon, wmesh = wmesh, arms = arms, bones = {}, byName = {}, nextRest = 0 }
    pcall(function() cur.pool = weapon:GetAmmoPool() end)
    cur.key = keyFor(weapon)
    cur.display = displayName(weapon)
    cur.socket = findSocket(pawn, weapon, arms)
    cur.armsInfo = armsInfo(arms)
    pcall(function()
        local n = wmesh:GetNumBones()
        for i = 0, n - 1 do
            local f = wmesh:GetBoneName(i)
            local p = "None"
            pcall(function() p = wmesh:GetParentBone(f):to_string() end)
            local b = { name = f:to_string(), f = f, parent = p, index = #cur.bones + 1 }
            cur.bones[#cur.bones + 1] = b
            cur.byName[b.name] = b
        end
    end)
    cur.rest = readBones(wmesh, cur.bones)
    cur.restClip = nil
    pcall(function() cur.restClip = weapon:GetCurrentAmmoCount() end)
    info("gun " .. tostring(cur.display) .. " key " .. tostring(cur.key) .. ", " .. #cur.bones .. " bones, socket " ..
        tostring(cur.socket and cur.socket:to_string()) .. ", profile " .. (profiles[cur.key or ""] and "yes" or "no"))
    updateStatus()
end

local function activeMontage(mesh)
    local m, pos = nil, nil
    pcall(function()
        local ai = mesh.AnimScriptInstance
        m = ai:GetCurrentActiveMontage()
        if m ~= nil then pos = ai:Montage_GetPosition(m) end
    end)
    return m, pos
end
local function isReloadMontage(m)
    if m == nil then return false end
    return shortName(m):lower():find("reload", 1, true) ~= nil
end
local function isReloading()
    local r = false
    pcall(function() r = cur.weapon:IsReloading() end)
    if r then return true end
    return isReloadMontage((activeMontage(cur.arms))) or isReloadMontage((activeMontage(cur.wmesh)))
end
local function getClip()
    local n = nil
    pcall(function() n = cur.weapon:GetCurrentAmmoCount() end)
    return n
end

-- an "empty" reload only exists for guns with their own empty variant (revolvers, break actions and the rocket
-- pistol reload the same way from empty: that counts as their normal reload, and has no rack)
local function isEmptyVariant(clip)
    if clip ~= 0 then return false end
    local has = true
    pcall(function() has = cur.pool.bHasEmptyReload end)
    return has == true
end

local function needsRecording(clip)
    if cur == nil or cur.key == nil then return false end
    if relearnKey == cur.key then return true end
    local p = profiles[cur.key]
    if p == nil or p.item == nil then p = variantProfile(cur.weapon, cur.key) or p end
    if p == nil or p.recorded == nil then return true end
    if isEmptyVariant(clip) then return p.recorded.empty == nil end
    return p.recorded.tactical == nil
end

-- -------------------------------------------------------------------------------------------------------------------
-- recording
-- -------------------------------------------------------------------------------------------------------------------
local function socketT(arms, socket)
    if socket == nil then return nil end
    local t = nil
    pcall(function() t = copyT(arms:GetSocketTransform(socket, RTS_COMPONENT)) end)
    return t
end

local function findHandProp(arms)
    for _, c in ipairs(children(arms)) do
        local socket = "None"
        pcall(function() socket = c.AttachSocketName:to_string() end)
        if socket:find("l_hand_Prop", 1, true) or socket:find("r_hand_Prop", 1, true) then
            local vis = true
            pcall(function() vis = c.bVisible end)
            if vis then return c, socket end
        end
    end
    return nil
end

local function startRecording()
    rec = { t0 = clock, lastActive = clock, frames = {}, fingers = {}, nextFinger = 0, empty = false }
    rec.clip0 = getClip()
    rec.empty = isEmptyVariant(rec.clip0)
    rec.key = cur.key
    -- rest pose: the idle snapshot (an empty pistol already shows its slide locked back at reload start)
    rec.rest = cur.rest
    updateStatus()
    info("recording " .. (rec.empty and "EMPTY" or "TACTICAL") .. " reload of " .. cur.display .. " (" .. tostring(cur.key) .. ")")
end

local function recordFrame()
    -- a shot ends the record (2026-11-20, Auto-Hacker 5000): the clip only rises during a reload, so a drop means the
    -- player fired in the END_TAIL window. The shot cycles the charging lever, and a last frame caught mid-cycle (0.6 cm
    -- out) failed the rack's back-at-rest test - the lever was not learned. Frames from the first shot on are not reload.
    local clipNow = getClip()
    if clipNow ~= nil then
        if rec.maxClip ~= nil and clipNow < rec.maxClip then rec.fired = true return end
        if rec.maxClip == nil or clipNow > rec.maxClip then rec.maxClip = clipNow end
    end
    local s = socketT(cur.arms, cur.socket)
    if s == nil then return end
    local ai = cur.armsInfo
    local fr = { t = clock - rec.t0, clip = clipNow, bones = readBones(cur.wmesh, cur.bones) }
    -- the weapon reload montage's own time: a bolt action is driven by scrubbing it (manual_reload)
    do
        local gm, gpos = activeMontage(cur.wmesh)
        if gm ~= nil and isReloadMontage(gm) then fr.gpos = gpos end
        -- the arms reload montage leads: the weapon montage is its sync follower and takes the arms' position every
        -- frame (a Montage_SetPosition on the weapon montage alone is undone the next frame, 2026-11-19)
        local am, apos = activeMontage(cur.arms)
        if am ~= nil and isReloadMontage(am) then fr.apos = apos end
    end
    pcall(function() fr.l = relT(s, copyT(cur.arms:GetSocketTransform(ai.l, RTS_COMPONENT))) end)
    pcall(function() fr.r = relT(s, copyT(cur.arms:GetSocketTransform(ai.r, RTS_COMPONENT))) end)
    local prop, propSocket = findHandProp(cur.arms)
    if prop ~= nil then
        pcall(function()
            local ps = copyT(cur.arms:GetSocketTransform(prop.AttachSocketName, RTS_COMPONENT))
            -- the prop sits on its socket at its relative transform (0 in every case seen); include it anyway
            local rl, rr = prop.RelativeLocation, prop.RelativeRotation
            local relQ = nil
            pcall(function() relQ = copyT(kismet_math_library:MakeTransform(rl, rr, { X = 1, Y = 1, Z = 1 })).q end)
            local local_ = { loc = { X = rl.X, Y = rl.Y, Z = rl.Z }, q = relQ or { X = 0, Y = 0, Z = 0, W = 1 } }
            local pw = { loc = { X = ps.loc.X, Y = ps.loc.Y, Z = ps.loc.Z }, q = ps.q }
            pw.loc = { X = pw.loc.X + qrot(ps.q, local_.loc).X, Y = pw.loc.Y + qrot(ps.q, local_.loc).Y, Z = pw.loc.Z + qrot(ps.q, local_.loc).Z }
            pw.q = qmul(ps.q, local_.q)
            fr.prop = { T = relT(s, pw), asset = fullName(meshAsset(prop)), cls = className(prop), socket = propSocket,
                        hand = propSocket:sub(1, 1) }
            -- a skeletal prop draws where its root bone is, not where its component is (2026-11-20, Charged Shock AR:
            -- the shock rod's socket / component pose sat 35-60 cm off the left hand and barely moved for the whole
            -- reload, while the game shows the rod in that hand - the rod's own animation carries its root bone there).
            -- The prop pose is the root bone's, both read in world space and taken into the arms component frame;
            -- sockT keeps the socket pose for the diagnostic below.
            local nb = 0
            pcall(function() nb = prop:GetNumBones() end)
            if nb > 0 then
                local armsW = copyT(cur.arms:K2_GetComponentToWorld())
                local rootW = copyT(prop:GetSocketTransform(prop:GetBoneName(0), 0))
                fr.prop.sockT = fr.prop.T
                fr.prop.T = relT(s, relT(armsW, rootW))
                if not rec.propRootInfo and fr.l ~= nil then
                    rec.propRootInfo = true
                    info(string.format("prop root: %s hand-l to socket %.1f cm, to root bone %.1f cm",
                        prop:GetBoneName(0):to_string(), dist(fr.l.loc, fr.prop.sockT.loc), dist(fr.l.loc, fr.prop.T.loc)))
                end
            end
        end)
        -- diagnostic (2026-11-19, Corrosive Shock MG rod: the socket pose stayed put while the hand moved 70 cm): the
        -- prop component's own transform and, for a skeletal prop, its first bones - in the same gun-socket frame
        pcall(function()
            local nb = 0
            pcall(function() nb = prop:GetNumBones() end)
            if not rec.propInfo then
                rec.propInfo = true
                local leader, parent = "-", "-"
                pcall(function() leader = fullName(prop.LeaderPoseComponent) end)
                pcall(function() parent = fullName(prop.AttachParent) end)
                local names = {}
                for bi = 0, math.min(nb, 12) - 1 do pcall(function() names[#names + 1] = prop:GetBoneName(bi):to_string() end) end
                info(string.format("prop diag: %s %s, %d bones [%s], parent %s socket %s, leader %s, relative (%.1f, %.1f, %.1f)",
                    className(prop), fullName(meshAsset(prop)), nb, table.concat(names, ","), parent, tostring(propSocket), leader,
                    prop.RelativeLocation.X, prop.RelativeLocation.Y, prop.RelativeLocation.Z))
            end
        end)
    end
    if #rec.frames < MAX_FRAMES then rec.frames[#rec.frames + 1] = fr end
    if clock >= rec.nextFinger then
        rec.nextFinger = clock + FINGER_EVERY
        local snap = { t = fr.t, l = {}, r = {} }
        for _, side in ipairs({ "l", "r" }) do
            local hand = nil
            pcall(function() hand = copyT(cur.arms:GetSocketTransform(ai[side], RTS_COMPONENT)) end)
            if hand ~= nil then
                for _, fb in ipairs(ai.fingers[side]) do
                    pcall(function() snap[side][fb.name] = relT(hand, copyT(cur.arms:GetSocketTransform(fb.f, RTS_COMPONENT))) end)
                end
            end
        end
        rec.fingers[#rec.fingers + 1] = snap
    end
    if isReloading() then rec.lastActive = clock end
end

-- -------------------------------------------------------------------------------------------------------------------
-- analysis
-- -------------------------------------------------------------------------------------------------------------------
local function subtreeOf(rootName)
    local out, set = {}, {}
    set[rootName] = true
    out[#out + 1] = rootName
    local grew = true
    while grew do
        grew = false
        for _, b in ipairs(cur.bones) do
            if not set[b.name] and set[b.parent] then set[b.name] = true out[#out + 1] = b.name grew = true end
        end
    end
    return out, set
end

local function isAncestor(anc, name)
    local b = cur.byName[name]
    while b ~= nil and b.parent ~= "None" do
        if b.parent == anc then return true end
        b = cur.byName[b.parent]
    end
    return false
end

-- per bone: max travel / rotation from rest, and whether it is back at rest at the end
local function boneMotion(frames, rest)
    local out = {}
    for i, b in ipairs(cur.bones) do
        local r = rest[i]
        local m = { maxD = 0, maxA = 0, tD = 0, iD = nil, iA = nil, endRest = true, startOff = false }
        if r ~= nil then
            for fi, fr in ipairs(frames) do
                local t = fr.bones[i]
                if t ~= nil then
                    local d, a = dist(t.loc, r.loc), qangle(t.q, r.q)
                    if d > m.maxD then m.maxD, m.iD = d, fi end
                    if a > m.maxA then m.maxA, m.iA = a, fi end
                end
            end
            local first, last = frames[1] and frames[1].bones[i], frames[#frames] and frames[#frames].bones[i]
            if last ~= nil then m.endRest = dist(last.loc, r.loc) < 0.5 and qangle(last.q, r.q) < 3 end
            if first ~= nil then m.startOff = dist(first.loc, r.loc) > 1.0 end
        end
        out[i] = m
    end
    return out
end

-- longest run where hand-in-bone is constant while bone and hand both travel relative to the gun
local function gripWindow(frames, bi, hk, rest)
    local best, run, prev, prevF = nil, nil, nil, nil
    for _, fr in ipairs(frames) do
        local bt, h = fr.bones[bi], fr[hk]
        local rel = (bt and h) and relT(bt, h) or nil
        local off = bt and rest[bi] and dist(bt.loc, rest[bi].loc) > 1.0
        local steady = rel and prev and off and dist(rel.loc, prev.loc) < 0.4 and qangle(rel.q, prev.q) < 3.0
        if steady then
            if run == nil then run = { t0 = fr.t, n = 0, sum = { X = 0, Y = 0, Z = 0 }, bPath = 0, hPath = 0 } end
            run.n = run.n + 1
            run.t1 = fr.t
            run.sum = { X = run.sum.X + rel.loc.X, Y = run.sum.Y + rel.loc.Y, Z = run.sum.Z + rel.loc.Z }
            run.q = rel.q
            if prevF ~= nil and prevF.bones[bi] and prevF[hk] then
                run.bPath = run.bPath + dist(bt.loc, prevF.bones[bi].loc)
                run.hPath = run.hPath + dist(h.loc, prevF[hk].loc)
            end
            if run.bPath > 2 and run.hPath > 2 and (best == nil or run.n > best.n) then best = run end
        else
            run = nil
        end
        prev, prevF = rel, fr
    end
    if best == nil or best.n < 3 then return nil end
    return { t0 = best.t0, t1 = best.t1, n = best.n, hand = hk,
             T = { loc = { X = best.sum.X / best.n, Y = best.sum.Y / best.n, Z = best.sum.Z / best.n }, q = best.q } }
end

local function ammoSteps(frames)
    local steps, last = {}, frames[1] and frames[1].clip
    for _, fr in ipairs(frames) do
        if fr.clip ~= nil and last ~= nil and fr.clip > last then steps[#steps + 1] = { t = fr.t, from = last, to = fr.clip } end
        if fr.clip ~= nil then last = fr.clip end
    end
    return steps
end

local function fingerPoseAt(t, side)
    local best, bestD = nil, 1e9
    for _, s in ipairs(rec.fingers) do
        local d = math.abs(s.t - t)
        if d < bestD then best, bestD = s, d end
    end
    if best == nil then return nil end
    local out = {}
    for name, T in pairs(best[side]) do out[name] = packT(T) end
    return out
end

-- seat frame = the first frame (after the item was away) where the item is back at rest; approach = the earliest
-- frame of the continuous final stretch within APPROACH_MAX_CM of the seat
local strokeInto
local function insertPath(frames, bi, rest, afterT)
    local r = rest[bi]
    local away, seat = false, nil
    for fi, fr in ipairs(frames) do
        local t = fr.bones[bi]
        if t ~= nil and fr.t >= (afterT or 0) then
            local d = dist(t.loc, r.loc)
            if d > 1.0 then away = true end
            if away and d < SEATED_CM then seat = fi break end
        end
    end
    if seat == nil then return nil end
    return strokeInto(frames, bi, r, seat)
end

-- the final insert stroke into target (a pose) ending at frame seat: its direction comes from the first frame back
-- that is > 1.5 cm out; walk back while the item stays in line with that stroke (the hand's earlier swing toward the
-- gun is not part of the insert)
strokeInto = function(frames, bi, r, seat)
    local ref = nil
    for k = seat - 1, 1, -1 do
        local t = frames[k].bones[bi]
        if t == nil then break end
        if dist(t.loc, r.loc) > 1.5 then ref = vnorm(vsub(r.loc, t.loc)) break end
    end
    local a = seat - 1
    while a > 1 do
        local t, tp = frames[a].bones[bi], frames[a - 1].bones[bi]
        if t == nil or tp == nil then break end
        -- the game snaps the last few cm in one frame (pistol: 5 cm), so allow jumps up to 8 cm
        if dist(tp.loc, r.loc) > APPROACH_MAX_CM or dist(tp.loc, t.loc) > 8.0 then break end
        -- in line with the stroke, beyond 1.5 cm (the distance that defines the stroke direction): the Beam Caster's
        -- battery wobbles 0.5-0.8 cm around its seat before settling, and those sub-cm steps point anywhere
        if ref ~= nil and dist(tp.loc, r.loc) > 1.5 then
            local d = vnorm(vsub(r.loc, tp.loc))
            local c = d.X * ref.X + d.Y * ref.Y + d.Z * ref.Z
            if c < math.cos(math.rad(15)) then break end
        end
        a = a - 1
    end
    local at = frames[a].bones[bi]
    local depth = dist(at.loc, r.loc)
    return { seatT = frames[seat].t, approach = at, depth = depth, axis = vnorm(vsub(r.loc, at.loc)) }
end

local function analyze()
    local frames, rest = rec.frames, rec.rest
    if #frames < 5 then return nil, "too short" end
    local steps = ammoSteps(frames)
    if #steps == 0 then return nil, "no ammo landed (cancelled?)" end
    local motion = boneMotion(frames, rest)
    local res = { empty = rec.empty, ammo = {}, mechanisms = {} }
    for _, s in ipairs(steps) do res.ammo[#res.ammo + 1] = r3(s.t) end
    local gaps, pour = {}, false
    for i = 2, #steps do gaps[#gaps + 1] = steps[i].t - steps[i - 1].t end
    for _, g in ipairs(gaps) do if g < POUR_GAP then pour = true end end
    res.perRound = (#steps >= 2 and not pour)
    res.pour = pour

    -- the carried item: the longest steady-grip window over bones that travelled far
    local best = nil
    for i, b in ipairs(cur.bones) do
        if motion[i].maxD >= ITEM_MIN_TRAVEL then
            for _, hk in ipairs({ "l", "r" }) do
                local w = gripWindow(frames, i, hk, rest)
                if w ~= nil then
                    w.bi = i
                    if best == nil or w.n > best.n then best = w end
                end
            end
        end
    end
    -- prefer an ancestor that is carried nearly as long (Magazine_JNT over its bullets)
    if best ~= nil then
        local changed = true
        while changed do
            changed = false
            local parent = cur.byName[cur.bones[best.bi].parent]
            if parent ~= nil and motion[parent.index].maxD >= ITEM_MIN_TRAVEL then
                local w = gripWindow(frames, parent.index, best.hand, rest)
                if w ~= nil and w.n >= best.n * 0.8 then w.bi = parent.index best = w changed = true end
            end
        end
    end
    local gripSource = "window"
    if best == nil then
        -- fallback: magazine-like bone with the most travel, hand pose at the last frame before it seats
        local pick, pickD = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if m.maxD >= ITEM_MIN_TRAVEL and (magLike(b.name) or b.name:lower():find("bullet", 1, true) or b.name:lower():find("rocket", 1, true)) then
                local parent = cur.byName[b.parent]
                local parentMoves = parent ~= nil and motion[parent.index].maxD >= ITEM_MIN_TRAVEL
                if not parentMoves and m.maxD > pickD then pick, pickD = i, m.maxD end
            end
        end
        if pick ~= nil then
            local path = insertPath(frames, pick, rest)
            local fi = nil
            if path ~= nil then
                for k, fr in ipairs(frames) do if fr.t >= path.seatT then fi = math.max(1, k - 1) break end end
            end
            fi = fi or #frames
            local fr = frames[fi]
            local bt = fr.bones[pick]
            -- the carrying hand: the one that stays closest to the item over its whole trip off the gun (mean
            -- distance), not at one frame - the rocket pistol's right hand on the grip is closer to the rocket's rear
            -- in the last frame before the seat, while the left hand brings it
            local sum, cnt = { l = 0, r = 0 }, 0
            local seatT = path and path.seatT or math.huge
            for _, f2 in ipairs(frames) do
                local b2 = f2.bones[pick]
                if b2 ~= nil and f2.t < seatT and f2.l ~= nil and f2.r ~= nil and dist(b2.loc, rest[pick].loc) > 1.0 then
                    sum.l, sum.r, cnt = sum.l + dist(f2.l.loc, b2.loc), sum.r + dist(f2.r.loc, b2.loc), cnt + 1
                end
            end
            local hk
            if cnt > 0 then
                hk = sum.l <= sum.r and "l" or "r"
            else
                local dl = (fr.l and bt) and dist(fr.l.loc, bt.loc) or 1e9
                local dr = (fr.r and bt) and dist(fr.r.loc, bt.loc) or 1e9
                hk = dl <= dr and "l" or "r"
            end
            if bt ~= nil and fr[hk] ~= nil then
                -- the grip is the hand on the item as it seats; the window is the item's trip off the gun (t0 = when it
                -- leaves). t0 = the seat frame made the insert-path search start after the seat and find nothing
                -- (Kinetic Beam Caster, 2026-11-19)
                local t0 = fr.t
                for _, f2 in ipairs(frames) do
                    local b2 = f2.bones[pick]
                    if b2 ~= nil and f2.t < fr.t and dist(b2.loc, rest[pick].loc) > 1.0 then t0 = f2.t break end
                end
                best = { bi = pick, hand = hk, t0 = t0, t1 = fr.t, n = 1, T = relT(bt, fr[hk]) }
                gripSource = "closest"
            end
        end
    end

    -- a hand prop (cell, canister, rod)
    local propFrames = {}
    for _, fr in ipairs(frames) do if fr.prop ~= nil then propFrames[#propFrames + 1] = fr end end

    local itemSet = {}
    if best ~= nil then
        local item = cur.bones[best.bi]
        local names, set = subtreeOf(item.name)
        itemSet = set
        local path = insertPath(frames, best.bi, rest, best.t0)
        res.item = { bone = item.name, bones = names, grip = packT(best.T), gripSource = gripSource,
                     gripT = { r3(best.t0), r3(best.t1) }, rest = packT(rest[best.bi]) }
        -- dock: where the item sits when the first ammo lands, when that is not its rest (the Heavy Revolver's
        -- speedloader rests stowed inside the grip and docks behind the open cylinder). The seat target becomes the
        -- dock, the insert stroke is measured into it.
        do
            local fa = nil
            for k, fr in ipairs(frames) do if fr.t >= steps[1].t - 0.001 then fa = k break end end
            local bt = fa and frames[fa].bones[best.bi]
            -- docked only if the item never slides on into its rest after the ammo landed (it leaves / teleports to a
            -- stowed rest): the heavy MG's magazine is 1.6 cm short of its seat when the ammo lands and then settles
            -- in - that is a magazine, not a dock (it got no drop copy, 2026-11-19)
            local slidesHome = false
            if bt ~= nil then
                local prev = bt
                for k = fa + 1, #frames do
                    local t = frames[k].bones[best.bi]
                    if t == nil then break end
                    if dist(t.loc, prev.loc) > 6.0 then break end -- a jump: left the gun / teleported
                    if dist(t.loc, rest[best.bi].loc) < SEATED_CM then slidesHome = true break end
                    prev = t
                end
            end
            if bt ~= nil and not slidesHome and dist(bt.loc, rest[best.bi].loc) > 1.5 then
                local ps = fa
                while ps > 1 and frames[ps - 1].bones[best.bi] ~= nil and dist(frames[ps - 1].bones[best.bi].loc, bt.loc) < 0.4 do ps = ps - 1 end
                local dpath = strokeInto(frames, best.bi, bt, ps)
                res.item.seat = packT(bt)
                res.item.docked = true
                path = dpath
                if path ~= nil then path.seatT = frames[ps].t end
            end
        end
        if path ~= nil then
            res.item.approach = packT(path.approach)
            res.item.depth = r3(path.depth)
            res.item.axis = { X = r3(path.axis.X), Y = r3(path.axis.Y), Z = r3(path.axis.Z) }
            res.item.seatT = r3(path.seatT)
        end
        res.hand = best.hand == "l" and "left" or "right"
        res.fingers = fingerPoseAt((best.t0 + best.t1) / 2, best.hand)
        -- round by round: every cycle the hand picks a round with the fingers wrapped, then opens them while the thumb
        -- pushes it in (the round slides in the fingers, so no steady window holds the real grip). Grip + fingers come
        -- from the frame where the hand is nearest the round while it is carried (Holographic Repeating Rifle
        -- 2026-11-19: window 0.34-0.50 s = index 216 deg, "fingers too wide"; nearest 1.82 s, 5.1 cm = index 314 deg)
        if res.perRound then
            local hk = best.hand
            local bestK, bestD = nil, 1e9
            for k, f2 in ipairs(frames) do
                local t, h = f2.bones[best.bi], f2[hk]
                if t ~= nil and h ~= nil and dist(t.loc, rest[best.bi].loc) > 1.0 then
                    local d = dist(h.loc, t.loc)
                    if d < bestD then bestK, bestD = k, d end
                end
            end
            if bestK ~= nil then
                local f2 = frames[bestK]
                res.item.grip = packT(relT(f2.bones[best.bi], f2[hk]))
                res.item.gripSource = "nearest"
                res.item.gripT = { r3(f2.t), r3(f2.t) }
                res.fingers = fingerPoseAt(f2.t, hk)
            end
        end
        -- the visual part on the item
        for _, c in ipairs(children(cur.wmesh)) do
            local cls = className(c)
            local socket = "None"
            pcall(function() socket = c.AttachSocketName:to_string() end)
            local asset = meshAsset(c)
            local onItem = false
            if socket ~= "None" then
                pcall(function() onItem = set[cur.wmesh:GetSocketBoneName(c.AttachSocketName):to_string()] == true end)
            elseif cls:find("SkeletalMesh", 1, true) and partIsItem(shortName(asset)) then
                onItem = true
            end
            if onItem then
                res.item.part = { asset = fullName(asset), cls = cls, socket = socket }
                break
            end
        end
        res.style = res.perRound and "rounds" or "item"
    elseif #propFrames > 0 then
        local pf = propFrames[1].prop
        res.item = { prop = { asset = pf.asset, cls = pf.cls, socket = pf.socket } }
        -- grip: hand in prop frame (constant: the prop rides the hand socket)
        local mid = propFrames[math.floor(#propFrames / 2) + 1]
        local hk = pf.hand == "r" and "r" or "l"
        if mid[hk] ~= nil then res.item.grip = packT(relT(mid.prop.T, mid[hk])) end
        res.hand = hk == "l" and "left" or "right"
        -- dock: the prop pose while ammo rises
        local sum, n, q = { X = 0, Y = 0, Z = 0 }, 0, nil
        for _, fr in ipairs(propFrames) do
            for _, s in ipairs(steps) do
                if math.abs(fr.t - s.t) < 0.05 then
                    sum = { X = sum.X + fr.prop.T.loc.X, Y = sum.Y + fr.prop.T.loc.Y, Z = sum.Z + fr.prop.T.loc.Z }
                    n, q = n + 1, fr.prop.T.q
                    break
                end
            end
        end
        if n == 0 then
            -- prop gone before ammo landed (beam MG: the rod docks, then a door turns): last prop frame
            local lf = propFrames[#propFrames]
            sum, n, q = lf.prop.T.loc, 1, lf.prop.T.q
        end
        res.item.dock = packT({ loc = { X = sum.X / n, Y = sum.Y / n, Z = sum.Z / n }, q = q })
        res.fingers = fingerPoseAt(mid.t, hk)
        res.style = "prop"
        -- parked prop (2026-11-20, Charged Shock AR): the prop rides l_hand_Prop_Socket on l_weapon_NSK, a child of the
        -- hand bone that the anims key ~90 cm under the hand (parked out of view) unless they bring the prop in. The
        -- Corrosive Shock MG's empty reload does (rod 9.4 cm from the hand); neither AR reload does, so the grip read
        -- 48 cm and the rod sat nowhere near the hand. A grip that far off is not a grip: the same prop asset's grip and
        -- finger pose from a profile that saw it in the hand are used, and the dock is the hand where the ammo lands
        -- (prop = hand * inverse(grip)).
        local gapOf = function(g) return g and g.loc and vlen(g.loc) or 1e9 end
        if gapOf(res.item.grip) > PROP_MAX_GRIP then
            local donor, donorKey = nil, nil
            for pk, pp in pairs(profiles) do
                local it = type(pp) == "table" and pp.item or nil
                if pk ~= rec.key and it and it.prop and it.prop.asset == pf.asset and gapOf(it.grip) <= PROP_MAX_GRIP
                    and (it.gripSource == nil or it.gripSource == "learned") then
                    if donor == nil or gapOf(it.grip) < gapOf(donor.item.grip) then donor, donorKey = pp, pk end
                end
            end
            if donor ~= nil then
                -- the hand where the ammo lands (else the last frame with the prop attached)
                local handAt = nil
                for _, fr in ipairs(frames) do
                    if fr[hk] ~= nil and steps[1] ~= nil and fr.t >= steps[1].t - 0.001 then handAt = fr[hk] break end
                end
                if handAt == nil then handAt = propFrames[#propFrames][hk] end
                local g = donor.item.grip
                local gq = { X = g.q.X, Y = g.q.Y, Z = g.q.Z, W = g.q.W }
                local invQ = qconj(gq)
                local invLoc = qrot(invQ, g.loc)
                invLoc = { X = -invLoc.X, Y = -invLoc.Y, Z = -invLoc.Z }
                if handAt ~= nil then
                    local dl = qrot(handAt.q, invLoc)
                    res.item.dock = packT({ loc = { X = handAt.loc.X + dl.X, Y = handAt.loc.Y + dl.Y, Z = handAt.loc.Z + dl.Z },
                                            q = qmul(handAt.q, invQ) })
                end
                info(string.format("prop grip %.1f cm (parked, never in the hand): using the grip of %s (%.1f cm)",
                    gapOf(res.item.grip), donorKey, gapOf(g)))
                res.item.grip = g
                res.item.gripSource = "borrowed:" .. donorKey
                if donor.fingers ~= nil then res.fingers = donor.fingers end
            else
                info(string.format("prop grip %.1f cm (parked, never in the hand) and no profile with this prop in the hand", gapOf(res.item.grip)))
            end
        end
    elseif res.perRound then
        -- Round by round with no carried round in the gun's skeleton (Incendiary Light Revolver 2026-11-19: the game's
        -- right hand fetches each round from 20-25 cm out and pushes it through a loading gate; no gun bone travels).
        -- The round goes into the chamber at the gate: of the round bones under the turning cylinder, the one nearest
        -- the gate across the cylinder axis; it is pushed along that axis from the gate side. The hand nearest that
        -- chamber when the rounds land holds it (grip + fingers from its nearest frame at an ammo step).
        local function low(b) return b.name:lower() end
        local ROUND_WORDS = { "bullet", "round", "shell", "cartridge" }
        local function roundLike(b)
            local n = low(b)
            for _, w in ipairs(ROUND_WORDS) do if n:find(w, 1, true) then return true end end
            return false
        end
        local gate = nil
        for i, b in ipairs(cur.bones) do if low(b):find("gate", 1, true) and rest[i] ~= nil then gate = i break end end
        local cyl, cylA = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if not roundLike(b) and m.maxA > cylA and m.iA ~= nil and rest[i] ~= nil then
                local has = false
                for _, c in ipairs(cur.bones) do
                    if roundLike(c) and isAncestor(b.name, c.name) then has = true break end
                end
                if has then cyl, cylA = i, m.maxA end
            end
        end
        if gate == nil or cyl == nil or cylA < 20 then return nil, "no carried item found" end
        -- the cylinder's turning axis (component frame) from rest to its most-turned frame
        local dq = qmul(frames[motion[cyl].iA].bones[cyl].q, qconj(rest[cyl].q))
        local sn = math.sqrt(math.max(0, 1 - dq.W * dq.W))
        if sn < 1e-4 then return nil, "no carried item found" end
        local ax = vnorm({ X = dq.X / sn, Y = dq.Y / sn, Z = dq.Z / sn })
        local g = rest[gate].loc
        local function across(p)
            local d = vsub(p, g)
            local along = d.X * ax.X + d.Y * ax.Y + d.Z * ax.Z
            return vlen({ X = d.X - ax.X * along, Y = d.Y - ax.Y * along, Z = d.Z - ax.Z * along }), along
        end
        local pick, pickD, pickAlong = nil, 1e9, 0
        for i, b in ipairs(cur.bones) do
            if roundLike(b) and rest[i] ~= nil and isAncestor(cur.bones[cyl].name, b.name) then
                local d, along = across(rest[i].loc)
                if d < pickD then pick, pickD, pickAlong = i, d, along end
            end
        end
        if pick == nil then return nil, "no carried item found" end
        -- the push direction: from the gate side into the chamber
        local dir = pickAlong >= 0 and ax or { X = -ax.X, Y = -ax.Y, Z = -ax.Z }
        local seat = rest[pick]
        local depth = math.abs(pickAlong) + 2.0
        local approach = { loc = { X = seat.loc.X - dir.X * depth, Y = seat.loc.Y - dir.Y * depth, Z = seat.loc.Z - dir.Z * depth }, q = seat.q }
        -- the loading hand: nearest the chamber at the ammo steps
        local best_ = { l = { d = 1e9 }, r = { d = 1e9 } }
        local sumD = { l = 0, r = 0 }
        for _, st in ipairs(steps) do
            for _, f2 in ipairs(frames) do
                if math.abs(f2.t - st.t) <= 0.12 then
                    for _, hk in ipairs({ "l", "r" }) do
                        if f2[hk] ~= nil then
                            local d = dist(f2[hk].loc, seat.loc)
                            if d < best_[hk].d then best_[hk] = { d = d, f = f2 } end
                        end
                    end
                end
            end
        end
        for _, f2 in ipairs(frames) do
            if f2.l ~= nil and f2.r ~= nil and f2.t >= steps[1].t - 0.6 and f2.t <= steps[#steps].t then
                sumD.l, sumD.r = sumD.l + dist(f2.l.loc, seat.loc), sumD.r + dist(f2.r.loc, seat.loc)
            end
        end
        -- the holding hand stays put next to the cylinder (low mean distance, little motion); the loading hand comes and
        -- goes - the nearest hand at the steps that is NOT parked beside the gun the whole time
        local function travel(hk)
            local tot, prev = 0, nil
            for _, f2 in ipairs(frames) do
                if f2[hk] ~= nil and f2.t >= steps[1].t - 0.6 and f2.t <= steps[#steps].t then
                    if prev ~= nil then tot = tot + dist(prev, f2[hk].loc) end
                    prev = f2[hk].loc
                end
            end
            return tot
        end
        local hk = travel("r") >= travel("l") and "r" or "l"
        local bf = best_[hk].f
        if bf == nil then return nil, "no carried item found" end
        local names, set = subtreeOf(cur.bones[pick].name)
        itemSet = set
        res.item = { bone = cur.bones[pick].name, bones = names, grip = packT(relT(seat, bf[hk])), gripSource = "gate",
                     gripT = { r3(bf.t), r3(bf.t) }, rest = packT(seat), seat = packT(seat), docked = true,
                     approach = packT(approach), depth = r3(depth), axis = { X = r3(dir.X), Y = r3(dir.Y), Z = r3(dir.Z) },
                     seatT = r3(steps[1].t), keepVisible = true, gate = cur.bones[gate].name, cylinder = cur.bones[cyl].name }
        res.hand = hk == "l" and "left" or "right"
        res.fingers = fingerPoseAt(bf.t, hk)
        res.style = "rounds"
    else
        return nil, "no carried item found"
    end

    -- round by round: where to hold between rounds. Holding on the count left the Incendiary Light Revolver's loaded
    -- round at the gate / a chamber half turned: the cylinder turns one chamber 0.09-0.15 s (montage) after the count,
    -- and from +0.23 s the ejector rod pushes the next spent case out (2026-11-19). Hold in the quiet moment between
    -- (montage time; manual_reload plays the settle at 1x). The loading hand's farthest point was tried first, but on an
    -- 8-round recording its distance plateau is flat (argmax anywhere in 0.20-0.24 s), so the hold
    -- is taken from the gun itself: after each count, the midpoint between the end of its first motion burst (the
    -- cylinder turn) and the start of the next (the ejector). The first round runs the montage's first section and
    -- settles sooner (turn +0.04-0.11, ejector +0.17 -> 0.14) than the looping rounds (turn to +0.17, next from +0.23 ->
    -- 0.20): feedSettleFirst + feedSettle (median of the loop rounds).
    if res.perRound and #steps >= 1 then
        local function moved(f, p)
            for i, b in ipairs(cur.bones) do
                local a, c = f.bones[i], p.bones[i]
                if not itemSet[b.name] and a ~= nil and c ~= nil and (dist(a.loc, c.loc) > 0.1 or qangle(a.q, c.q) > 1.0) then return true end
            end
            return false
        end
        local holds = {}
        for si, st in ipairs(steps) do
            local limit = steps[si + 1] and math.min(st.t + 0.45, steps[si + 1].t) or st.t + 0.45
            local lastMove, firstQuiet, nextMove = nil, nil, nil
            for k = 2, #frames do
                local f = frames[k]
                if f.t > st.t and f.t <= limit then
                    local mv = moved(f, frames[k - 1])
                    if lastMove == nil then
                        if mv then lastMove = f.t end
                    elseif firstQuiet == nil then
                        if mv then lastMove = f.t else firstQuiet = f.t end
                    elseif mv then
                        nextMove = f.t
                        break
                    end
                end
            end
            if lastMove ~= nil and firstQuiet ~= nil then
                holds[si] = ((lastMove + (nextMove or (firstQuiet + 0.05))) / 2) - st.t
            elseif lastMove == nil then
                holds[si] = 0 -- nothing moves after this count
            end
        end
        if holds[1] ~= nil then res.feedSettleFirst = r3(holds[1]) end
        local loop = {}
        for si = 2, #steps do if holds[si] ~= nil then loop[#loop + 1] = holds[si] end end
        if #loop > 0 then
            table.sort(loop)
            res.feedSettle = r3(loop[math.floor((#loop + 1) / 2)])
        else
            res.feedSettle = res.feedSettleFirst
        end
    end

    -- rack (empty reloads, or the only reload of a gun without an empty variant - Volted Sniper Rifle's bolt cycles on
    -- every reload): a part that slides from rest and back, outside the item
    local hasEmpty = true
    pcall(function() hasEmpty = cur.pool.bHasEmptyReload == true end)
    if rec.empty or not hasEmpty then
        local rk, rkD = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if not itemSet[b.name] and m.maxD >= RACK_MIN_TRAVEL and m.endRest and m.iD ~= nil then
                local t = frames[m.iD].bones[i]
                local rotAtMax = qangle(t.q, rest[i].q)
                local parent = cur.byName[b.parent]
                local parentSlides = parent ~= nil and not itemSet[parent.name] and motion[parent.index].maxD >= RACK_MIN_TRAVEL
                if rotAtMax < 20 and not parentSlides and m.maxD > rkD then rk, rkD = i, m.maxD end
            end
        end
        if rk ~= nil then
            local m = motion[rk]
            local b = cur.bones[rk]
            local tMax = frames[m.iD].bones[rk]
            local axis = vnorm(vsub(tMax.loc, rest[rk].loc))
            local release = nil
            for k = m.iD, #frames do
                local t = frames[k].bones[rk]
                if t ~= nil and dist(t.loc, rest[rk].loc) < 0.3 then release = frames[k].t break end
            end
            -- locked back: the part sits displaced for most of the reload before the pull (the game moves the
            -- pistol slide back within the first frames of an empty reload, so frame 1 can still read rest)
            local before, displaced, lockSum = 0, 0, 0
            for k = 1, m.iD - 1 do
                local t = frames[k].bones[rk]
                if t ~= nil then
                    before = before + 1
                    local d = dist(t.loc, rest[rk].loc)
                    if d > 1.0 then displaced, lockSum = displaced + 1, lockSum + d end
                end
            end
            local lockedBack = before >= 5 and displaced >= before * 0.8
            -- hand on it: the hand doing the reload work (the item hand) when it is near the part at max pull, else the
            -- closer hand. Closest alone picked the bullpup AR's right hand, which sits on the grip about 1 cm closer
            -- than the left hand pulling the lever.
            local fr = frames[m.iD]
            local dl = fr.l and dist(fr.l.loc, tMax.loc) or 1e9
            local dr = fr.r and dist(fr.r.loc, tMax.loc) or 1e9
            local hk = dl <= dr and "l" or "r"
            local workHand = res.hand == "left" and "l" or (res.hand == "right" and "r" or nil)
            if workHand ~= nil and (workHand == "l" and dl or dr) <= 25 then hk = workHand end
            res.rack = { bone = b.name, axis = { X = r3(axis.X), Y = r3(axis.Y), Z = r3(axis.Z) }, travel = r3(m.maxD),
                         lockedBack = lockedBack, lockedCm = lockedBack and r3(lockSum / displaced) or nil,
                         pullT = r3(fr.t), releaseT = release and r3(release) or nil,
                         hand = hk == "l" and "left" or "right", grip = fr[hk] and packT(relT(tMax, fr[hk])) or nil,
                         rest = packT(rest[rk]), fingers = fingerPoseAt(fr.t, hk) }
            -- lift: a rotating part in the rack's chain that turns before the pull (bolt handle)
            for i, bb in ipairs(cur.bones) do
                local mm = motion[i]
                if i ~= rk and (isAncestor(b.name, bb.name) or isAncestor(bb.name, b.name)) and mm.maxA >= 20 and mm.iA ~= nil
                    and frames[mm.iA].t <= fr.t + 0.05 then
                    local open = frames[mm.iA].bones[i]
                    res.rack.lift = { bone = bb.name, angle = r3(mm.maxA), open = packT(relT(rest[i], open)) }
                    break
                end
            end
            -- the hand pose on the part: the frame where the rack hand is nearest the part it works (the lift handle when
            -- there is one) while the part is off rest. At the max pull the Volted Sniper's right hand is holding the
            -- new clip 12.6 cm away (finger pose = clip grip, "mangled"); it is on the handle at 2.51 s (5.2 cm).
            do
                local gi = rk
                if res.rack.lift ~= nil and cur.byName[res.rack.lift.bone] ~= nil then gi = cur.byName[res.rack.lift.bone].index end
                local bestK, bestD = nil, 1e9
                for k, f2 in ipairs(frames) do
                    local t, h, g = f2.bones[rk], f2[hk], f2.bones[gi]
                    if t ~= nil and h ~= nil and g ~= nil and dist(t.loc, rest[rk].loc) > 1.0 then
                        local d = dist(h.loc, g.loc)
                        if d < bestD then bestK, bestD = k, d end
                    end
                end
                if bestK ~= nil then
                    local f2 = frames[bestK]
                    res.rack.grip = packT(relT(f2.bones[rk], f2[hk]))
                    res.rack.fingers = fingerPoseAt(f2.t, hk)
                    res.rack.gripT = r3(f2.t)
                end
            end
            res.rack.every = not rec.empty -- learned from the gun's only reload variant: it racks on every reload
            -- bolt: the part is open while the item seats (bolt action: opened before the clip goes in, shut after).
            -- The weapon montage drives the bolt, its handle and any linkage outside its bone chain (the Volted Sniper's
            -- BoltArm1/2 fold with the bolt), so the manual close scrubs that montage: openPos = fully open,
            -- close = { montage time, bolt travel } from the last fully-open frame to closed (travel non-increasing).
            local seatT = res.item and res.item.seatT
            if seatT ~= nil then
                local function dk(k) local t = frames[k].bones[rk] return t and dist(t.loc, rest[rk].loc) or nil end
                local iSeat = nil
                for k, f2 in ipairs(frames) do if f2.t >= seatT - 0.001 then iSeat = k break end end
                local ds = iSeat and dk(iSeat) or 0
                if ds >= 0.5 * m.maxD then
                    local near = m.maxD - 0.15
                    local iOpen, iHold, iClosed = nil, nil, nil
                    for k = 1, #frames do local d = dk(k) if d ~= nil and d >= near then iOpen = k break end end
                    for k = iSeat, #frames do local d = dk(k) if d ~= nil and d < 0.3 then iClosed = k break end end
                    if iOpen ~= nil and iClosed ~= nil then
                        for k = iOpen, iClosed do local d = dk(k) if d ~= nil and d >= near then iHold = k end end
                    end
                    if iOpen ~= nil and iHold ~= nil and iClosed ~= nil and frames[iOpen].gpos ~= nil then
                        local tbl, minD = {}, 1e9
                        for k = iHold, iClosed do
                            local d, p = dk(k), frames[k].gpos
                            if d ~= nil and p ~= nil then
                                minD = math.min(minD, d)
                                tbl[#tbl + 1] = { p = r3(p), a = frames[k].apos and r3(frames[k].apos) or nil, d = r3(minD) }
                            end
                        end
                        if #tbl >= 2 then
                            res.rack.bolt = { openPos = r3(frames[iOpen].gpos), close = tbl,
                                              openArms = frames[iOpen].apos and r3(frames[iOpen].apos) or nil }
                        end
                    end
                end
            end
        end
    end

    -- crank (2026-11-20, Chilling Anti-Matter Plasma Rifle): after the magazine seats, the hand winds Crank_JNT from -86 to
    -- +360 deg (1.24 turns) while Gear1/Gear2/Rotator spin up to 720 deg and the Wingnut counter-turns - the ammo arrives
    -- mid-wind. A part copy cannot show the linked parts, so the wind scrubs the reload montages like the bolt action:
    -- rack.bolt = { openPos = montage time where the wind starts, close = { montage time, deg still to wind } } with
    -- rack.crank = true (manual_reload measures the hand sweep about the crank axis instead of a push along it).
    -- Candidates: rotation only (< 0.5 cm), unwrapped sweep >= CRANK_MIN_DEG in one run that starts after the item seats,
    -- frames carry the weapon montage time; the part the hands come nearest during the run wins (gears spin more, but the
    -- hand works the crank: 5.2 cm vs 12+).
    if (rec.empty or not hasEmpty) and res.rack == nil then
        local seatT = res.item and res.item.seatT or 0
        -- (the reference axis needs a real turn, >= 0.5 deg in a frame: the first tiny delta was quaternion rounding noise
        -- along (-1,1,-1)/sqrt3 - stored as the Anti-Matter crank axis, it skewed the hand sweep, 2026-11-20)
        local function unwrapped(i)
            local acc, axis, prev, out, turn = 0, nil, nil, {}, {}
            for k, f2 in ipairs(frames) do
                local t = f2.bones[i]
                if t ~= nil and prev ~= nil then
                    local qd = qmul(t.q, qconj(prev.q))
                    if qd.W < 0 then qd = { X = -qd.X, Y = -qd.Y, Z = -qd.Z, W = -qd.W } end
                    local sn = math.sqrt(qd.X * qd.X + qd.Y * qd.Y + qd.Z * qd.Z)
                    local ang = math.deg(2 * math.atan(sn, qd.W))
                    if sn > 1e-5 then
                        local ax = { X = qd.X / sn, Y = qd.Y / sn, Z = qd.Z / sn }
                        if axis == nil and ang >= 0.5 then axis = ax end
                        if axis ~= nil then
                            local sg = (ax.X * axis.X + ax.Y * axis.Y + ax.Z * axis.Z) >= 0 and 1 or -1
                            acc = acc + sg * ang
                            turn[k] = { X = ax.X * sg * ang, Y = ax.Y * sg * ang, Z = ax.Z * sg * ang }
                        end
                    end
                end
                if t ~= nil then prev = t end
                out[k] = acc
            end
            return out, axis, turn
        end
        local best = nil
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if not itemSet[b.name] and m.maxD < 0.5 and m.maxA >= RACK_MIN_DEG then
                local acc, axis, turn = unwrapped(i)
                if axis ~= nil then
                    -- the biggest sweep acc[j] - acc[i0] (either sense) with i0 < j, via running min / max
                    local iMin, iMax, bi, bj, bs = 1, 1, nil, nil, 0
                    for k = 2, #frames do
                        if acc[k] - acc[iMin] > bs then bi, bj, bs = iMin, k, acc[k] - acc[iMin] end
                        if acc[iMax] - acc[k] > bs then bi, bj, bs = iMax, k, acc[iMax] - acc[k] end
                        if acc[k] < acc[iMin] then iMin = k end
                        if acc[k] > acc[iMax] then iMax = k end
                    end
                    if bi ~= nil and bs >= CRANK_MIN_DEG then
                        local sg = acc[bj] >= acc[bi] and 1 or -1
                        -- trim the plateaus: the last frame still at the start angle, the first already at the end angle
                        -- (the Anti-Matter crank overshoots to -89 deg before it settles at -86: an exact-angle plateau
                        -- trim started the wind at 0.73 s, before the magazine came out)
                        local a0 = acc[bi]
                        local j0 = bj
                        for k = j0, bi, -1 do if (acc[k] - a0) * sg >= bs - 1 then bj = k end end
                        for k = bi, bj do if (acc[k] - a0) * sg <= 0.03 * bs then bi = k end end
                        local nearest = 1e9
                        for k = bi, bj do
                            local t, f2 = frames[k].bones[i], frames[k]
                            if t ~= nil then
                                if f2.l then nearest = math.min(nearest, dist(f2.l.loc, t.loc)) end
                                if f2.r then nearest = math.min(nearest, dist(f2.r.loc, t.loc)) end
                            end
                        end
                        if frames[bi].t >= seatT - 0.1 and frames[bi].gpos ~= nil and nearest <= 25
                            and (best == nil or nearest < best.nearest) then
                            local sum = { X = 0, Y = 0, Z = 0 }
                            for k = bi + 1, bj do
                                local tv = turn[k]
                                if tv ~= nil then sum = { X = sum.X + tv.X, Y = sum.Y + tv.Y, Z = sum.Z + tv.Z } end
                            end
                            local ra = vnorm(sum)
                            best = { i = i, acc = acc, bi = bi, bj = bj, sg = sg, nearest = nearest,
                                     axis = { X = ra.X * sg, Y = ra.Y * sg, Z = ra.Z * sg } }
                        end
                    end
                end
            end
        end
        if best ~= nil then
            local i, acc, sg = best.i, best.acc, best.sg
            -- the table ends before the ammo arrives: the finish plays the rest of the montage (a Montage_SetPosition
            -- jump would skip the notify that grants it)
            local jEnd = best.bj
            local steps = ammoSteps(frames)
            for _, st in ipairs(steps) do
                if st.t > frames[best.bi].t and st.t <= frames[jEnd].t then
                    for k = best.bi, jEnd do if frames[k].t >= st.t then jEnd = math.max(best.bi + 1, k - 2) break end end
                    break
                end
            end
            local total = (acc[jEnd] - acc[best.bi]) * sg
            local tbl, minD = {}, 1e9
            for k = best.bi, jEnd do
                local f2 = frames[k]
                if f2.gpos ~= nil then
                    minD = math.min(minD, math.max(0, total - (acc[k] - acc[best.bi]) * sg))
                    tbl[#tbl + 1] = { p = r3(f2.gpos), a = f2.apos and r3(f2.apos) or nil, d = r3(minD) }
                end
            end
            if #tbl >= 2 and total >= CRANK_MIN_DEG * 0.5 then
                local b = cur.bones[i]
                local mid = math.floor((best.bi + jEnd) / 2)
                local fr = frames[mid]
                local tm = fr.bones[i]
                local dl = fr.l and dist(fr.l.loc, tm.loc) or 1e9
                local dr = fr.r and dist(fr.r.loc, tm.loc) or 1e9
                local hk = dl <= dr and "l" or "r"
                -- linked parts: everything else that turns during the wind (the montage scrub poses them; they are not
                -- openers to flick shut)
                local linked = {}
                for i2, b2 in ipairs(cur.bones) do
                    if i2 ~= i and not itemSet[b2.name] and motion[i2].maxA >= MECH_MIN_DEG then
                        local a2 = unwrapped(i2)
                        if math.abs(a2[jEnd] - a2[best.bi]) >= MECH_MIN_DEG then linked[#linked + 1] = b2.name end
                    end
                end
                local knob = nil
                do
                    local gT = fr[hk] and relT(tm, fr[hk]) or nil
                    local fp = fingerPoseAt(fr.t, hk)
                    if gT ~= nil and type(fp) == "table" then
                        local c, n = { X = 0, Y = 0, Z = 0 }, 0
                        for name, f in pairs(fp) do
                            if name:find("2_JNT", 1, true) and f.loc ~= nil then
                                local w = qrot(gT.q, f.loc)
                                c = { X = c.X + w.X + gT.loc.X, Y = c.Y + w.Y + gT.loc.Y, Z = c.Z + w.Z + gT.loc.Z }
                                n = n + 1
                            end
                        end
                        if n > 0 then knob = { X = r3(c.X / n), Y = r3(c.Y / n), Z = r3(c.Z / n) } end
                    end
                end
                res.rack = { crank = true, knob = knob, bone = b.name, axis = { X = r3(best.axis.X), Y = r3(best.axis.Y), Z = r3(best.axis.Z) },
                             travel = r3(total), hand = hk == "l" and "left" or "right",
                             grip = fr[hk] and packT(relT(tm, fr[hk])) or nil, rest = packT(rest[i]),
                             fingers = fingerPoseAt(fr.t, hk), gripT = r3(fr.t), linked = linked,
                             pullT = r3(frames[best.bi].t), releaseT = r3(frames[jEnd].t),
                             bolt = { openPos = tbl[1].p, openArms = tbl[1].a, close = tbl },
                             every = not rec.empty }
            end
        end
    end

    -- rotary rack (2026-11-20, Rookie's Reward ChargingHandle_JNT): no sliding part, but a handle that swings about its
    -- pivot - 19.5 deg locked while empty, pulled to 42 deg after the new magazine seats, snaps home. Candidates: outside
    -- the item, rotation only (>= RACK_MIN_DEG, < 0.5 cm travel), back at rest at the end, a hand within 25 cm at the max
    -- swing, and the max swing after the item seats - a hinge / mag release opens before the item comes out (Rookie's
    -- ClipRelease_JNT 19 deg at 0.28 s, Autospray Magazine_Hinge_JNT 24 deg at 0.33 s). The biggest swing wins.
    -- Stored like a slide rack with rot = true: axis = the rotation axis (gun component space), travel / lockedDeg in deg.
    if (rec.empty or not hasEmpty) and res.rack == nil then
        local seatT = res.item and res.item.seatT
        local rk, rkA = nil, 0
        for i, b in ipairs(cur.bones) do
            local m = motion[i]
            if not itemSet[b.name] and m.maxA >= RACK_MIN_DEG and m.maxD < 0.5 and m.endRest and m.iA ~= nil
                and (seatT == nil or frames[m.iA].t >= seatT) then
                local parent = cur.byName[b.parent]
                local parentMoves = parent ~= nil and not itemSet[parent.name] and
                    (motion[parent.index].maxA >= RACK_MIN_DEG or motion[parent.index].maxD >= RACK_MIN_TRAVEL)
                local fr = frames[m.iA]
                local t = fr.bones[i]
                local dl = fr.l and dist(fr.l.loc, t.loc) or 1e9
                local dr = fr.r and dist(fr.r.loc, t.loc) or 1e9
                if not parentMoves and math.min(dl, dr) <= 25 and m.maxA > rkA then rk, rkA = i, m.maxA end
            end
        end
        if rk ~= nil then
            local m = motion[rk]
            local b = cur.bones[rk]
            local fr = frames[m.iA]
            local tMax = fr.bones[rk]
            -- component-space delta: tMax.q = qd * rest.q (the pivot stays put)
            local qd = qmul(tMax.q, qconj(rest[rk].q))
            if qd.W < 0 then qd = { X = -qd.X, Y = -qd.Y, Z = -qd.Z, W = -qd.W } end
            local axis = vnorm({ X = qd.X, Y = qd.Y, Z = qd.Z })
            local function angleOf(t) return t and qangle(t.q, rest[rk].q) or nil end
            local release = nil
            for k = m.iA, #frames do
                local a = angleOf(frames[k].bones[rk])
                if a ~= nil and a < 3 then release = frames[k].t break end
            end
            local before, displaced, lockSum = 0, 0, 0
            for k = 1, m.iA - 1 do
                local a = angleOf(frames[k].bones[rk])
                if a ~= nil then
                    before = before + 1
                    if a > 5 then displaced, lockSum = displaced + 1, lockSum + a end
                end
            end
            local lockedBack = before >= 5 and displaced >= before * 0.8
            local dl = fr.l and dist(fr.l.loc, tMax.loc) or 1e9
            local dr = fr.r and dist(fr.r.loc, tMax.loc) or 1e9
            local hk = dl <= dr and "l" or "r"
            local workHand = res.hand == "left" and "l" or (res.hand == "right" and "r" or nil)
            if workHand ~= nil and (workHand == "l" and dl or dr) <= 25 then hk = workHand end
            res.rack = { rot = true, bone = b.name, axis = { X = r3(axis.X), Y = r3(axis.Y), Z = r3(axis.Z) }, travel = r3(m.maxA),
                         lockedBack = lockedBack, lockedDeg = lockedBack and r3(lockSum / displaced) or nil,
                         pullT = r3(fr.t), releaseT = release and r3(release) or nil,
                         hand = hk == "l" and "left" or "right", grip = fr[hk] and packT(relT(tMax, fr[hk])) or nil,
                         rest = packT(rest[rk]), fingers = fingerPoseAt(fr.t, hk) }
            -- hand pose: the frame where the rack hand is nearest the handle while it is swung (> 5 deg)
            local bestK, bestD = nil, 1e9
            for k, f2 in ipairs(frames) do
                local t, h = f2.bones[rk], f2[hk]
                if t ~= nil and h ~= nil and angleOf(t) > 5 then
                    local d = dist(h.loc, t.loc)
                    if d < bestD then bestK, bestD = k, d end
                end
            end
            if bestK ~= nil then
                local f2 = frames[bestK]
                res.rack.grip = packT(relT(f2.bones[rk], f2[hk]))
                res.rack.fingers = fingerPoseAt(f2.t, hk)
                res.rack.gripT = r3(f2.t)
            end
            res.rack.every = not rec.empty
        end
    end

    -- mechanisms: other parts that open and close (hinges, gates, locks, clamps, doors)
    local skip = {}
    if res.rack then skip[res.rack.bone] = true if res.rack.lift then skip[res.rack.lift.bone] = true end end
    if res.rack and res.rack.linked then for _, n in ipairs(res.rack.linked) do skip[n] = true end end
    for i, b in ipairs(cur.bones) do
        local m = motion[i]
        if not itemSet[b.name] and not skip[b.name] and (m.maxA >= MECH_MIN_DEG or m.maxD >= MECH_MIN_CM) and m.endRest then
            local parent = cur.byName[b.parent]
            local parentMech = parent ~= nil and (motion[parent.index].maxA >= MECH_MIN_DEG or motion[parent.index].maxD >= MECH_MIN_CM)
            if not parentMech and #res.mechanisms < 16 then
                -- motion is measured from the part's pose when the reload montage starts, not the idle pose: the Beam
                -- Caster's Mag_Release_JNT sits 180 deg off its idle pose for the whole montage (a pose-basis difference
                -- between the idle and reload anims, not a swing) and passed as an opener (2026-11-19)
                -- The montage can pose the gun a frame after the recording starts (Beam Caster empty reload: frame 1 at
                -- the idle basis, frame 2 at +180), so the baseline moves past any single-frame jump > 90 deg before the
                -- ammo lands: a pose-basis snap; no animated hinge turns 90 deg in one frame.
                local base, baseK = frames[1].bones[i] or rest[i], 1
                for k = 2, #frames do
                    if frames[k].t >= steps[1].t then break end
                    local pa, pb = frames[k - 1].bones[i], frames[k].bones[i]
                    if pa ~= nil and pb ~= nil and qangle(pa.q, pb.q) > 90 then base, baseK = pb, k end
                end
                local tOpen, tClose = nil, nil
                local mA, mD, iA, iD = 0, 0, nil, nil
                for fi, fr in ipairs(frames) do
                    local t = fi >= baseK and fr.bones[i] or nil
                    if t ~= nil then
                        local d, a = dist(t.loc, base.loc), qangle(t.q, base.q)
                        if d > mD then mD, iD = d, fi end
                        if a > mA then mA, iA = a, fi end
                        if d > 0.3 or a > 3 then tOpen = tOpen or fr.t tClose = fr.t end
                    end
                end
                local key = nil
                if mA >= MECH_MIN_DEG then key = iA elseif mD >= MECH_MIN_CM then key = iD end
                if key ~= nil then
                    local mech = { bone = b.name, open = packT(relT(rest[i], frames[key].bones[i])), rest = packT(rest[i]),
                        maxDeg = r3(mA), maxCm = r3(mD), tOpen = tOpen and r3(tOpen), tClose = tClose and r3(tClose) }
                    local ta = steps[1].t
                    local carriesItem = res.item ~= nil and res.item.bone ~= nil and isAncestor(b.name, res.item.bone)
                    -- round by round, the opener may carry the rounds: the Charged Triple Barrel Shotgun's barrel_JNT
                    -- (83 deg) holds the three shell bones the shells are loaded into (2026-11-19)
                    if mA >= 30 and tOpen ~= nil and tClose ~= nil and tOpen < ta and tClose > ta and (not carriesItem or res.perRound) then
                        local fa = nil
                        for k, fr in ipairs(frames) do if fr.t >= ta - 0.001 then fa = k break end end
                        -- open when the ammo lands (the revolver cylinder is): the Beam Caster's latch is pressed at
                        -- 1.6 s and only jumps back to its idle basis after the montage ends - neither is an opening
                        if fa ~= nil and frames[fa].bones[i] ~= nil and qangle(frames[fa].bones[i].q, base.q) >= 30 then
                            mech.opener = true
                            mech.openPose = packT(frames[fa].bones[i])
                        end
                    end
                    res.mechanisms[#res.mechanisms + 1] = mech
                end
            end
        end
    end
    -- Break action, several chambers (Charged Triple Barrel Shotgun 2026-11-19): the barrel opens, the spent shells fly
    -- out, the same shell bones come back in the hand and go in one at a time - Left, Middle, Right, the k-th shell into
    -- the k-th chamber (a one-shell reload loads Left). Per count: the round bone under the opener that most recently
    -- arrived in its place relative to the opener; its seat + insert stroke are kept relative to the opener and placed
    -- at the opener's open pose (manual_reload's open copy). item.seats in loading order.
    if res.perRound and res.item ~= nil and res.item.bone ~= nil then
        local op = nil
        for _, m in ipairs(res.mechanisms) do
            if m.opener and m.openPose ~= nil and isAncestor(m.bone, res.item.bone) then op = m break end
        end
        if op ~= nil and cur.byName[op.bone] ~= nil then
            local function composeT(a, b) local l = qrot(a.q, b.loc) return { loc = { X = a.loc.X + l.X, Y = a.loc.Y + l.Y, Z = a.loc.Z + l.Z }, q = qmul(a.q, b.q) } end
            local function roundName(n)
                n = n:lower()
                return n:find("bullet", 1, true) or n:find("round", 1, true) or n:find("shell", 1, true) or n:find("cartridge", 1, true)
            end
            local oi = cur.byName[op.bone].index
            local rounds = {}
            for i, b in ipairs(cur.bones) do
                if roundName(b.name) and isAncestor(op.bone, b.name) and rest[i] ~= nil and not roundName(b.parent or "") then
                    rounds[#rounds + 1] = i
                end
            end
            local function relRest(i) return relT(rest[oi], rest[i]) end
            local function seatedAt(k, i)
                local f = frames[k]
                if f == nil or f.bones[oi] == nil or f.bones[i] == nil then return false end
                return dist(relT(f.bones[oi], f.bones[i]).loc, relRest(i).loc) < 0.5
            end
            local seats, used = {}, {}
            for _, st in ipairs(steps) do
                local ks = nil
                for k, f in ipairs(frames) do if f.t >= st.t - 0.001 then ks = k break end end
                if ks ~= nil then
                    -- the shell can seat a frame after its count (Right: counted at 2.227 s, 1.5 cm out, in at 2.25 s):
                    -- look up to 0.12 s past the count
                    local best, bestArr, bestK = nil, -1, nil
                    local kk = ks
                    while best == nil and kk <= #frames and frames[kk].t <= st.t + 0.12 do
                        for _, i in ipairs(rounds) do
                            if not used[i] and seatedAt(kk, i) then
                                local k = kk
                                while k > 1 and seatedAt(k - 1, i) do k = k - 1 end
                                if frames[k].t > bestArr then best, bestArr, bestK = i, frames[k].t, k end
                            end
                        end
                        kk = kk + 1
                    end
                    if best ~= nil then
                        used[best] = true
                        local path = strokeInto(frames, best, frames[bestK].bones[best], bestK)
                        local appRel = path ~= nil and relT(frames[bestK].bones[oi], path.approach) or relRest(best)
                        seats[#seats + 1] = { bone = cur.bones[best].name,
                            seat = packT(composeT(op.openPose, relRest(best))),
                            approach = packT(composeT(op.openPose, appRel)),
                            depth = path ~= nil and r3(path.depth) or 0 }
                    end
                end
            end
            if #seats > 0 then
                res.item.seats = seats
                res.item.seat, res.item.approach = seats[1].seat, seats[1].approach
                res.item.opener = op.bone
            end
        end
    end
    return res
end

local function mergeProfile(res)
    local p = profiles[rec.key]
    if p == nil or relearnKey == rec.key then p = { recorded = {} } end
    p.recorded = p.recorded or {}
    p.name = cur.display
    p.weaponClass = shortName(cur.weapon:get_class())
    p.mesh = fullName(meshAsset(cur.wmesh))
    pcall(function()
        p.reloadType = cur.pool.AmmoReloadType
        p.emptyReloadType = cur.pool.AmmoEmptyReloadType
        p.poolSize = cur.pool.PoolSize
        p.hasEmptyReload = cur.pool.bHasEmptyReload
    end)
    p.records = p.records or {}
    p.records[res.empty and "empty" or "tactical"] = res
    p.recorded[res.empty and "empty" or "tactical"] = os.time()
    -- the live profile: the magazine-style record wins over a prop record ("mag swap always"); rack only from empty
    -- of two prop records, the one whose prop stays in the hand: the Corrosive Shock MG's tactical reload leaves the rod
    -- ~90 cm from the hand (the arms never bring it in), the empty one carries it 9.4 cm from the hand (2026-11-19)
    local function propGap(r) local g = r and r.item and r.item.grip return g and vlen(g.loc) or 1e9 end
    local function pick(a, b)
        if a and a.style ~= "prop" then return a end
        if b and b.style ~= "prop" then return b end
        if a and b then return (propGap(b) < propGap(a)) and b or a end
        return a or b
    end
    local main = pick(p.records.tactical, p.records.empty)
    p.style, p.hand, p.item, p.fingers, p.perRound, p.pour, p.ammo = main.style, main.hand, main.item, main.fingers, main.perRound, main.pour, main.ammo
    p.feedSettle, p.feedSettleFirst = main.feedSettle, main.feedSettleFirst
    p.rack = (p.records.empty and p.records.empty.rack) or (p.records.tactical and p.records.tactical.rack) or nil
    p.mechanisms = rackMechanisms(main.mechanisms, p.rack)
    p.mirror = (p.hand == "right")
    profiles[rec.key] = p
    variantCache = {}
    saveProfiles()
    if relearnKey == rec.key then relearnKey = nil end
    return p
end

local function endRecording()
    if DUMP_FRAMES and rec ~= nil then
        pcall(function()
            local names = {}
            for i, b in ipairs(cur.bones) do names[i] = b.name end
            json.dump_file("reload_frames_" .. (rec.empty and "empty" or "tactical") .. ".json",
                { gun = cur.display, bones = names, rest = rec.rest, frames = rec.frames, fingers = rec.fingers }, 0)
        end)
    end
    local ok, res, why = pcall(analyze)
    if not ok then
        info("analysis error: " .. tostring(res))
    elseif res == nil then
        info("no profile from this reload of " .. cur.display .. ": " .. tostring(why))
    else
        local p = mergeProfile(res)
        info(cur.display .. " learned (" .. (res.empty and "empty" or "tactical") .. "): " .. profileSummary(p))
        if res.item and res.item.bone then
            detail(string.format("  item %s, grip %s via %s %.2f-%.2f s, seat %s, approach depth %s axis %s",
                res.item.bone, res.item.grip and fmtV(res.item.grip.loc) or "-", res.item.gripSource or "?",
                res.item.gripT[1], res.item.gripT[2], res.item.rest and fmtV(res.item.rest.loc) or "-",
                tostring(res.item.depth), res.item.axis and fmtV(res.item.axis) or "-"))
            if res.item.part then detail("  part " .. res.item.part.asset .. " on " .. res.item.part.socket) end
        elseif res.item and res.item.prop then
            detail("  prop " .. res.item.prop.asset .. ", dock " .. (res.item.dock and fmtV(res.item.dock.loc) or "-"))
        end
        if res.rack then
            detail(string.format("  rack %s axis %s travel %.2f lockedBack %s hand %s%s", res.rack.bone, fmtV(res.rack.axis),
                res.rack.travel, tostring(res.rack.lockedBack), res.rack.hand, res.rack.lift and (" lift " .. res.rack.lift.bone) or ""))
        end
        for _, m in ipairs(res.mechanisms) do
            detail(string.format("  mechanism %s %.1f deg %.2f cm open %s-%s", m.bone, m.maxDeg, m.maxCm, tostring(m.tOpen), tostring(m.tClose)))
        end
        detail("  ammo at " .. table.concat(res.ammo, ", ") .. (res.perRound and " (per round)" or "") .. (res.pour and " (pour)" or ""))
    end
    rec = nil
    updateStatus()
end

-- -------------------------------------------------------------------------------------------------------------------
-- tick
-- -------------------------------------------------------------------------------------------------------------------
uevrUtils.registerPreEngineTickCallback(function(engine, delta)
    clock = clock + (delta or 0)
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return end
    local weapon = nil
    pcall(function() weapon = pawn:GetCurrentWeapon() end)
    if weapon == nil then
        if rec ~= nil then rec = nil end
        if cur ~= nil then cur = nil updateStatus() end
        return
    end
    if cur == nil or cur.weapon ~= weapon then
        rec = nil
        local melee = false
        pcall(function() melee = weapon.WeaponCategory.TagName:to_string():find("Melee", 1, true) ~= nil end)
        if melee then
            if cur ~= nil then cur = nil end
            setStatus("melee weapon")
            return
        end
        setupWeapon(pawn, weapon)
        if cur == nil then return end
    end
    if rec ~= nil then
        local ok, err = pcall(recordFrame)
        if not ok then info("record error: " .. tostring(err)) rec = nil updateStatus() return end
        if rec.fired or clock - rec.lastActive > END_TAIL then endRecording() end
        return
    end
    local clip = getClip()
    local reloading = isReloading()
    if reloading ~= cur.lastReloading then
        cur.lastReloading = reloading
        detail("reload state " .. tostring(reloading) .. ", clip " .. tostring(clip) .. ", needs recording " .. tostring(needsRecording(clip)))
    end
    if not needsRecording(clip) then return end
    if reloading then
        startRecording()
        pcall(recordFrame)
        return
    end
    -- idle: keep the rest pose current (only while the clip is not empty: an empty pistol locks its slide back)
    if clock >= cur.nextRest and clip ~= nil and clip > 0 and activeMontage(cur.wmesh) == nil then
        cur.nextRest = clock + REST_REFRESH
        cur.rest = readBones(cur.wmesh, cur.bones)
    end
end)

uevrUtils.registerPreLevelChangeCallback(function()
    rec, cur = nil, nil
    keyCache = {}
    variantCache = {}
end)

configui.onUpdate("mr_auto_relearn", function()
    uevrUtils.setTimeout(1, function()
        if cur == nil or cur.key == nil then setStatus("no gun") return end
        relearnKey = cur.key
        setStatus(cur.display .. ": re-learning - do a normal reload (with rounds left, then from empty)")
        info("re-learn requested for " .. cur.key)
    end)
end)

_G.ow2ReloadAnalyzer = {
    getProfile = getProfile,
    keyFor = keyFor,
    isRecording = function() return rec ~= nil end,
    -- does the analyzer still want the reload that is starting on the held gun (not learned / empty variant missing /
    -- re-learn pending)? manual_reload.lua asks this before catching a reload: a reload starts during the engine
    -- tick, after this script's pre-engine check, so "isRecording" is one frame late
    wantsReload = function()
        if rec ~= nil then return true end
        if cur == nil then return false end
        return needsRecording(getClip())
    end,
    relearn = function() if cur ~= nil then relearnKey = cur.key end end,
    profiles = function() return profiles end,
}

info("loaded, " .. (function() local n = 0 for _ in pairs(profiles) do n = n + 1 end return n end)() .. " gun profiles")
