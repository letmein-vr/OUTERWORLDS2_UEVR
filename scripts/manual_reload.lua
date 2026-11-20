-- Manual reload for The Outer Worlds 2 (2026-11-19), driven by the automatic per-gun analysis in reload_analyzer.lua
-- (data/manual_reload_auto.json) - no per-weapon tuning. Port of Hellraiser's scripts/manual_reload.lua.
--
-- Flow (2026-11-19: the game's reload button ejects, mag swap always):
--   1. The game's reload starts: its arm + weapon montages are caught near frame 0 and held paused (the game stays in
--      its reload state, so nothing fires mid-reload). The real magazine hides; a copy of it drops out of the gun.
--   2. A copy of the gun's own magazine sits in a pouch at the left hip; take it with the left grip. It sits in the
--      visible left hand exactly as in the game's own reload (the learned grip on l_hand_JNT, glove or IK rig), with the
--      game's finger pose.
--   3. Bring it to the magazine well: once close it glides onto the learned insert stroke and seats.
--   4. After an empty magazine with a learned rack part (slide / lever / bolt): pull it back along its learned axis and
--      let go. The part shows locked back while empty when the game does that.
--   5. The paused native reload runs on at high speed - the game moves the ammo from inventory into the clip itself.
-- A gun without a profile (or without its empty-reload recording yet) reloads natively so the analyzer can learn it.
-- First version: item-style reloads carried by the left hand (magazines, battery, speedloader, clip, rocket). Round by
-- round, prop (cell / canister / rod) and right-hand guns reload natively for now.

local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require('libs/configui')
local animation = require('libs/animation')
local hands = nil
pcall(function() hands = require('libs/hands') end)
local ik = nil
pcall(function() ik = require('libs/ik') end)

local vr = uevr.params.vr

local BTN_LB = 0x0100        -- left grip (raw, before controls.lua's LB/LT swap)
local RTS_COMPONENT = 2
local BONE_SPACE_COMPONENT = 1
local HAND_BONE = "l_hand_JNT"
local LATE_CATCH_S = 0.15    -- a reload montage further along than this is left to the game (pistol mag leaves 0.16 s)
local SHOW_AFTER_S = 0.06    -- new copies stay hidden until placed (first frames render at the origin)
local FINISH_TIMEOUT_S = 3.0

_G.OW2_SECTIONS = _G.OW2_SECTIONS or {}
table.insert(_G.OW2_SECTIONS, { order = 2.8, label = "Manual Reload", layout = {
    { widgetType = "checkbox", id = "mr_enabled", label = "Manual reload (reload button drops the magazine, take a new one from the left hip and push it in)", initialValue = true },
    { widgetType = "checkbox", id = "mr_rack", label = "Rack the slide / charging handle / crank after an empty magazine", initialValue = true },
    { widgetType = "text", id = "mr_status", label = "Manual reload: -" },
    { widgetType = "drag_float3", id = "mr_pouch_loc", label = "Hip pouch position (cm from the HMD: forward / right / up, body facing)", initialValue = { 8.0, -24.0, -58.0 }, range = {-120, 120}, speed = 0.5 },
    { widgetType = "slider_float", id = "mr_grab_radius", label = "Grab: hand within (cm of the pouch)", initialValue = 13.0, range = {4.0, 30.0} },
    { widgetType = "slider_float", id = "mr_insert_radius", label = "Insert: magazine within (cm of the well)", initialValue = 7.0, range = {2.0, 20.0} },
    { widgetType = "slider_float", id = "mr_rack_radius", label = "Rack: hand within (cm of the slide)", initialValue = 10.0, range = {3.0, 25.0} },
    { widgetType = "slider_float", id = "mr_rack_done", label = "Rack: pull at least (fraction of the travel)", initialValue = 0.8, range = {0.3, 1.0} },
    { widgetType = "slider_float", id = "mr_grab_glide", label = "Pouch to hand glide time (s)", initialValue = 0.10, range = {0.0, 0.5} },
    { widgetType = "slider_float", id = "mr_insert_time", label = "Insert glide time (s)", initialValue = 0.15, range = {0.03, 0.6} },
    { widgetType = "slider_float", id = "mr_finish_rate", label = "Native reload fast-forward rate", initialValue = 20.0, range = {2.0, 40.0} },
    { widgetType = "slider_float", id = "mr_feed_rate", label = "Round-by-round: native reload rate while one round goes in", initialValue = 10.0, range = {2.0, 20.0} },
    { widgetType = "slider_float", id = "mr_round_insert_radius", label = "Round-by-round: insert radius (cm, any side of the stroke)", initialValue = 12.0, range = {3.0, 25.0} },
    { widgetType = "slider_float", id = "mr_pour_rate", label = "Canister: native reload rate while it pours", initialValue = 3.0, range = {1.0, 10.0} },
    { widgetType = "slider_float", id = "mr_prop_dock_down", label = "Canister: dock lower than the game's (cm, along the gun's up)", initialValue = 5.0, range = {-10.0, 20.0} },
    { widgetType = "checkbox", id = "mr_fingers", label = "Left hand takes the game's finger pose on the magazine", initialValue = true },
    { widgetType = "slider_float", id = "mr_finger_blend", label = "Finger pose blend time (s)", initialValue = 0.2, range = {0.0, 0.8} },
    { widgetType = "checkbox", id = "mr_flick_close", label = "Flick the gun to close a swung-out cylinder / barrel (off = closes by itself)", initialValue = true },
    { widgetType = "slider_float", id = "mr_flick_speed", label = "Flick: gun speed at least (cm/s)", initialValue = 110.0, range = {40.0, 400.0} },
    { widgetType = "checkbox", id = "mr_haptics", label = "Haptics", initialValue = true },
    { widgetType = "checkbox", id = "mr_log", label = "Log to log.txt", initialValue = false },
}})

-- -------------------------------------------------------------------------------------------------------------------
-- helpers
-- -------------------------------------------------------------------------------------------------------------------
local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end
local function cfgVec(id, default)
    local v = configui.getValue(id)
    if type(v) == "table" or type(v) == "userdata" then
        local ok, x, y, z = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
    end
    return default[1], default[2], default[3]
end
local function log(s)
    if configui.getValue("mr_log") == true then pcall(function() uevr.params.functions.log_info("[manual_reload] " .. s) end) end
end
local function info(s) pcall(function() uevr.params.functions.log_info("[manual_reload] " .. s) end) end
local lastStatus = nil
local function status(s)
    if s == lastStatus then return end
    lastStatus = s
    pcall(function() configui.setLabel("mr_status", "Manual reload: " .. s) end)
end
local function haptic(duration, amplitude)
    if configui.getValue("mr_haptics") == false then return end
    pcall(function() vr.trigger_haptic_vibration(0, duration, 1.0, amplitude, vr.get_left_joystick_source()) end)
end
local function exists(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return UEVR_UObjectHook.exists(obj) end)
    return ok and r == true
end
local function addr(obj)
    if obj == nil then return nil end
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or nil
end
local function fname(s) return uevrUtils.fname_from_string(s) end
local function vec(x, y, z) return uevrUtils.vector(x, y, z) end

-- transforms as { loc = {X,Y,Z}, q = {X,Y,Z,W} } (UE quaternion convention)
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
local function addV(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
local function subV(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function mulV(a, s) return { X = a.X * s, Y = a.Y * s, Z = a.Z * s } end
local function dotV(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function lenV(a) return math.sqrt(dotV(a, a)) end
local function compose(a, b) return { loc = addV(a.loc, qrot(a.q, b.loc)), q = qmul(a.q, b.q) } end
local function inv(a) local c = qconj(a.q) return { loc = qrot(c, mulV(a.loc, -1)), q = c } end
local IDENT = { loc = { X = 0, Y = 0, Z = 0 }, q = { X = 0, Y = 0, Z = 0, W = 1 } }
local function nlerpQ(a, b, t)
    local d = a.X * b.X + a.Y * b.Y + a.Z * b.Z + a.W * b.W
    local s = d < 0 and -1 or 1
    local q = { X = a.X + (s * b.X - a.X) * t, Y = a.Y + (s * b.Y - a.Y) * t, Z = a.Z + (s * b.Z - a.Z) * t, W = a.W + (s * b.W - a.W) * t }
    local l = math.sqrt(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W)
    return { X = q.X / l, Y = q.Y / l, Z = q.Z / l, W = q.W / l }
end
local function lerpT(a, b, t) return { loc = addV(a.loc, mulV(subV(b.loc, a.loc), t)), q = nlerpQ(a.q, b.q, t) } end
local function q2r(q)
    local sing = q.Z * q.X - q.W * q.Y
    local yawY = 2 * (q.W * q.Z + q.X * q.Y)
    local yawX = 1 - 2 * (q.Y * q.Y + q.Z * q.Z)
    local yaw = math.deg(math.atan(yawY, yawX))
    if sing < -0.4999995 then
        return { Pitch = -90, Yaw = yaw, Roll = -yaw - 2 * math.deg(math.atan(q.X, q.W)) }
    elseif sing > 0.4999995 then
        return { Pitch = 90, Yaw = yaw, Roll = yaw - 2 * math.deg(math.atan(q.X, q.W)) }
    end
    return { Pitch = math.deg(math.asin(2 * sing)), Yaw = yaw,
             Roll = math.deg(math.atan(-2 * (q.W * q.X + q.Y * q.Z), 1 - 2 * (q.X * q.X + q.Y * q.Y))) }
end
local function fromUE(t)
    return { loc = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
             q = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W } }
end
local function fromProfile(p)
    if p == nil then return nil end
    return { loc = { X = p.loc.X, Y = p.loc.Y, Z = p.loc.Z }, q = { X = p.q.X, Y = p.q.Y, Z = p.q.Z, W = p.q.W } }
end
-- a right-hand grip as a left-hand one: mirrored across the gun's XZ plane
local function mirrorT(t) return { loc = { X = t.loc.X, Y = -t.loc.Y, Z = t.loc.Z }, q = { X = -t.q.X, Y = t.q.Y, Z = -t.q.Z, W = t.q.W } } end
local function ueTransform(t)
    local r = q2r(t.q)
    return kismet_math_library:MakeTransform(vec(t.loc.X, t.loc.Y, t.loc.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), vec(1, 1, 1))
end
local function setRelative(comp, t)
    local r = q2r(t.q)
    comp:K2_SetRelativeLocationAndRotation(vec(t.loc.X, t.loc.Y, t.loc.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), false, reusable_hit_result, true)
end
local function setWorld(comp, t)
    local r = q2r(t.q)
    comp:K2_SetWorldLocationAndRotation(vec(t.loc.X, t.loc.Y, t.loc.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), false, reusable_hit_result, true)
end
local function worldOf(comp) return fromUE(comp:K2_GetComponentToWorld()) end
local function smooth(t) return t * t * (3 - 2 * t) end

local function blocked()
    if _G.ow2IsMenuOpen ~= nil and _G.ow2IsMenuOpen() then return "menu" end
    if uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_input_disabled") == true then return "cutscene" end
    local world = uevrUtils.get_world()
    if world ~= nil and Statics ~= nil and Statics:IsGamePaused(world) == true then return "paused" end
    return nil
end

local function meshAsset(comp)
    local a = nil
    pcall(function() a = comp.SkeletalMesh end)
    if a == nil then pcall(function() a = comp.SkinnedAsset end) end
    if a == nil then pcall(function() a = comp.StaticMesh end) end
    return a
end
local function fullName(obj)
    if obj == nil then return "-" end
    local ok, s = pcall(function() return obj:get_full_name() end)
    return ok and s or "-"
end
local function children(comp)
    local out = {}
    pcall(function()
        local c = comp.AttachChildren
        for i = 1, #c do if c[i] ~= nil then out[#out + 1] = c[i] end end
    end)
    return out
end

-- the visible left hand: the glove (Hands mode) or the IK rig (IK mode); both copy FPVMesh and carry l_hand_JNT
local function leftHandMesh()
    -- IK mode first: the hands library's glove can still exist (hidden) in IK mode, and the finger pose went onto it
    -- while the visible IK arms kept their own pose (Holographic Repeating Rifle 2026-11-19: index bent 52 deg on the
    -- visible hand vs 149 deg in the pose, "fingers stay open")
    if _G.getHandsMode ~= nil and _G.getHandsMode() == 2 and ik ~= nil then
        local rig = nil
        pcall(function() rig = ik.getCurrentMesh(1) end)
        if exists(rig) then return rig end
    end
    local pmc = nil
    pcall(function() pmc = hands.getHandComponent(Handed.Left) end)
    if exists(pmc) then return pmc end
    return nil
end

-- -------------------------------------------------------------------------------------------------------------------
-- right-hand guns: the game's right-hand pose mirrored onto the left hand (2026-11-19)
-- A left hand bone frame is the right one mirrored across the body plane with some of its own axes flipped:
-- L = M * R * F (M = mirror Y, F = diagonal +-1, det -1). F is read off the arms skeleton: a finger's offset inside
-- its hand frame is a constant of the rig, so left offsets = F * right offsets (Middle1, Thumb1, Pinky1, Index1).
-- -------------------------------------------------------------------------------------------------------------------
local function q2m(q)
    local x, y, z, w = q.X, q.Y, q.Z, q.W
    return {
        { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w) },
        { 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w) },
        { 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y) },
    }
end
local function m2q(m)
    local tr = m[1][1] + m[2][2] + m[3][3]
    local q
    if tr > 0 then
        local S = math.sqrt(tr + 1.0) * 2
        q = { W = 0.25 * S, X = (m[3][2] - m[2][3]) / S, Y = (m[1][3] - m[3][1]) / S, Z = (m[2][1] - m[1][2]) / S }
    elseif m[1][1] > m[2][2] and m[1][1] > m[3][3] then
        local S = math.sqrt(1.0 + m[1][1] - m[2][2] - m[3][3]) * 2
        q = { W = (m[3][2] - m[2][3]) / S, X = 0.25 * S, Y = (m[1][2] + m[2][1]) / S, Z = (m[1][3] + m[3][1]) / S }
    elseif m[2][2] > m[3][3] then
        local S = math.sqrt(1.0 + m[2][2] - m[1][1] - m[3][3]) * 2
        q = { W = (m[1][3] - m[3][1]) / S, X = (m[1][2] + m[2][1]) / S, Y = 0.25 * S, Z = (m[2][3] + m[3][2]) / S }
    else
        local S = math.sqrt(1.0 + m[3][3] - m[1][1] - m[2][2]) * 2
        q = { W = (m[2][1] - m[1][2]) / S, X = (m[1][3] + m[3][1]) / S, Y = (m[2][3] + m[3][2]) / S, Z = 0.25 * S }
    end
    local l = math.sqrt(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W)
    return { X = q.X / l, Y = q.Y / l, Z = q.Z / l, W = q.W / l }
end
-- rows scaled by a (left diagonal), columns scaled by b (right diagonal)
local function diagMul(a, m, b)
    local r = {}
    for i = 1, 3 do r[i] = {} for j = 1, 3 do r[i][j] = a[i] * m[i][j] * b[j] end end
    return r
end

local mirrorF = nil -- { fx, fy, fz } or false (could not be read)
local FINGER_PROBES = { "Middle1", "Thumb1", "Pinky1", "Index1" }
-- The axis convention is a property of the skeleton, so it is read from the reference pose: the finger roots are direct
-- children of the hand bones, and their ref-pose local positions are hand-relative and pose independent. The animated
-- pose (the fallback below) depends on what both hands are doing when the reload is caught - 1.60 cm on the Holographic
-- Repeating Rifle, over the 1.5 cm limit, and that "false" was cached for the session: every right-hand gun lost its
-- finger pose and got the approximate grip (2026-11-19, "fingers stay open").
local REF_PROBES = { "IndexRoot", "MiddleRoot", "RingRoot", "PinkyRoot", "Thumb1" }
local function mirrorFFromRefPose(arms)
    local acc = { 0, 0, 0 }
    local pairs_ = {}
    for _, n in ipairs(REF_PROBES) do
        local il = arms:GetBoneIndex(fname("LeftHand" .. n .. "_JNT"))
        local ir = arms:GetBoneIndex(fname("RightHand" .. n .. "_JNT"))
        if il ~= nil and ir ~= nil and il >= 0 and ir >= 0
            and arms:GetParentBone(fname("LeftHand" .. n .. "_JNT")):to_string() == "l_hand_JNT"
            and arms:GetParentBone(fname("RightHand" .. n .. "_JNT")):to_string() == "r_hand_JNT" then
            local l, r = arms:GetRefPosePosition(il), arms:GetRefPosePosition(ir)
            l, r = { X = l.X, Y = l.Y, Z = l.Z }, { X = r.X, Y = r.Y, Z = r.Z }
            acc[1], acc[2], acc[3] = acc[1] + l.X * r.X, acc[2] + l.Y * r.Y, acc[3] + l.Z * r.Z
            pairs_[#pairs_ + 1] = { l = l, r = r }
        end
    end
    if #pairs_ < 3 then return nil end
    local F = { acc[1] >= 0 and 1 or -1, acc[2] >= 0 and 1 or -1, acc[3] >= 0 and 1 or -1 }
    local err = 0
    for _, p in ipairs(pairs_) do
        err = math.max(err, lenV(subV(p.l, { X = F[1] * p.r.X, Y = F[2] * p.r.Y, Z = F[3] * p.r.Z })))
    end
    info(string.format("mirror axes F = (%d, %d, %d) from the ref pose (%d probes), fit error %.2f cm", F[1], F[2], F[3], #pairs_, err))
    if err > 0.5 or F[1] * F[2] * F[3] ~= -1 then return nil end
    return F
end

-- Every finger bone has its OWN axis flip: L_bone = M * R_bone * F_bone, and the left index root's is (-1,-1,-1) while
-- the hand's is (1,-1,1). A hand-relative transform mirrors as rel_L = F_hand * rel_R * F_bone; using F_hand on both
-- sides reversed the bend axis of those bones and the index / middle fingers folded back into the wrist (2026-11-19).
-- F_bone comes from the reference pose, parent first: local_L = F_parent * local_R * F_bone, so
-- F_bone = local_R^T * F_parent * local_L (rounded to a +-1 diagonal).
local boneFlip = nil -- left bone name -> { fx, fy, fz }
local function computeBoneFlips(arms, F)
    local out = { l_hand_JNT = F }
    local n = arms:GetNumBones()
    for i = 0, n - 1 do -- bone indices are parent-first
        local lf = arms:GetBoneName(i)
        local lname = lf:to_string()
        if lname:find("^LeftHand") or (lname:find("^l_") and lname ~= "l_hand_JNT") then
            local parent = arms:GetParentBone(lf):to_string()
            local Fp = out[parent]
            if Fp ~= nil then
                local rname = lname:gsub("^LeftHand", "RightHand"):gsub("^l_", "r_")
                local ir = arms:GetBoneIndex(fname(rname))
                if ir ~= nil and ir >= 0 then
                    local L, R = arms:GetRefPoseTransform(i), arms:GetRefPoseTransform(ir)
                    local mL = q2m({ X = L.Rotation.X, Y = L.Rotation.Y, Z = L.Rotation.Z, W = L.Rotation.W })
                    local mR = q2m({ X = R.Rotation.X, Y = R.Rotation.Y, Z = R.Rotation.Z, W = R.Rotation.W })
                    -- F_bone[j][j] = sum_k mR[k][j] * Fp[k] * mL[k][j]
                    local fb, ok = {}, true
                    for j = 1, 3 do
                        local d = 0
                        for k = 1, 3 do d = d + mR[k][j] * Fp[k] * mL[k][j] end
                        if math.abs(math.abs(d) - 1) > 0.1 then ok = false end
                        fb[j] = d >= 0 and 1 or -1
                    end
                    if ok and fb[1] * fb[2] * fb[3] == -1 then out[lname] = fb end
                end
            end
        end
    end
    local c, diff = 0, 0
    for name, fb in pairs(out) do
        c = c + 1
        if fb[1] ~= F[1] or fb[2] ~= F[2] or fb[3] ~= F[3] then diff = diff + 1 end
    end
    info(string.format("finger bone flips from the ref pose: %d bones, %d differ from the hand's", c, diff))
    return out
end

local function computeMirrorF(arms)
    if mirrorF then
        if boneFlip == nil then pcall(function() boneFlip = computeBoneFlips(arms, mirrorF) end) end
        return mirrorF
    end -- a failed fit is not cached: it is tried again on the next reload
    local okRef, F = pcall(mirrorFFromRefPose, arms)
    if okRef and F ~= nil then
        mirrorF = F
        local okB, res = pcall(computeBoneFlips, arms, F)
        if okB then boneFlip = res else info("finger bone flips: " .. tostring(res)) end
        return mirrorF
    end
    if not okRef then info("mirror axes from the ref pose: " .. tostring(F)) end
    local ok, res = pcall(function()
        local hr = fromUE(arms:GetSocketTransform(fname("r_hand_JNT"), RTS_COMPONENT))
        local hl = fromUE(arms:GetSocketTransform(fname("l_hand_JNT"), RTS_COMPONENT))
        local acc = { 0, 0, 0 }
        local pairs_ = {}
        for _, n in ipairs(FINGER_PROBES) do
            local r = compose(inv(hr), fromUE(arms:GetSocketTransform(fname("RightHand" .. n .. "_JNT"), RTS_COMPONENT))).loc
            local l = compose(inv(hl), fromUE(arms:GetSocketTransform(fname("LeftHand" .. n .. "_JNT"), RTS_COMPONENT))).loc
            acc[1], acc[2], acc[3] = acc[1] + l.X * r.X, acc[2] + l.Y * r.Y, acc[3] + l.Z * r.Z
            pairs_[#pairs_ + 1] = { l = l, r = r }
        end
        local F = { acc[1] >= 0 and 1 or -1, acc[2] >= 0 and 1 or -1, acc[3] >= 0 and 1 or -1 }
        local err = 0
        for _, p in ipairs(pairs_) do
            err = math.max(err, lenV(subV(p.l, { X = F[1] * p.r.X, Y = F[2] * p.r.Y, Z = F[3] * p.r.Z })))
        end
        info(string.format("mirror axes F = (%d, %d, %d), fit error %.2f cm", F[1], F[2], F[3], err))
        if err > 1.5 or F[1] * F[2] * F[3] ~= -1 then return false end
        return F
    end)
    mirrorF = ok and res or false
    return mirrorF
end

-- a right-hand bone pose in the gun frame -> the left hand's, mirrored across the gun plane y = planeY
local function mirrorHandInGun(H, planeY, F)
    local loc = { X = H.loc.X, Y = 2 * planeY - H.loc.Y, Z = H.loc.Z }
    return { loc = loc, q = m2q(diagMul({ 1, -1, 1 }, q2m(H.q), F)) }
end

-- a right-hand finger pose (hand-relative, RightHand* bones) -> the left hand's
local function mirrorFingers(pose, F)
    if pose == nil or not F then return nil end
    local out = {}
    for name, T in pairs(pose) do
        local t = fromProfile(T)
        local lname = name:gsub("^RightHand", "LeftHand"):gsub("^r_", "l_")
        local Fb = (boneFlip ~= nil and boneFlip[lname]) or F
        local m = diagMul(F, q2m(t.q), Fb)
        out[lname] = { loc = { X = F[1] * t.loc.X, Y = F[2] * t.loc.Y, Z = F[3] * t.loc.Z }, q = m2q(m) }
    end
    return out
end

local function spareAmmo(pawn, weapon)
    local n = nil
    pcall(function()
        local cls = weapon:GetAmmoPool():GetCurrentAmmoClass()
        local inv_ = uevrUtils.find_default_instance("Class /Script/Arkansas.InventoryComponent")
        n = inv_:GetItemCountOnActor(pawn, cls)
    end)
    return n
end

-- -------------------------------------------------------------------------------------------------------------------
-- copies of the magazine (proxy): the gun's own magazine part, or a poseable copy of the gun with only the item bones
-- Copies are tracked by their own reference (p.comp nil once destroyed or after a level change), never by
-- UEVR_UObjectHook.exists: a component created this moment can read "not alive" until the backend has registered it,
-- and the next tick then dropped it - the heavy MG's ejected magazine vanished instead of falling (2026-11-19).
-- proxy = { comp, kind, atRest (component pose in gun space while the item sits at rest), created, shown }
-- -------------------------------------------------------------------------------------------------------------------
local proxies = {}

-- poseable bone isolation (Hellraiser applyPart): the root collapses to 0.001 at the kept bone, the kept bone keeps
-- its component-space transform, its children keep theirs (absolute component-space writes = idempotent)
-- p.subs: one poseable per mesh that may carry the bone's geometry (the gun + its leader-posed skeletal mod parts:
-- the rocket pistol's rocket lives in MOD_P_Breech_Base, 2026-11-19); meshes without that geometry show nothing
local function applyIsolation(p)
    local tiny = vec(0.001, 0.001, 0.001)
    for _, sub in ipairs(p.subs or {}) do
        if sub.comp ~= nil then
            local r = q2r(sub.rootT.q)
            sub.comp:SetBoneTransformByName(fname(sub.rootBone), kismet_math_library:MakeTransform(vec(p.boneT.loc.X, p.boneT.loc.Y, p.boneT.loc.Z),
                uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), tiny), BONE_SPACE_COMPONENT)
            sub.comp:SetBoneTransformByName(fname(p.bone), ueTransform(p.boneT), BONE_SPACE_COMPONENT)
        end
    end
end

-- the gun's skeletal meshes: the weapon mesh + leader-posed skeletal mod parts (attached without a socket)
local function gunSkeletalMeshes(gun)
    local out = { gun }
    for _, c in ipairs(children(gun)) do
        local isSk, socket = false, "x"
        pcall(function() isSk = c:get_class():get_fname():to_string():find("SkeletalMesh", 1, true) ~= nil end)
        pcall(function() socket = c.AttachSocketName:to_string() end)
        if isSk and socket == "None" then out[#out + 1] = c end
    end
    return out
end

-- hide / unhide a bone on every skeletal mesh of the real gun (recorded for unhideReal)
-- the gun's parts mounted on sockets of `bone` or of a bone below it: { comp, socket, bone }
-- (Charged Triple Barrel Shotgun 2026-11-19: every shell is a static mesh on a shell-bone socket - hiding the bone
-- only hides skinned geometry, the shells stayed)
local function socketPartsUnder(gun, bone)
    local out = {}
    local bf = fname(bone)
    for _, c in ipairs(children(gun)) do
        pcall(function()
            local socket = c.AttachSocketName:to_string()
            if socket == "None" then return end
            local sbf = gun:GetSocketBoneName(c.AttachSocketName)
            local sb = sbf:to_string()
            if sb == bone or gun:BoneIsChildOf(sbf, bf) then out[#out + 1] = { comp = c, socket = socket, bone = sb } end
        end)
    end
    return out
end

local function hideGunBone(gun, bone, store)
    for _, m in ipairs(gunSkeletalMeshes(gun)) do
        pcall(function() m:HideBoneByName(fname(bone), 0) end)
        store[#store + 1] = { c = m, b = bone }
    end
    for _, part in ipairs(socketPartsUnder(gun, bone)) do
        pcall(function() part.comp:SetHiddenInGame(true, true) end)
        store[#store + 1] = { part = part.comp }
    end
end

local function proxyBoneVisible(p, bone, visible)
    for _, sub in ipairs(p.subs or { { comp = p.comp } }) do
        pcall(function()
            if visible then sub.comp:UnHideBoneByName(fname(bone)) else sub.comp:HideBoneByName(fname(bone), 0) end
        end)
    end
    for _, part in ipairs(p.parts or {}) do
        if part.anc[bone] then pcall(function() part.comp:SetVisibility(visible, true) end) end
    end
end

local function newProxy(comp, kind, atRest)
    pcall(function() comp:SetVisibility(false, true) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:SetCollisionEnabled(0) end)
    local p = { comp = comp, kind = kind, atRest = atRest or IDENT, created = os.clock(), shown = false }
    proxies[#proxies + 1] = p
    return p
end

-- poseable copies of the gun's skeletal meshes showing only bone's subtree (boneT: its component-space pose); fills
-- p.bone / p.boneT / p.rootBone / p.rootT / p.subs and returns the main poseable component
local function buildIsolation(p, gun, bone, boneT, noParts)
    local comp = uevrUtils.createPoseableMeshFromSkeletalMesh(gun, { useDefaultPose = true })
    if comp == nil then return nil end
    pcall(function() comp:SetVisibility(false, true) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:SetCollisionEnabled(0) end)
    p.bone = bone
    p.rootBone = gun:GetBoneName(0):to_string()
    p.boneT = boneT or fromUE(gun:GetSocketTransform(fname(bone), RTS_COMPONENT))
    p.rootT = fromUE(gun:GetSocketTransform(fname(p.rootBone), RTS_COMPONENT))
    p.subs = { { comp = comp, rootBone = p.rootBone, rootT = p.rootT } }
    for i, m in ipairs(gunSkeletalMeshes(gun)) do
        if i > 1 then
            pcall(function()
                local extra = uevrUtils.createPoseableMeshFromSkeletalMesh(m, { useDefaultPose = true })
                if extra == nil then return end
                pcall(function() extra:SetVisibility(false, true) end)
                pcall(function() extra:SetCastShadow(false) end)
                extra:K2_AttachToComponent(comp, fname(""), 2, 2, 2, false)
                local rb = m:GetBoneName(0):to_string()
                p.subs[#p.subs + 1] = { comp = extra, rootBone = rb, rootT = fromUE(m:GetSocketTransform(fname(rb), RTS_COMPONENT)) }
            end)
        end
    end
    -- the parts on sockets in the kept subtree (shells, barrel mods): copies on the same sockets of the copy
    p.parts = {}
    -- (noParts: this isolation rides a copy of the part itself - the Charged Triple Barrel Shotgun's hip shell showed
    -- twice, 2026-11-19)
    for _, part in ipairs(noParts and {} or socketPartsUnder(gun, bone)) do
        pcall(function()
            local c = part.comp
            if not c:get_class():get_fname():to_string():find("StaticMesh", 1, true) then return end
            local copy = uevrUtils.createStaticMeshComponent(meshAsset(c))
            if copy == nil then return end
            pcall(function() uevrUtils.copyMaterials(c, copy) end)
            pcall(function() copy:SetCastShadow(false) end)
            pcall(function() copy:SetCollisionEnabled(0) end)
            copy:K2_AttachToComponent(comp, fname(part.socket), 2, 2, 2, false)
            pcall(function() copy:K2_SetRelativeLocationAndRotation(c.RelativeLocation, c.RelativeRotation, false, reusable_hit_result, true) end)
            pcall(function() copy:SetRelativeScale3D(c.RelativeScale3D) end)
            local anc, name = {}, part.bone
            while name ~= nil and name ~= "None" and name ~= "" do
                anc[name] = true
                local nxt = nil
                pcall(function() nxt = gun:GetParentBone(fname(name)):to_string() end)
                name = nxt
            end
            p.parts[#p.parts + 1] = { comp = copy, bone = part.bone, anc = anc }
        end)
    end
    p.nextApply = 0
    pcall(applyIsolation, p)
    return comp
end

-- item: profile.item; gun: the live weapon mesh; boneOverride: isolate this bone instead (rack part), built at
-- restOverride (the learned rest: the paused gun may already hold the part locked back)
-- withSkin: the item bone's own skinned geometry is drawn on the real gun (hideRealItem hides that bone too), so a
-- part copy also carries it - the Kinetic Beam Caster's glass battery casing is skinned to Battery_JNT in the gun mesh,
-- its plasma core is the static part (2026-11-19). The copy shows what the hide removes.
-- a hand prop's mesh asset (Charged Bio-Mass Shotgun: the goo canister the game spawns on the left hand while it reloads)
local propAssets = {}
local function propAsset(item)
    local name = item.prop and item.prop.asset
    if name == nil then return nil end
    if propAssets[name] == nil then
        local a = nil
        pcall(function() a = uevr.api:find_uobject(name) end)
        propAssets[name] = a or false
    end
    return propAssets[name] or nil
end

-- the item pose a copy is placed by: the learned rest of the item bone, identity for a hand prop
local function itemRestT(item) return fromProfile(item.rest) or IDENT end

local function createProxy(gun, item, boneOverride, restOverride, withSkin)
    local p = nil
    if boneOverride == nil and item.prop ~= nil then
        local asset = propAsset(item)
        local comp = nil
        if asset ~= nil then
            -- the Shock MG's rod is a skeletal mesh, the goo canister a static one
            if (item.prop.cls or ""):find("Skeletal", 1, true) then comp = uevrUtils.createSkeletalMeshComponent(asset)
            else comp = uevrUtils.createStaticMeshComponent(asset) end
        end
        if comp ~= nil then p = newProxy(comp, "static", IDENT) end
        return p
    end
    local ok, err = pcall(function()
        if boneOverride == nil and item.part ~= nil then
            -- find the live part (its asset carries the mod's materials) - on the learned socket too: the Charged Triple
            -- Barrel Shotgun has six parts with the same shell mesh, and the first one (the Hand_2 shell) put the held
            -- shell far off the hand (2026-11-19)
            for _, c in ipairs(children(gun)) do
                local socketOk = true
                if item.part.socket ~= nil and item.part.socket ~= "None" then
                    pcall(function() socketOk = c.AttachSocketName:to_string() == item.part.socket end)
                end
                if socketOk and fullName(meshAsset(c)) == item.part.asset then
                    local asset = meshAsset(c)
                    local comp = nil
                    if item.part.cls:find("Skeletal", 1, true) then
                        comp = uevrUtils.createSkeletalMeshComponent(asset)
                        if comp ~= nil then
                            pcall(function() uevrUtils.copyMaterials(c, comp) end)
                            -- leader-posed on the gun's skeleton with zero relative: at rest the component sits on the gun origin
                            p = newProxy(comp, "skeletal", IDENT)
                        end
                    else
                        comp = uevrUtils.createStaticMeshComponent(asset)
                        if comp ~= nil then
                            pcall(function() uevrUtils.copyMaterials(c, comp) end)
                            local atRest = IDENT
                            -- the part rides its item bone: its offset to that bone is fixed, the bone's rest is learned.
                            -- The live part pose is wrong whenever the gun is posed (Charged Triple Barrel Shotgun: the
                            -- held shell hung below the hand - copied from the shell in the barrel broken open 57 deg)
                            pcall(function() atRest = compose(inv(worldOf(gun)), worldOf(c)) end)
                            pcall(function()
                                if item.bone == nil or item.rest == nil then return end
                                local boneW = fromUE(gun:GetSocketTransform(fname(item.bone), 0))
                                atRest = compose(fromProfile(item.rest), compose(inv(boneW), worldOf(c)))
                            end)
                            p = newProxy(comp, "static", atRest)
                        end
                    end
                    if p ~= nil and withSkin and item.rest ~= nil then
                        -- the isolation rides the part copy in the gun frame: relative = inv(atRest)
                        local iso = buildIsolation(p, gun, item.bone, fromProfile(item.rest), true)
                        if iso ~= nil then
                            iso:K2_AttachToComponent(p.comp, fname(""), 2, 2, 2, false)
                            setRelative(iso, inv(p.atRest))
                        end
                    end
                    return
                end
            end
        end
        -- bone isolation on poseable copies of the gun's skeletal meshes
        local bone = boneOverride or item.bone
        local boneT = nil
        if boneOverride == nil and item.rest ~= nil then boneT = fromProfile(item.rest) end
        if boneOverride ~= nil and restOverride ~= nil then boneT = restOverride end
        local tmp = {}
        local comp = buildIsolation(tmp, gun, bone, boneT)
        if comp == nil then return end
        p = newProxy(comp, "poseable", IDENT)
        for k, v in pairs(tmp) do p[k] = v end
    end)
    if not ok then info("createProxy: " .. tostring(err)) end
    return p
end

local function destroyProxy(p)
    if p == nil then return end
    for i = #proxies, 1, -1 do if proxies[i] == p then table.remove(proxies, i) end end
    for _, sub in ipairs(p.subs or {}) do
        if sub.comp ~= nil and sub.comp ~= p.comp then pcall(function() uevrUtils.destroyComponent(sub.comp, false, false) end) end
    end
    for _, part in ipairs(p.parts or {}) do
        if part.comp ~= nil then pcall(function() uevrUtils.destroyComponent(part.comp, false, false) end) end
    end
    p.parts = nil
    if p.comp ~= nil then pcall(function() uevrUtils.destroyComponent(p.comp, true, false) end) end
    p.comp = nil
end

-- per tick: show placed copies after their first frames, keep re-applying poseable isolation for a while
local function tickProxies(now)
    for i = #proxies, 1, -1 do
        local p = proxies[i]
        if p.comp == nil then
            table.remove(proxies, i)
        else
            local age = now - p.created
            if p.subs ~= nil and age < 3.0 and (age < 0.4 or now >= p.nextApply) then
                p.nextApply = now + 0.25
                pcall(applyIsolation, p)
            end
            if not p.shown and age >= SHOW_AFTER_S and not p.hold then
                p.shown = true
                pcall(function() p.comp:SetVisibility(true, true) end)
            end
        end
    end
end

-- placement: the copy's component pose for an item pose
local function compPose(p, itemPose, rest) return compose(compose(itemPose, inv(rest)), p.atRest) end
local function placeOnGun(p, gun, itemPoseGun, rest)
    if p.parent ~= gun then
        p.comp:K2_AttachToComponent(gun, fname(""), 1, 1, 1, false)
        p.parent = gun
    end
    setRelative(p.comp, compPose(p, itemPoseGun, rest))
end
local function placeWorld(p, itemWorld, rest)
    if p.parent ~= nil then pcall(function() p.comp:K2_DetachFromComponent(1, 1, 1) end) p.parent = nil end
    setWorld(p.comp, compPose(p, itemWorld, rest))
end
local function itemWorldOf(p, rest) return compose(compose(worldOf(p.comp), inv(p.atRest)), rest) end

-- falling copies (ejected / dropped)
local GRAVITY = 980.0
local fallers = {}
local function startFall(p, vel)
    pcall(function() p.comp:K2_DetachFromComponent(1, 1, 1) end)
    p.parent = nil
    local w = worldOf(p.comp)
    fallers[#fallers + 1] = { p = p, pos = w.loc, q = w.q, vel = vel, t0 = os.clock() }
    log(string.format("fall start %s at (%.1f, %.1f, %.1f) vel (%.0f, %.0f, %.0f)", tostring(addr(p.comp)), w.loc.X, w.loc.Y, w.loc.Z, vel.X, vel.Y, vel.Z))
end
local function updateFallers(dt)
    local now = os.clock()
    for i = #fallers, 1, -1 do
        local f = fallers[i]
        local done = f.p.comp == nil or now - f.t0 > 2.0
        if not done then
            local ok, err = pcall(function()
                f.vel = { X = f.vel.X, Y = f.vel.Y, Z = f.vel.Z - GRAVITY * dt }
                f.pos = addV(f.pos, mulV(f.vel, dt))
                setWorld(f.p.comp, { loc = f.pos, q = f.q })
            end)
            if not ok then done = true info("fall error: " .. tostring(err)) end
        end
        if done then
            local vis = "?"
            pcall(function()
                local c = f.p.comp
                local w = worldOf(c)
                vis = string.format("bVisible %s hidden %s IsVisible %s mesh %s parent %s at (%.1f, %.1f, %.1f) scale %s",
                    tostring(c.bVisible), tostring(c.bHiddenInGame), tostring(c:IsVisible()), fullName(meshAsset(c)),
                    tostring(c.AttachParent and fullName(c.AttachParent) or "none"), w.loc.X, w.loc.Y, w.loc.Z,
                    tostring(c.RelativeScale3D and (c.RelativeScale3D.X .. "," .. c.RelativeScale3D.Y) or "?"))
            end)
            log(string.format("fall end %s after %.2f s, shown %s: %s", tostring(addr(f.p.comp)), now - f.t0, tostring(f.p.shown), vis))
            destroyProxy(f.p) table.remove(fallers, i)
        end
    end
end
-- -------------------------------------------------------------------------------------------------------------------
-- left hand finger pose (the game's, from the profile) - written after the hands lib's own animation.
-- Blended both ways (2026-11-19): into the held pose when the magazine / slide is taken, and back out to the
-- hand's own pose when it is let go (insert, drop, rack release), over mr_finger_blend seconds. Poses are blended in
-- the hand bone's frame (finger relative to l_hand_JNT), so the hand can move while it blends. When a blend-out ends
-- the fingers get their exact pre-grab local transforms back (the writes also set bone locations, which the hands
-- lib's pose lerps never reset) and the hand's input-driven poses are unlocked.
-- -------------------------------------------------------------------------------------------------------------------
local fingers = {}   -- { active, mesh, order, snapshot (local transforms), snapRel, lastRel, from, to, t0, out }

local function lockLeftInput(on) pcall(function() hands.setInputLocked(Handed.Left, on) end) end

local function restoreFingerLocals(f)
    if f.mesh == nil or f.snapshot == nil or not exists(f.mesh) then return end
    pcall(function()
        for _, b in ipairs(f.snapshot) do
            animation.setBoneSpaceLocalTransform(f.mesh, b.fname, kismet_math_library:MakeTransform(b.loc, b.rot, b.scale))
        end
    end)
end

-- immediate (no blend): cleanup / level change
local function releaseFingers()
    local f = fingers
    -- diagnostic (2026-11-19, IK rig fingers not posed): how long the pose was written
    if f.active then log(string.format("finger pose: off after %d writes", f.writes or 0)) end
    fingers = {}
    lockLeftInput(false)
    restoreFingerLocals(f)
end

local function toPose(pose)
    local out = {}
    for name, T in pairs(pose) do out[name] = fromProfile(T) end
    return out
end

-- pose: profile finger table (name -> hand-relative transform) or nil = blend back out
local function setFingerPose(pose, mirrored)
    local wantPose = pose ~= nil and not mirrored and configui.getValue("mr_fingers") ~= false
    if wantPose then
        local n = 0
        for _ in pairs(pose) do n = n + 1 end
        log(string.format("finger pose: on (%d bones, input lock -> left hand)", n))
        fingers.active = true
        fingers.out = false
        fingers.to = toPose(pose)
        fingers.from = fingers.lastRel -- nil: read from the mesh on the first write
        fingers.t0 = os.clock()
        lockLeftInput(true)
    elseif pose ~= nil then
        lockLeftInput(true) -- mirrored grip: no finger pose, but no input-driven curl either
    elseif fingers.active and not fingers.out then
        fingers.out = true
        fingers.from = fingers.lastRel
        fingers.to = fingers.snapRel
        fingers.t0 = os.clock()
    elseif not fingers.active then
        lockLeftInput(false)
    end
end

-- the current hand-relative transforms of the listed bones
local function readRel(mesh, order, hand)
    local inv_ = inv(hand)
    local out = {}
    for _, b in ipairs(order) do
        out[b.name] = compose(inv_, fromUE(mesh:GetBoneTransformByName(b.f, BONE_SPACE_COMPONENT)))
    end
    return out
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    if not fingers.active then return end
    local ok, err = pcall(function()
        local mesh = leftHandMesh()
        if mesh == nil then return end
        local hand = fromUE(mesh:GetBoneTransformByName(fname(HAND_BONE), BONE_SPACE_COMPONENT))
        if fingers.mesh ~= mesh then
            -- first write on this mesh: the parent-first bone order, the local transforms to restore at the end and
            -- the same pose hand-relative (the blend-out target)
            local want = fingers.to or {}
            fingers.mesh, fingers.snapshot, fingers.order = mesh, {}, {}
            local n = mesh:GetNumBones()
            for i = 0, n - 1 do
                local f = mesh:GetBoneName(i)
                local s = f:to_string()
                if want[s] ~= nil then
                    fingers.order[#fingers.order + 1] = { name = s, f = f }
                    local rot, loc, scale = animation.getBoneSpaceLocalTransform(mesh, f)
                    if rot ~= nil then
                        fingers.snapshot[#fingers.snapshot + 1] = { fname = f, rot = uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll),
                            loc = vec(loc.X, loc.Y, loc.Z), scale = vec(scale.X, scale.Y, scale.Z) }
                    end
                end
            end
            log(string.format("finger pose: writing %d of %d bones on %s", #fingers.order,
                (function() local c = 0 for _ in pairs(want) do c = c + 1 end return c end)(), fullName(mesh)))
            fingers.snapRel = readRel(mesh, fingers.order, hand)
            fingers.lastRel = nil
            if fingers.out then fingers.to = fingers.snapRel end
            fingers.from = nil
        end
        if fingers.from == nil then fingers.from = fingers.lastRel or readRel(mesh, fingers.order, hand) end
        local T = cfgNum("mr_finger_blend", 0.2)
        local a = T > 0 and math.min(1.0, (os.clock() - fingers.t0) / T) or 1.0
        local e = smooth(a)
        local last = {}
        for _, b in ipairs(fingers.order) do
            local to = fingers.to[b.name]
            local from = fingers.from[b.name] or to
            if to ~= nil then
                local rel = lerpT(from, to, e)
                last[b.name] = rel
                mesh:SetBoneTransformByName(b.f, ueTransform(compose(hand, rel)), BONE_SPACE_COMPONENT)
            end
        end
        fingers.lastRel = last
        fingers.writes = (fingers.writes or 0) + 1
        if fingers.out and a >= 1.0 then releaseFingers() end
    end)
    if not ok then info("finger pose: " .. tostring(err)) releaseFingers() end
end)


-- -------------------------------------------------------------------------------------------------------------------
-- state
-- -------------------------------------------------------------------------------------------------------------------
-- the rack part copy's transform relative to the gun (it is built posed at rest in the gun's component space):
-- a slide moves pull cm along the axis; a rotary rack (rk.rot, Rookie's Reward charging handle 2026-11-20) turns pull
-- deg about the axis through its pivot (the bone's rest position): loc = P - qd * P, q = qd
local function rackDelta(rk, pull)
    local h = math.rad(pull) * 0.5
    local sn = math.sin(h)
    return { X = rk.axis.X * sn, Y = rk.axis.Y * sn, Z = rk.axis.Z * sn, W = math.cos(h) }
end
local function rackRelative(rk, pull)
    if not rk.rot then return { loc = mulV(rk.axis, pull), q = IDENT.q } end
    local qd = rackDelta(rk, pull)
    local P = rk.rest.loc
    return { loc = subV(P, qrot(qd, P)), q = qd }
end

local S_IDLE, S_AWAIT, S_HOLD, S_INSERT, S_AWAIT_RACK, S_RACK, S_FINISH = "idle", "await_mag", "holding", "inserting", "await_rack", "racking", "finishing"
local S_CLOSE = "closing" -- swing-out parts (revolver cylinder) close after the docked item is done
local S_FEED = "feeding"  -- round by round: the native reload runs until one more round is in, then holds again
local S_POUR = "pouring"  -- a docked prop (goo canister): the native reload pours until full, then the prop drops
local FEED_TIMEOUT_S = 1.5
local state = S_IDLE
local cur = {}            -- the reload in progress
local pouch = nil         -- { p, key }
local noInterceptUntil = 0
local gripDown, gripPressed, gripReleased, swallowGrip = false, false, false, false
local nearPouch, nearRack = false, false
local pressLocked = false -- the input callback locked the left hand for a press the tick has not handled yet

local function enter(s)
    if s ~= state then log("state " .. state .. " -> " .. s) end
    state = s
    _G.ow2ManualReloadBusy = (s ~= S_IDLE)
end

local function montageOf(anim)
    local m = nil
    pcall(function() m = anim:GetCurrentActiveMontage() end)
    return m
end
local function montageName(m)
    local n = nil
    pcall(function() n = m:get_fname():to_string() end)
    return n
end
local function isReloadMontage(m)
    local n = m ~= nil and montageName(m) or nil
    return n ~= nil and n:lower():find("reload", 1, true) ~= nil
end

-- real magazine on the gun: the parts on item-bone sockets + a leader-posed skeletal mag part, + the bone itself
local function hideRealItem(gun, item)
    cur.hidden = {}
    cur.hiddenBones = {}
    if item.bone == nil then return end -- a hand prop: nothing of it is on the gun
    -- a round learned from the chamber at a loading gate is a real chamber round of the cylinder: it stays
    -- (Incendiary Light Revolver 2026-11-19: hiding it emptied that chamber and turned with the cylinder)
    if item.keepVisible then return end
    local set = {}
    for _, b in ipairs(item.bones or { item.bone }) do set[b] = true end
    for _, c in ipairs(children(gun)) do
        local hide = false
        pcall(function()
            local socket = c.AttachSocketName:to_string()
            if socket ~= "None" then
                hide = set[gun:GetSocketBoneName(c.AttachSocketName):to_string()] == true
            elseif item.part ~= nil and fullName(meshAsset(c)) == item.part.asset then
                hide = true
            end
        end)
        if hide then
            pcall(function() c:SetHiddenInGame(true, true) end)
            cur.hidden[#cur.hidden + 1] = c
        end
    end
    cur.hiddenBones = {}
    hideGunBone(gun, item.bone, cur.hiddenBones)
end

local function unhideReal()
    for _, c in ipairs(cur.hidden or {}) do
        if exists(c) then pcall(function() c:SetHiddenInGame(false, true) end) end
    end
    if cur.gun ~= nil and exists(cur.gun) then
        for _, h in ipairs(cur.hiddenBones or {}) do
            if h.part ~= nil then
                if exists(h.part) then pcall(function() h.part:SetHiddenInGame(false, true) end) end
            elseif exists(h.c) then pcall(function() h.c:UnHideBoneByName(fname(h.b)) end) end
        end
    end
    cur.hidden, cur.hiddenBones = {}, {}
end

local rackHandRelease = nil -- set by the rack-hand section below
-- hold a reload montage. Round-by-round (Repeating) reloads end and fill the whole tube as soon as their montage is
-- not playing - a paused montage counts (Holographic Repeating Rifle 2026-11-19: clip 4 -> 10 within frames of the
-- pause, the magazine guns never did this) - so those are held with a near-zero play rate instead: still playing,
-- practically frozen
local HOLD_RATE = 0.0001
local function holdMontage(anim, m, rounds)
    if anim == nil or m == nil then return end
    if rounds then
        pcall(function() anim:Montage_SetPlayRate(m, HOLD_RATE) anim:Montage_Resume(m) end)
    else
        pcall(function() anim:Montage_Pause(m) end)
    end
end

-- Round-by-round (Repeating) reloads also run a native fill timer: when no round lands within the pool's ReloadTime /
-- EmptyReloadTime (1.52 / 2.25 s on the Holographic Repeating Rifle) the game fills the whole tube at once, whatever
-- the montage does (held, paused or at 0.0001 rate). The timer is armed when the reload starts, so while a learned
-- round-by-round gun is in hand and manual reload applies, the pool carries ROUNDS_HOLD_TIME instead (measured
-- 2026-11-19: held 5 s at clip 4, then one round landed natively at montage 0.78 s). The game's own values are kept
-- (data/manual_reload_pool_times.json, per weapon class) and put back whenever manual reload does not apply.
local ROUNDS_HOLD_TIME = 1000.0
local POOL_TIMES_FILE = "manual_reload_pool_times.json"
local poolTimes = nil
local function updateRoundsTimer(weapon, hold)
    if poolTimes == nil then
        poolTimes = {}
        pcall(function() local t = json.load_file(POOL_TIMES_FILE) if type(t) == "table" then poolTimes = t end end)
    end
    local pool = weapon:GetAmmoPool()
    if pool == nil then return end
    local key = weapon:get_class():get_fname():to_string()
    local r, e = pool.ReloadTime, pool.EmptyReloadTime
    if type(r) ~= "number" or type(e) ~= "number" then return end
    local o = poolTimes[key]
    if r < ROUNDS_HOLD_TIME * 0.5 and e < ROUNDS_HOLD_TIME * 0.5 then
        -- the game's own values (a stat update may rewrite them): remember them
        if o == nil or math.abs(o.r - r) > 1e-4 or math.abs(o.e - e) > 1e-4 then
            poolTimes[key] = { r = r, e = e }
            o = poolTimes[key]
            pcall(function() json.dump_file(POOL_TIMES_FILE, poolTimes, 1) end)
        end
    end
    if hold then
        if r ~= ROUNDS_HOLD_TIME then pool.ReloadTime = ROUNDS_HOLD_TIME end
        if e ~= ROUNDS_HOLD_TIME then pool.EmptyReloadTime = ROUNDS_HOLD_TIME end
    elseif o ~= nil and (r >= ROUNDS_HOLD_TIME * 0.5 or e >= ROUNDS_HOLD_TIME * 0.5) then
        pool.ReloadTime = o.r
        pool.EmptyReloadTime = o.e
        log(string.format("%s: native reload times restored (%.2f / %.2f s)", key, o.r, o.e))
    end
end

local function restoreBreakPoolSize()
    local ba = cur ~= nil and cur.breakAction or nil
    if ba == nil or ba.poolSize == nil then return end
    pcall(function() cur.weapon:GetAmmoPool().PoolSize = ba.poolSize end)
    ba.poolSize = nil
end

local function cleanup(resumeGame, reason)
    restoreBreakPoolSize()
    if cur ~= nil and cur.propFx ~= nil then
        pcall(function() cur.propFx:Deactivate() end)
        pcall(function() cur.propFx:K2_DestroyComponent(cur.propFx) end)
        cur.propFx = nil
    end
    if reason ~= "done" then info("released (" .. tostring(reason) .. ") in state " .. state) end
    if rackHandRelease ~= nil then pcall(rackHandRelease, os.clock()) end
    if resumeGame then
        pcall(function() if cur.armsMontage ~= nil then cur.armsAnim:Montage_SetPlayRate(cur.armsMontage, 1.0) cur.armsAnim:Montage_Resume(cur.armsMontage) end end)
        pcall(function() if cur.gunMontage ~= nil then cur.gunAnim:Montage_SetPlayRate(cur.gunMontage, 1.0) cur.gunAnim:Montage_Resume(cur.gunMontage) end end)
    end
    unhideReal()
    for _, k in ipairs({ "held", "seated", "slide" }) do if cur[k] ~= nil then destroyProxy(cur[k]) end end
    for _, o in ipairs(cur.openers or {}) do destroyProxy(o.p) end
    setFingerPose(nil) -- blend back out (an insert ~0.1 s before the reload ends is still blending)
    cur = {}
    swallowGrip = false
    noInterceptUntil = os.clock() + 0.5
    enter(S_IDLE)
end

-- the left hand pose for this profile (mirrored for a right-hand gun)
local function profileGrip(profile, F)
    local g = fromProfile(profile.item.grip)
    if g == nil then return nil end
    if profile.mirror then
        local rest = fromProfile(profile.item.rest)
        if not F then return mirrorT(g) end -- no axis convention: plain mirror (approximate)
        local H = compose(rest, g)                       -- the right hand in the gun frame
        g = compose(inv(rest), mirrorHandInGun(H, rest.loc.Y, F))
    end
    return g
end

-- the finger pose to show on the left hand (mirrored from the right for a right-hand gun)
local function leftFingers(pose, profile)
    if not profile.mirror then return pose end
    return mirrorFingers(pose, mirrorF)
end

local function supported(profile)
    if profile == nil or profile.item == nil or profile.item.grip == nil then return false, "not learned yet" end
    if profile.item.rest == nil and profile.item.prop == nil then return false, "not learned yet" end
    if profile.style ~= "item" and profile.style ~= "rounds" and profile.style ~= "prop" then return false, "style " .. tostring(profile.style) .. " not supported yet" end
    if profile.style == "prop" and profile.item.dock == nil then return false, "prop reload without a dock" end
    return true
end

-- -------------------------------------------------------------------------------------------------------------------
-- reload start: catch the native reload, hold it, eject
-- -------------------------------------------------------------------------------------------------------------------
-- Multi-chamber break action (item.seats, Charged Triple Barrel Shotgun 2026-11-19): the k-th round of this reload goes
-- into the k-th chamber in the game's loading order (Left, Middle, Right); seats are at the open barrel copy's pose.
local function selectRoundSeat()
    local seats = cur.profile and cur.profile.item and cur.profile.item.seats
    if seats == nil or #seats == 0 then return end
    local s = seats[math.min(#seats, (cur.loaded or 0) + 1)]
    cur.seat = fromProfile(s.seat)
    cur.approachT = fromProfile(s.approach)
    cur.seatBone = s.bone
end

local function tryIntercept(pawn, weapon, gun, profile)
    if os.clock() < noInterceptUntil then return end
    local arms = nil
    pcall(function() arms = pawn.FPVMesh end)
    if arms == nil then return end
    local armsAnim, gunAnim = nil, nil
    pcall(function() armsAnim = arms.AnimScriptInstance end)
    pcall(function() gunAnim = gun.AnimScriptInstance end)
    local am, gm = montageOf(armsAnim), montageOf(gunAnim)
    if not isReloadMontage(am) and not isReloadMontage(gm) then return end
    if not isReloadMontage(am) then am = nil end
    if not isReloadMontage(gm) then gm = nil end
    local pos = 0
    pcall(function() pos = am ~= nil and armsAnim:Montage_GetPosition(am) or gunAnim:Montage_GetPosition(gm) end)
    if type(pos) ~= "number" or pos > LATE_CATCH_S then return end

    local clip = nil
    pcall(function() clip = weapon:GetCurrentAmmoCount() end)
    local hasEmpty = true
    pcall(function() hasEmpty = weapon:GetAmmoPool().bHasEmptyReload end)
    local wasEmpty = clip == 0
    -- the analyzer still has to see this kind of reload once
    if _G.ow2ReloadAnalyzer ~= nil then
        local a = _G.ow2ReloadAnalyzer
        if (a.wantsReload ~= nil and a.wantsReload()) or a.isRecording() then
            noInterceptUntil = os.clock() + 1.0
            log("the analyzer wants this reload - native")
            return
        end
    end
    if wasEmpty and hasEmpty and (profile.recorded == nil or profile.recorded.empty == nil) then
        noInterceptUntil = os.clock() + 1.0
        log("empty reload not learned yet - native")
        return
    end
    -- two-handing: two_handed.lua lets go of the gun once _G.ow2ManualReloadBusy is set (enter below)

    -- Break action (multi-chamber, item.seats): the game completes this reload on its own timer whatever the montage
    -- does (BreakActionReloadTimes - a map Lua cannot write; ReloadTime and the time-dilation handlers do not move it:
    -- measured 2026-11-19, filled ~3 s into a held reload). So the native reload runs through at once here, the shells
    -- it put in go back out (refunded to the inventory), and every shell the player seats is granted with RefillAmmo.
    local breakAct = profile.style == "rounds" and profile.reloadType == 2 and profile.item ~= nil and profile.item.seats ~= nil
    if breakAct then
        pcall(function() if am ~= nil then armsAnim:Montage_SetPlayRate(am, 100.0) armsAnim:Montage_Resume(am) end end)
        pcall(function() if gm ~= nil then gunAnim:Montage_SetPlayRate(gm, 100.0) gunAnim:Montage_Resume(gm) end end)
    else
        holdMontage(armsAnim, am, profile.style == "rounds" or profile.style == "prop")
        holdMontage(gunAnim, gm, profile.style == "rounds" or profile.style == "prop")
    end

    cur = { pawn = pawn, weapon = weapon, gun = gun, profile = profile, armsAnim = armsAnim, armsMontage = am,
            gunAnim = gunAnim, gunMontage = gm, wasEmpty = wasEmpty, clipBefore = clip,
            rest = itemRestT(profile.item) }
    if profile.mirror then computeMirrorF(arms) end
    cur.grip = profileGrip(profile, mirrorF)
    -- the seat target: the dock (the item is elsewhere than its rest when the ammo lands: revolver speedloader) or rest
    cur.seat = fromProfile(profile.item.seat) or cur.rest
    if profile.style == "prop" then
        -- the prop goes to where the game docks it (the canister over the open lid) and stays there while it pours
        cur.seat = fromProfile(profile.item.dock)
        -- 2026-11-19: the canister sits lower into the opening than the game's dock (the gun frame's Z is up)
        if profile.pour then cur.seat.loc.Z = cur.seat.loc.Z - cfgNum("mr_prop_dock_down", 5.0) end
        cur.approachT = cur.seat
    end
    cur.missing = math.max(0, (profile.poolSize or clip or 0) - (clip or 0))
    selectRoundSeat()
    if breakAct then
        cur.breakAction = { phase = "complete", clip0 = clip or 0, spare0 = spareAmmo(pawn, weapon), t0 = os.clock(), pending = 0 }
        -- PoolSize is the capacity (GetMissingAmmo = PoolSize - count): at the current count the native refill adds
        -- nothing - no flash of a full gun, no inventory taken (2026-11-19: "ammo sets to 3 after a few seconds")
        pcall(function()
            local pool = weapon:GetAmmoPool()
            cur.breakAction.poolSize = pool.PoolSize
            pool.PoolSize = clip or 0
        end)
    end
    info(string.format("reload caught at %.2f s (%s, clip %s): %s - arms %s, weapon %s", pos, wasEmpty and "empty" or "tactical",
        tostring(clip), tostring(profile.name), tostring(montageName(am)), tostring(montageName(gm))))

    -- eject: a copy takes the real magazine's place and falls out along the insert stroke
    -- the item bone's skinned geometry is part of the item when the game draws it (read before hideRealItem hides it)
    pcall(function() cur.itemSkin = not gun:IsBoneHiddenByName(fname(profile.item.bone)) end)
    -- rounds go in one at a time: nothing comes out
    local drop = (not profile.item.docked and profile.style ~= "rounds" and profile.style ~= "prop") and createProxy(gun, profile.item, nil, nil, cur.itemSkin) or nil
    hideRealItem(gun, profile.item)
    -- swing-out parts (cylinder hinge, break barrel): a moving copy of the part's bone subtree takes over and opens
    cur.openers = {}
    for _, m in ipairs(profile.mechanisms or {}) do
        if m.opener and m.openPose ~= nil and m.rest ~= nil then
            local p = createProxy(gun, profile.item, m.bone, fromProfile(m.rest))
            if p ~= nil then
                pcall(function()
                    p.comp:K2_AttachToComponent(gun, fname(""), 2, 2, 2, false)
                    p.parent = gun
                end)
                hideGunBone(gun, m.bone, cur.hiddenBones)
                local o = { p = p, rest = fromProfile(m.rest), open = fromProfile(m.openPose), bone = m.bone, rounds = {} }
                -- rounds in the part (revolver cylinder, break-barrel chambers): ejected once it is open
                pcall(function()
                    local hinge = fname(m.bone)
                    local isRound = function(n) n = n:lower() return n:find("bullet", 1, true) or n:find("round", 1, true)
                        or n:find("shell", 1, true) or n:find("cartridge", 1, true) end
                    local n = gun:GetNumBones()
                    for bi = 0, n - 1 do
                        local bf = gun:GetBoneName(bi)
                        local name = bf:to_string()
                        if isRound(name) and gun:BoneIsChildOf(bf, hinge) then
                            local parentName = gun:GetParentBone(bf):to_string()
                            if not isRound(parentName) then
                                o.rounds[#o.rounds + 1] = { name = name, rest = fromUE(gun:GetSocketTransform(bf, RTS_COMPONENT)) }
                            end
                        end
                    end
                end)
                do
                    local swing = compose(o.open, inv(o.rest))
                    local pt = (#o.rounds > 0 and o.rounds[1].rest.loc) or addV(o.rest.loc, { X = 5, Y = 0, Z = 0 })
                    local openPt = compose(swing, { loc = pt, q = IDENT.q }).loc
                    local d = subV(pt, openPt)
                    local l = lenV(d)
                    o.closeDir = l > 0.01 and mulV(d, 1 / l) or nil
                end
                cur.openers[#cur.openers + 1] = o
            end
        end
    end
    if #cur.openers > 0 then cur.openAnim = { t0 = os.clock(), from = 0, to = 1, dur = 0.2 } end
    log("drop copy: " .. (drop ~= nil and (tostring(drop.kind) .. " " .. tostring(addr(drop.comp))) or "none"))
    if drop ~= nil then
        local okDrop, errDrop = pcall(function()
            placeOnGun(drop, gun, cur.rest, cur.rest)
            local axis = profile.item.axis or { X = 0, Y = 0, Z = 1 }
            local outWorld = qrot(worldOf(gun).q, mulV(axis, -1))
            -- out along the stroke, gently, plus a push down: a top magazine (heavy MG: the stroke comes down + back)
            -- reversed at 120 cm/s shot forward off the gun and read as "it just disappears" (2026-11-19)
            startFall(drop, addV(mulV(outWorld, 35.0), { X = 0, Y = 0, Z = -40.0 }))
        end)
        if not okDrop then info("drop copy error: " .. tostring(errDrop)) end
    end
    haptic(0.04, 0.4)
    -- a rack part (empty reloads, or every reload when the gun has only one reload variant)
    -- round-by-round guns: their rack is a lever (rotates about a pivot; the sliding part copy would look wrong) - the
    -- (prop guns: the Corrosive Shock MG's empty record "racked" R_Capasitor_03_JNT, a part sliding by itself - the manual
    -- reload then waited for a rack with the trigger blocked, 2026-11-19)
    -- native reload still cycles it during the feed, a manual lever is a later step
    if profile.rack ~= nil and profile.style ~= "rounds" and profile.style ~= "prop" and (wasEmpty or profile.rack.every) and configui.getValue("mr_rack") ~= false then
        local rk = profile.rack
        if rk.bolt ~= nil and gm ~= nil then
            -- bolt action (Volted Sniper Rifle): the gun's own reload montage poses the bolt, its handle and the linkage
            -- outside the bolt's bone chain, so no part copy: the montage is scrubbed open now, and the left hand
            -- pushes it shut after the insert (scrubbing back along the learned travel -> montage time table)
            local gpos, apos = 0, nil
            pcall(function() gpos = gunAnim:Montage_GetPosition(gm) end)
            pcall(function() if am ~= nil then apos = armsAnim:Montage_GetPosition(am) end end)
            cur.rack = { bolt = rk.bolt, pull = rk.travel or 5, lock = 0, travel = rk.travel or 5, axis = rk.axis,
                         grabBone = rk.lift and rk.lift.bone or rk.bone, crank = rk.crank == true, knob = rk.knob,
                         open = { from = gpos, fromArms = apos or gpos, t0 = os.clock(), dur = 0.3 } }
        else
            -- the part copy shows where the game holds it (locked back) from now on
            local slide = createProxy(gun, profile.item, rk.bone, fromProfile(rk.rest))
            if slide ~= nil then
                hideGunBone(gun, rk.bone, cur.hiddenBones)
                local lock = rk.lockedBack and ((rk.rot and rk.lockedDeg or rk.lockedCm) or 0) or 0
                cur.slide = slide
                cur.rack = { pull = lock, lock = lock, travel = rk.travel or 5, axis = rk.axis, rest = fromProfile(rk.rest),
                             rot = rk.rot == true }
                pcall(function()
                    slide.comp:K2_AttachToComponent(gun, fname(""), 2, 2, 2, false)
                    slide.parent = gun
                    setRelative(slide.comp, rackRelative(cur.rack, lock))
                end)
            end
        end
    end
    enter(S_AWAIT)
end

-- -------------------------------------------------------------------------------------------------------------------
-- pouch at the left hip
-- -------------------------------------------------------------------------------------------------------------------
local function pouchItemWorld(gun, profile)
    local head = controllers.getControllerLocation(2)
    local hr = controllers.getControllerRotation(2)
    if head == nil or hr == nil then return nil end
    local yaw = math.rad(hr.Yaw or 0)
    local fx, fy, fz = cfgVec("mr_pouch_loc", { 8.0, -24.0, -58.0 })
    local f = { X = math.cos(yaw), Y = math.sin(yaw), Z = 0 }
    local r = { X = -math.sin(yaw), Y = math.cos(yaw), Z = 0 }
    local point = { X = head.X + f.X * fx + r.X * fy, Y = head.Y + f.Y * fx + r.Y * fy, Z = head.Z + fz }
    -- the magazine as it sits in an upright gun facing the body's forward
    local yq = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) }
    return { loc = point, q = qmul(yq, itemRestT(profile.item).q) }
end

local function destroyPouch()
    if pouch ~= nil then destroyProxy(pouch.p) end
    pouch = nil
    nearPouch = false
end

local function updatePouch(gun, profile)
    local key = tostring(addr(gun))
    if pouch == nil or pouch.key ~= key or pouch.p.comp == nil then
        destroyPouch()
        -- the pouch copy is built while idle too (no cur): then nothing of ours is hidden and the real gun's bone
        -- visibility is the game's own; during a reload cur.itemSkin holds the value read before hideRealItem
        local skin = false
        if cur ~= nil and cur.gun == gun then skin = cur.itemSkin == true
        else pcall(function() skin = not gun:IsBoneHiddenByName(fname(profile.item.bone)) end) end
        local p = createProxy(gun, profile.item, nil, nil, skin)
        if p == nil then return end
        pouch = { p = p, key = key }
    end
    local w = pouchItemWorld(gun, profile)
    if w == nil then return end
    pcall(function() placeWorld(pouch.p, w, itemRestT(profile.item)) end)
    local hand = controllers.getControllerLocation(Handed.Left)
    local was = nearPouch
    nearPouch = hand ~= nil and lenV(subV({ X = hand.X, Y = hand.Y, Z = hand.Z }, w.loc)) <= cfgNum("mr_grab_radius", 13.0)
    if nearPouch and not was and state == S_AWAIT then haptic(0.02, 0.25) end
end

-- -------------------------------------------------------------------------------------------------------------------
-- magazine in the hand
-- -------------------------------------------------------------------------------------------------------------------
local function grabFromPouch()
    local mesh = leftHandMesh()
    if mesh == nil or pouch == nil then return false end
    local p = pouch.p
    pouch = nil
    local ok = pcall(function()
        p.comp:K2_AttachToComponent(mesh, fname(HAND_BONE), 1, 1, 1, false) -- keep world, then glide into the grip
        p.parent = mesh
        local from = compose(inv(fromUE(mesh:GetSocketTransform(fname(HAND_BONE), 0))), worldOf(p.comp))
        p.glide = { t0 = os.clock(), from = from }
    end)
    if not ok then destroyProxy(p) return false end
    cur.held = p
    setFingerPose(leftFingers(cur.profile.fingers, cur.profile), false)
    haptic(0.03, 0.5)
    enter(S_HOLD)
    log("magazine taken from the pouch")
    return true
end

-- the copy's pose on the hand bone: item in hand frame = grip^-1
local function heldTarget(p) return compPose(p, inv(cur.grip), cur.rest) end

local function updateHeld()
    local p = cur.held
    if p == nil or p.comp == nil then return false end
    local target = heldTarget(p)
    local g = p.glide
    local T = cfgNum("mr_grab_glide", 0.10)
    if g ~= nil and T > 0 then
        local a = math.min(1.0, (os.clock() - g.t0) / T)
        if a >= 1.0 then p.glide = nil end
        setRelative(p.comp, lerpT(g.from, target, smooth(a)))
    else
        p.glide = nil
        setRelative(p.comp, target)
    end
    return true
end

local function dropHeld()
    local p = cur.held
    cur.held = nil
    setFingerPose(nil)
    if p ~= nil and p.comp ~= nil then startFall(p, { X = 0, Y = 0, Z = -50 }) end
    log("magazine let go - dropped")
end

-- the held magazine vs the start of the learned insert stroke, world cm
-- distance to the learned insert path (approach -> seat segment): a push from any side counts once the item is near any
-- point of the stroke (2026-11-19, Holographic Repeating Rifle: rounds go in at the side gate and slide forward)
local function wellDistance()
    local item = itemWorldOf(cur.held, cur.rest)
    local gunW = worldOf(cur.gun)
    local a = compose(gunW, cur.approachT or fromProfile(cur.profile.item.approach) or cur.rest).loc
    local b = compose(gunW, cur.seat or cur.rest).loc
    local ab = subV(b, a)
    local L2 = dotV(ab, ab)
    local t = L2 > 1e-6 and math.max(0, math.min(1, dotV(subV(item.loc, a), ab) / L2)) or 0
    local q = addV(a, mulV(ab, t))
    return lenV(subV(item.loc, q))
end

-- -------------------------------------------------------------------------------------------------------------------
-- insert glide: onto the learned approach pose, then along the stroke into the seat
-- -------------------------------------------------------------------------------------------------------------------
local INSERT_ALIGN_FRACTION = 0.5
local function startInsert()
    local p = cur.held
    cur.held = nil
    setFingerPose(nil)
    pcall(function()
        p.comp:K2_AttachToComponent(cur.gun, fname(""), 1, 1, 1, false)
        p.parent = cur.gun
    end)
    -- where the item is now, in gun space
    local itemNow = compose(inv(worldOf(cur.gun)), itemWorldOf(p, cur.rest))
    cur.seated = p
    cur.insert = { t0 = os.clock(), from = itemNow, approach = cur.approachT or fromProfile(cur.profile.item.approach) or cur.rest }
    enter(S_INSERT)
    log("insert glide")
end

local function updateInsert()
    local ins, p = cur.insert, cur.seated
    if ins == nil or p == nil or p.comp == nil then return true end
    local T = cfgNum("mr_insert_time", 0.15)
    local a = math.min(1.0, (os.clock() - ins.t0) / T)
    local pose
    if a < INSERT_ALIGN_FRACTION then
        local t = a / INSERT_ALIGN_FRACTION
        pose = lerpT(ins.from, ins.approach, 1 - (1 - t) * (1 - t))
    else
        local t = (a - INSERT_ALIGN_FRACTION) / (1 - INSERT_ALIGN_FRACTION)
        pose = lerpT(ins.approach, cur.seat, t * t)
    end
    if a >= 1.0 then pose = cur.seat end
    pcall(function() setRelative(p.comp, compPose(p, pose, cur.rest)) end)
    return a >= 1.0
end

-- -------------------------------------------------------------------------------------------------------------------
-- rack: the part copy follows the left hand along the learned axis; let go past mr_rack_done = racked
-- -------------------------------------------------------------------------------------------------------------------
local function setSlidePull(pull)
    if cur.slide == nil or cur.slide.comp == nil then return end
    pcall(function() setRelative(cur.slide.comp, rackRelative(cur.rack, pull)) end)
end

-- the rack grab points (world): the part itself, and where the game's left hand bone sits on it (the learned grip -
-- the wrist bone, on the AR 13 cm from the lever: compared with the visible hand's wrist bone, not the controller)
local function rackGrabWorld()
    local rk, prof = cur.rack, cur.profile.rack
    local gunW = worldOf(cur.gun)
    local bone = { loc = addV(rk.rest.loc, mulV(rk.axis, rk.pull)), q = rk.rest.q }
    if rk.rot then bone = compose(rackRelative(rk, rk.pull), rk.rest) end
    local partW = compose(gunW, bone).loc
    local handW = (prof.grip ~= nil and prof.hand ~= "right") and compose(gunW, compose(bone, fromProfile(prof.grip))).loc or nil
    return partW, handW
end

local function leftHandBoneWorld()
    local mesh = leftHandMesh()
    if mesh == nil then return nil end
    local t = nil
    pcall(function() t = fromUE(mesh:GetSocketTransform(fname(HAND_BONE), 0)).loc end)
    return t
end

local function startFinish()
    local rate = cfgNum("mr_finish_rate", 20.0)
    pcall(function() if cur.armsMontage ~= nil then cur.armsAnim:Montage_SetPlayRate(cur.armsMontage, rate) cur.armsAnim:Montage_Resume(cur.armsMontage) end end)
    pcall(function() if cur.gunMontage ~= nil then cur.gunAnim:Montage_SetPlayRate(cur.gunMontage, rate) cur.gunAnim:Montage_Resume(cur.gunMontage) end end)
    cur.finishT0 = os.clock()
    enter(S_FINISH)
    log(string.format("native reload resumed at %.0fx", rate))
end

-- -------------------------------------------------------------------------------------------------------------------
-- left hand on the rack part (2026-11-19: the hand must stay fixed on the slide while pulling). On the grab the
-- visible hand is fixed to the part copy where it is; it moves with the pull and glides back to the controller on
-- release (Hellraiser "left hand rides the slide").
--   Hands mode: the glove is re-parented onto the part copy (keep world) and put back afterwards.
--   IK mode:    libs/ik.lua's accessory channel ("on_accessory_attach": the left IK target rides the part copy as a
--               virtual controller = the controller's grab-time pose in the part's frame), detached on release.
-- -------------------------------------------------------------------------------------------------------------------
local rackHand = nil   -- { ik, parent, glove, snap = { parent, socket, rel }, glide, returning }

local function ikHandsMode() return _G.getHandsMode ~= nil and _G.getHandsMode() == 2 end
local function handGlideTime()
    local v = configui.getValue("th_offhand_glide") -- two_handed.lua's off-hand glide
    return type(v) == "number" and v or 0.15
end

local function attachRackHand(now, parentComp, socket)
    rackHand = nil
    local ok, err = pcall(function()
        local ctrl = controllers.getController(Handed.Left, true)
        if ctrl == nil or parentComp == nil then return end
        local rh = { ik = ikHandsMode(), parent = parentComp }
        if rh.ik then
            local parentW = worldOf(parentComp)
            if socket ~= nil then parentW = fromUE(parentComp:GetSocketTransform(fname(socket), 0)) end
            local rel = compose(inv(parentW), worldOf(ctrl))
            local r = q2r(rel.q)
            rh.loc, rh.rot = rel.loc, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
            uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Left, parentComp, socket or "", 0, rh.loc, rh.rot)
            rh.attached = true
        else
            local glove = hands ~= nil and hands.getHandComponent(Handed.Left) or nil
            if glove == nil or not exists(glove) then return end
            local parent = glove.AttachParent
            local socket = "None"
            pcall(function() socket = glove.AttachSocketName:to_string() end)
            rh.glove = glove
            rh.snap = { parent = parent, socket = socket ~= "None" and socket or "",
                        rel = parent ~= nil and compose(inv(worldOf(parent)), worldOf(glove)) or nil }
            glove:K2_AttachToComponent(parentComp, fname(socket or ""), 1, 1, 1, false) -- keep world: fixed where it is
        end
        rackHand = rh
    end)
    if not ok then info("rack hand attach: " .. tostring(err)) rackHand = nil end
end

local function releaseRackHand(now)
    local rh = rackHand
    if rh == nil or rh.returning then return end
    if rh.ik then
        rackHand = nil
        if rh.attached then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end) end
        return
    end
    local ok = pcall(function()
        if not exists(rh.glove) then error("glove gone") end
        if rh.snap.parent ~= nil and exists(rh.snap.parent) then
            rh.glove:K2_AttachToComponent(rh.snap.parent, fname(rh.snap.socket), 1, 1, 1, false) -- keep world, then glide
            rh.glide = { t0 = now, dur = handGlideTime(), from = compose(inv(worldOf(rh.snap.parent)), worldOf(rh.glove)) }
            rh.returning = true
        else
            controllers.attachComponentToController(Handed.Left, rh.glove)
            rackHand = nil
        end
    end)
    if not ok then rackHand = nil end
end

-- every frame: the glove's glide home after a release (the ride itself needs nothing: the glove / IK target is on the
-- moving part copy)
local function tickRackHand(now)
    local rh = rackHand
    if rh == nil or not rh.returning then return end
    local ok = pcall(function()
        if not exists(rh.glove) then error("glove gone") end
        local g = rh.glide
        local a = g.dur > 0 and math.min(1.0, (now - g.t0) / g.dur) or 1.0
        local e = 1 - (1 - a) ^ 3
        setRelative(rh.glove, lerpT(g.from, rh.snap.rel, e))
        if a >= 1.0 then rackHand = nil end
    end)
    if not ok then rackHand = nil end
end

rackHandRelease = releaseRackHand

-- bolt action: the weapon reload montage is the bolt's pose (see the rack setup in tryIntercept). It is a sync follower
-- of the arms reload montage, which overwrites its position every frame, so the arms montage (the leader) is moved
-- too - a weapon-only Montage_SetPosition was undone the next frame and the bolt never opened (2026-11-19).
-- pos: weapon montage time; armsPos: arms montage time (the same time when not learned)
local function setBoltPos(pos, armsPos)
    pcall(function() if cur.armsMontage ~= nil then cur.armsAnim:Montage_SetPosition(cur.armsMontage, armsPos or pos) end end)
    pcall(function() cur.gunAnim:Montage_SetPosition(cur.gunMontage, pos) end)
end
-- bolt travel (cm back from closed) -> montage time, through the learned close table (travel non-increasing)
local function setBoltPull(pull)
    local tbl = cur.rack.bolt.close
    local pos, armsPos = tbl[1].p, tbl[1].a
    if pull <= tbl[#tbl].d then
        pos, armsPos = tbl[#tbl].p, tbl[#tbl].a
    elseif pull < tbl[1].d then
        for k = 1, #tbl - 1 do
            local a, b = tbl[k], tbl[k + 1]
            if pull <= a.d and pull >= b.d then
                local span = a.d - b.d
                local f = span > 1e-4 and (a.d - pull) / span or 1.0
                pos = a.p + (b.p - a.p) * f
                if a.a ~= nil and b.a ~= nil then armsPos = a.a + (b.a - a.a) * f else armsPos = nil end
                break
            end
        end
    end
    setBoltPos(pos, armsPos)
end
-- the bolt opening right after the eject (the game opens it in its first 0.35 s; the reload is caught before that)
local function tickBoltOpen(now)
    local rk = cur ~= nil and cur.rack or nil
    if rk == nil or rk.open == nil or cur.gunMontage == nil then return end
    local a = math.min(1.0, (now - rk.open.t0) / rk.open.dur)
    local toA = rk.bolt.openArms or rk.bolt.openPos
    setBoltPos(rk.open.from + (rk.bolt.openPos - rk.open.from) * a, rk.open.fromArms + (toA - rk.open.fromArms) * a)
    if a >= 1.0 then rk.open = nil end
end

-- crank (rk.crank, Anti-Matter Plasma Rifle 2026-11-20): the bolt table holds degrees still to wind. The hand winds it at
-- the knob - rk.knob, where the game's fist closes on the crank (crank bone frame, about 9 cm off the axle). Each frame
-- the hand's travel along the knob's circle, over the knob radius, is the turn: the knob keeps pace with the hand 1:1
-- wherever the player's own circle is centred. (The first version measured the hand's angle about the axle: with the
-- hand a few cm off the axle a small move read as a big turn - "the rotation feels large".) Re-grabbing continues the
-- wind (it stays where it was left).
local function crankCross(a, b) return { X = a.Y * b.Z - a.Z * b.Y, Y = a.Z * b.X - a.X * b.Z, Z = a.X * b.Y - a.Y * b.X } end
local function crankKnobWorld(rk)
    local boneW = nil
    pcall(function() boneW = fromUE(cur.gun:GetSocketTransform(fname(rk.grabBone), 0)) end)
    if boneW == nil then return nil, nil end
    if rk.knob == nil then return boneW.loc, boneW end
    return compose(boneW, { loc = rk.knob, q = IDENT.q }).loc, boneW
end
local function crankStep(rk, hand)
    local prev = rk.crankPrev
    rk.crankPrev = hand
    if prev == nil then return 0 end
    local knobW, boneW = crankKnobWorld(rk)
    if knobW == nil then return 0 end
    local ax = qrot(worldOf(cur.gun).q, rk.axis)
    local k = subV(knobW, boneW.loc)
    k = subV(k, mulV(ax, dotV(k, ax)))
    local R = lenV(k)
    if R < 3 then
        -- no knob offset learned: the hand's own offset from the axle
        k = subV(hand, boneW.loc)
        k = subV(k, mulV(ax, dotV(k, ax)))
        R = lenV(k)
        if R < 3 then return 0 end
    end
    local tangent = crankCross(ax, mulV(k, 1 / R))
    return math.deg(dotV(subV(hand, prev), tangent) / R)
end

local function updateBolt(now, pressed, released)
    local rk = cur.rack
    if rk.open ~= nil then return end
    local handC = controllers.getControllerLocation(Handed.Left)
    local hand = handC and { X = handC.X, Y = handC.Y, Z = handC.Z } or nil
    local grabW = nil
    if rk.crank then
        grabW = crankKnobWorld(rk)
    else
        pcall(function() grabW = fromUE(cur.gun:GetSocketTransform(fname(rk.grabBone), 0)).loc end)
    end
    local was = nearRack
    nearRack = hand ~= nil and grabW ~= nil and lenV(subV(hand, grabW)) <= cfgNum("mr_rack_radius", 10.0)
    if nearRack and not was and state == S_AWAIT_RACK then haptic(0.02, 0.25) end
    if state == S_AWAIT_RACK then
        if pressed and nearRack then
            rk.handStart, rk.pullStart = hand, rk.pull
            rk.crankPrev, rk.crankSweep = nil, 0
            setBoltPull(rk.pull)
            local pose = cur.profile.rack.fingers
            if cur.profile.rack.hand == "right" then pose = mirrorFingers(pose, mirrorF) end
            setFingerPose(pose, false)
            attachRackHand(now, cur.gun, rk.grabBone)
            haptic(0.02, 0.4)
            enter(S_RACK)
        end
        return
    end
    -- S_RACK: push it home (against the open axis); it stays where it is left on a release
    if hand ~= nil then
        local d
        if rk.crank then
            rk.crankSweep = (rk.crankSweep or 0) + crankStep(rk, hand)
            d = -rk.crankSweep
        else
            local axisW = qrot(worldOf(cur.gun).q, rk.axis)
            d = dotV(subV(hand, rk.handStart), axisW)
        end
        rk.pull = math.max(0, math.min(rk.travel, rk.pullStart + d))
        setBoltPull(rk.pull)
        if rk.pull <= rk.travel * (1.0 - cfgNum("mr_rack_done", 0.8)) then
            setBoltPull(0)
            setFingerPose(nil)
            releaseRackHand(now)
            haptic(0.05, 0.9)
            log("bolt closed")
            startFinish()
            return
        end
    end
    if released or not gripDown then
        setFingerPose(nil)
        releaseRackHand(now)
        enter(S_AWAIT_RACK)
    end
end

-- rotary rack: the angle the hand has swept about the pivot axis since the grab (both measured in the plane across the
-- axis). The pivot is taken at the grab (the gun moves with the right hand while the left pulls - fine for a quick pull).
-- A hand within 4 cm of the axis gives no usable angle: the tangential travel over a 4 cm radius is used instead.
local function rotaryPull(rk, hand)
    local ax = rk.axisW
    local function flat(v) return subV(v, mulV(ax, dotV(v, ax))) end
    local function cross(a, b) return { X = a.Y * b.Z - a.Z * b.Y, Y = a.Z * b.X - a.X * b.Z, Z = a.X * b.Y - a.Y * b.X } end
    local gunW = worldOf(cur.gun)
    local pivot = compose(gunW, rk.rest).loc
    local v0 = flat(subV(rk.handStart, rk.pivotW))
    local v = flat(subV(hand, pivot))
    local r0 = lenV(v0)
    if r0 >= 4 and lenV(v) >= 4 then
        return math.deg(math.atan(dotV(ax, cross(v0, v)), dotV(v0, v)))
    end
    local n = r0 > 1e-3 and mulV(v0, 1 / r0) or nil
    if n == nil then return 0 end
    local t = cross(ax, n)
    return math.deg(dotV(subV(hand, rk.handStart), t) / 4)
end

local function updateRack(now, pressed, released)
    local rk = cur.rack
    if rk == nil then startFinish() return end
    if rk.bolt ~= nil then updateBolt(now, pressed, released) return end
    if rk.spring ~= nil then
        local a = math.min(1.0, (now - rk.spring.t0) / 0.05)
        rk.pull = rk.spring.from + (rk.spring.to - rk.spring.from) * a * a
        setSlidePull(rk.pull)
        if a >= 1.0 then
            local done = rk.spring.armed
            rk.spring = nil
            if done then
                haptic(0.05, 0.9)
                log("racked")
                startFinish()
            end
        end
        return
    end
    local handC = controllers.getControllerLocation(Handed.Left)
    local hand = handC and { X = handC.X, Y = handC.Y, Z = handC.Z } or nil
    local partW, handW = rackGrabWorld()
    local was = nearRack
    local radius = cfgNum("mr_rack_radius", 10.0)
    local handBone = handW ~= nil and leftHandBoneWorld() or nil
    nearRack = (hand ~= nil and lenV(subV(hand, partW)) <= radius) or
               (handBone ~= nil and lenV(subV(handBone, handW)) <= radius)
    if nearRack and not was and state == S_AWAIT_RACK then haptic(0.02, 0.25) end
    if state == S_AWAIT_RACK then
        if pressed and nearRack and hand ~= nil then
            rk.handStart, rk.pullStart, rk.armed = hand, rk.pull, false
            if rk.rot then
                local gunW = worldOf(cur.gun)
                rk.pivotW = compose(gunW, rk.rest).loc
                rk.axisW = qrot(gunW.q, rk.axis)
            end
            -- the rack pose is mirrored by the hand that racked in the game, not the gun's item hand
            -- (Sawed-Off Aircooled MG: right hand carries the drum, left hand pulls the bolt)
            local rackPose = cur.profile.rack.fingers
            if cur.profile.rack.hand == "right" then rackPose = mirrorFingers(rackPose, mirrorF) end
            setFingerPose(rackPose, false)
            if cur.slide ~= nil and cur.slide.comp ~= nil then attachRackHand(now, cur.slide.comp) end
            haptic(0.02, 0.4)
            enter(S_RACK)
        end
        return
    end
    -- S_RACK
    if hand ~= nil then
        local d
        if rk.rot then
            d = rotaryPull(rk, hand)
        else
            local axisW = qrot(worldOf(cur.gun).q, rk.axis)
            d = dotV(subV(hand, rk.handStart), axisW)
        end
        rk.pull = math.max(rk.lock, math.min(rk.travel, rk.pullStart + d))
        setSlidePull(rk.pull)
        if not rk.armed and rk.pull >= rk.travel * cfgNum("mr_rack_done", 0.8) then
            rk.armed = true
            haptic(0.03, 0.6)
        end
    end
    if released or not gripDown then
        setFingerPose(nil)
        releaseRackHand(now)
        rk.spring = { t0 = now, from = rk.pull, to = rk.armed and 0 or rk.lock, armed = rk.armed }
        enter(S_AWAIT_RACK)
    end
end

-- The weapon reload montage is a sync follower of the arms one. Resumed on its own at the finish rate, it lost its
-- leader when the arms montage ended and kept looping its "Loop" section at 20x after the reload was over (Incendiary
-- Light Revolver 2026-11-19: arms montage gone, IsReloading false, weapon montage still playing "Loop" until a shot).
-- Done = the arms montage ended (when there is one); a weapon reload montage still running then is stopped.
local function finishDone()
    local am = cur.armsAnim ~= nil and montageOf(cur.armsAnim) or nil
    local gm = cur.gunAnim ~= nil and montageOf(cur.gunAnim) or nil
    local armsBusy = cur.armsMontage ~= nil and am ~= nil and addr(am) == addr(cur.armsMontage)
    local gunBusy = cur.gunMontage ~= nil and gm ~= nil and addr(gm) == addr(cur.gunMontage)
    if cur.armsMontage ~= nil then
        if armsBusy then return false end
        if gunBusy then
            pcall(function() cur.gunAnim:Montage_Stop(0.15, cur.gunMontage) end)
            log("weapon reload montage stopped with its leader")
        end
        return true
    end
    return not gunBusy
end

-- -------------------------------------------------------------------------------------------------------------------
-- input: the left grip
-- -------------------------------------------------------------------------------------------------------------------
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state_)
    if user_index ~= 0 or state_ == nil then return end
    local down = uevrUtils.isButtonPressed(state_, BTN_LB)
    if down and not gripDown then
        gripPressed = true
        if (state == S_AWAIT and nearPouch) or (state == S_AWAIT_RACK and nearRack) then
            swallowGrip = true
            pcall(function() hands.setInputLocked(Handed.Left, true) end)
            pressLocked = true
        end
    elseif not down and gripDown then
        gripReleased = true
    end
    gripDown = down
    if swallowGrip or state == S_HOLD or state == S_INSERT or state == S_RACK then
        state_.Gamepad.wButtons = state_.Gamepad.wButtons & ~BTN_LB
        if not down then swallowGrip = false end
    end
    -- the fire trigger is held back while the manual reload waits for the player: a shot cancels the game's reload
    -- (AR 2026-11-19: a trigger pull during the rack wait replaced the reload montage with the fire montage)
    -- Round by round (2026-11-19 design): while waiting for / holding / pushing a round the trigger stays live, so
    -- a shot ends the reload with the rounds already in (the game's own behaviour for tube-fed guns)
    local roundsWait = cur ~= nil and cur.profile ~= nil and cur.profile.style == "rounds" and cur.breakAction == nil and
                       (state == S_AWAIT or state == S_HOLD or state == S_INSERT)
    if state ~= S_IDLE and state ~= S_FINISH and not roundsWait then state_.Gamepad.bRightTrigger = 0 end
end, 26) -- before holsters (25), physical melee (20), hand poses (10), two_handed (5), the LB/LT swap (1)

-- -------------------------------------------------------------------------------------------------------------------
-- tick (post-stereo, once per frame: gun + controller poses of this frame)
-- -------------------------------------------------------------------------------------------------------------------
local lastTick, lastPawn = nil, nil

local function updateOpeners(now)
    local a = cur.openAnim
    if a == nil or cur.openers == nil then return end
    local t = a.dur > 0 and math.min(1.0, (now - a.t0) / a.dur) or 1.0
    local e = a.from + (a.to - a.from) * smooth(t)
    for _, o in ipairs(cur.openers) do
        if o.p.comp ~= nil then
            o.p.boneT = lerpT(o.rest, o.open, e)
            pcall(applyIsolation, o.p)
        end
    end
    if t >= 1.0 and a.to == 1 then
        cur.openAnim = nil -- open: hold there (the copy keeps its boneT)
        -- empty it (2026-11-19): every round falls out backwards; the open copy shows the chambers empty
        local gunW = worldOf(cur.gun)
        for _, o in ipairs(cur.openers) do
            if not o.ejected and #o.rounds > 0 then
                o.ejected = true
                local swing = compose(o.open, inv(o.rest)) -- the part's rigid swing, component space
                -- multi-chamber break action: only the spent ones (a one-shell reload ejects Left only)
                local spent = nil
                local seats = cur.profile.item.seats
                if seats ~= nil then
                    spent = {}
                    for k = 1, math.min(#seats, cur.missing or #seats) do spent[seats[k].bone] = true end
                end
                for k, r in ipairs(o.rounds) do
                  if spent == nil or spent[r.name] then
                    proxyBoneVisible(o.p, r.name, false)
                    local copy = createProxy(cur.gun, cur.profile.item, r.name, compose(swing, r.rest))
                    if copy ~= nil then
                        pcall(function()
                            setWorld(copy.comp, gunW)
                            local back = qrot(gunW.q, { X = -1, Y = 0, Z = 0 })
                            local side = qrot(gunW.q, { X = 0, Y = (k % 2 == 0) and 0.3 or -0.3, Z = 0 })
                            startFall(copy, addV(mulV(back, 70 + 10 * (k % 3)), mulV(side, 40)))
                        end)
                    end
                  end
                end
                haptic(0.03, 0.3)
            end
        end
    end
end

-- Round by round: the held reload montage freezes the gun's own rounds wherever its loop happens to be - the Incendiary
-- Light Revolver showed a round half out of its chamber at the gate (RevolverBullet_01 3.3 cm back from its chamber,
-- 2026-11-19). A round bone out of place relative to its parent (vs its ref-pose local offset) is in transit on the
-- real gun: it is hidden while the manual reload runs; chambered rounds keep their ref offset and stay.
local ROUND_BONE_WORDS = { "bullet", "round", "shell", "cartridge" }
local function transitRoundList(gun)
    local out, byName = {}, {}
    local n = gun:GetNumBones()
    for i = 0, n - 1 do
        local f = gun:GetBoneName(i)
        local name = f:to_string()
        local low = name:lower()
        local isRound = false
        for _, w in ipairs(ROUND_BONE_WORDS) do if low:find(w, 1, true) then isRound = true break end end
        if isRound then
            local parent = gun:GetParentBone(f):to_string()
            local ref = gun:GetRefPoseTransform(i)
            local r = { name = name, f = f, parent = parent, pf = fname(parent),
                        refLoc = { X = ref.Translation.X, Y = ref.Translation.Y, Z = ref.Translation.Z } }
            out[#out + 1] = r
            byName[name] = r
        end
    end
    for _, r in ipairs(out) do r.parentRound = byName[r.parent] end -- parent-first order: a hidden parent hides these
    return out
end

local function updateTransitRounds(gun)
    if cur.transitRounds == nil then cur.transitRounds = transitRoundList(gun) end
    for _, r in ipairs(cur.transitRounds) do
        -- sticky: a hidden bone is no longer evaluated and reads its ref pose, so "back in place" cannot be seen - the
        -- unhide below made it blink every frame (hidden -> reads in -> unhidden -> reads out -> hidden, 2026-11-19).
        -- A round once in transit stays hidden until the reload ends (cleanup unhides cur.hiddenBones).
        if r.hidden or (r.parentRound ~= nil and r.parentRound.hidden) then
            -- hidden, or covered by its hidden parent
        else
            local pT = fromUE(gun:GetSocketTransform(r.pf, RTS_COMPONENT))
            local bT = fromUE(gun:GetSocketTransform(r.f, RTS_COMPONENT))
            local loc = compose(inv(pT), bT).loc
            local off = lenV(subV(loc, r.refLoc)) > 0.5
            if off then
                hideGunBone(gun, r.name, cur.hiddenBones)
                r.hidden = true
            end
        end
    end
end

-- Pour effect on the prop in hand (2026-11-19: "make the goo come out of the canister"). The game spawns its pour
-- effect on the gun (Charged Bio-Mass Shotgun: NS_GooReload on VFX_Reload at the opening, 15 cm under the docked
-- canister). The same system is spawned on our docked copy: at the end of the prop mesh that faces the game's effect,
-- with the game effect's world rotation; it goes with the copy when the pour ends.
local function spawnPourFxOnProp(nativeFx)
    local p = cur.seated
    if p == nil or p.comp == nil or nativeFx == nil then return end
    local okS, errS = pcall(function()
        local asset = nativeFx.Asset
        if asset == nil then return end
        local propW = worldOf(p.comp)
        local fxW = worldOf(nativeFx)
        -- the prop's end facing the effect, from the mesh bounds (prop local space)
        -- GetBounds (Origin / BoxExtent): GetBoundingBox's FBox comes back with lowercase min/max fields here
        local b = meshAsset(p.comp):GetBounds()
        local o, e = b.Origin, b.BoxExtent
        local mn = { X = o.X - e.X, Y = o.Y - e.Y, Z = o.Z - e.Z }
        local mx = { X = o.X + e.X, Y = o.Y + e.Y, Z = o.Z + e.Z }
        local c = { X = (mn.X + mx.X) / 2, Y = (mn.Y + mx.Y) / 2, Z = (mn.Z + mx.Z) / 2 }
        local tgt = compose(inv(propW), fxW).loc
        local d = subV(tgt, c)
        local ax, best = "X", math.abs(d.X)
        if math.abs(d.Y) > best then ax, best = "Y", math.abs(d.Y) end
        if math.abs(d.Z) > best then ax, best = "Z", math.abs(d.Z) end
        local mouth = { X = c.X, Y = c.Y, Z = c.Z }
        mouth[ax] = d[ax] >= 0 and mx[ax] or mn[ax]
        local relQ = qmul(qconj(propW.q), fxW.q)
        local r = q2r(relQ)
        local nfl = uevrUtils.find_default_instance("Class /Script/Niagara.NiagaraFunctionLibrary")
        cur.propFx = nfl:SpawnSystemAttached(asset, p.comp, fname(""), vec(mouth.X, mouth.Y, mouth.Z),
            uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), 0, true, true, 0, false)
        log(string.format("pour fx %s on the prop at (%.1f, %.1f, %.1f), %s end", fullName(asset), mouth.X, mouth.Y, mouth.Z, ax))
    end)
    if not okS then info("pour fx: " .. tostring(errS)) end
end

local function stopPourFx()
    if cur.propFx ~= nil then
        pcall(function() cur.propFx:Deactivate() end)
        pcall(function() cur.propFx:K2_DestroyComponent(cur.propFx) end)
        cur.propFx = nil
    end
end

local function ammoClassOf(weapon)
    local cls = nil
    pcall(function() cls = weapon:GetAmmoPool():GetCurrentAmmoClass() end)
    return cls
end

-- break action: wait for the native reload to finish (it fills the gun), then take back what the manual flow has not
-- loaded yet; what the fill took from the inventory goes back to it
local function updateBreakComplete(now)
    local ba = cur.breakAction
    local reloading = true
    pcall(function() reloading = cur.weapon:IsReloading() end)
    if reloading and now - ba.t0 < 10.0 then return end -- the native reload must be over before the capacity comes back
    -- the game refills a frame AFTER its reload ends, with the capacity it reads then (2026-11-19: over at 2.83 s with
    -- clip 0, capacity restored, then 0 -> 3 at 2.86 s): the capacity stays held a moment longer
    if ba.endT == nil then ba.endT = now end
    if now - ba.endT < 0.3 and now - ba.t0 < 10.0 then return end
    restoreBreakPoolSize()
    local clip = nil
    pcall(function() clip = cur.weapon:GetCurrentAmmoCount() end)
    local spare = spareAmmo(cur.pawn, cur.weapon)
    local want = ba.clip0
    local excess = (clip or want) - want
    if excess > 0 then
        pcall(function() cur.weapon:GetAmmoPool():ConsumeAmmo(excess) end)
        local taken = (ba.spare0 ~= nil and spare ~= nil) and (ba.spare0 - spare) or 0
        if taken > 0 then
            pcall(function()
                local inv_ = uevrUtils.find_default_instance("Class /Script/Arkansas.InventoryComponent")
                inv_:GiveItemToPlayer(ammoClassOf(cur.weapon), math.min(taken, excess), false, false)
            end)
        end
        info(string.format("break action: native reload done (clip %s, spare %s -> %s), %d back out, %d refunded -> clip %s, spare %s",
            tostring(clip), tostring(ba.spare0), tostring(spare), excess, math.max(0, math.min(taken, excess)),
            tostring((function() local c = nil pcall(function() c = cur.weapon:GetCurrentAmmoCount() end) return c end)()),
            tostring(spareAmmo(cur.pawn, cur.weapon))))
    end
    log(string.format("break action: native reload over after %.2f s (reloading %s, clip %s, want %d)", now - ba.t0, tostring(reloading), tostring(clip), want))
    pcall(function() if cur.armsMontage ~= nil then cur.armsAnim:Montage_Stop(0.1, cur.armsMontage) end end)
    pcall(function() if cur.gunMontage ~= nil then cur.gunAnim:Montage_Stop(0.1, cur.gunMontage) end end)
    ba.phase = "manual"
    -- shells seated while the native reload was still running: granted now that the capacity is back
    for _ = 1, (ba.pending or 0) do pcall(function() cur.weapon:GetAmmoPool():RefillAmmo(1, true) end) end
    pcall(function() ba.expect = cur.weapon:GetCurrentAmmoCount() end)
    if (ba.pending or 0) > 0 then log(string.format("break action: %d queued shell(s) granted", ba.pending)) end
    ba.pending = 0
end

-- break action: one shell seated = one round, from the inventory
local function grantBreakShell()
    local before, after = nil, nil
    pcall(function() before = cur.weapon:GetCurrentAmmoCount() end)
    pcall(function() cur.weapon:GetAmmoPool():RefillAmmo(1, true) end)
    pcall(function() after = cur.weapon:GetCurrentAmmoCount() end)
    log(string.format("break action shell: clip %s -> %s, spare %s (%.2f s)", tostring(before), tostring(after), tostring(spareAmmo(cur.pawn, cur.weapon)), os.clock() - cur.breakAction.t0))
    cur.breakAction.expect = after
    return after
end

local function tickBody(now, dt, pressed, released)
    tickProxies(now)
    if state ~= S_IDLE then pcall(updateOpeners, now) pcall(tickBoltOpen, now) end
    if state ~= S_IDLE and cur.breakAction ~= nil and cur.breakAction.phase == "manual" and cur.breakAction.expect ~= nil then
        local c, r = nil, nil
        pcall(function() c = cur.weapon:GetCurrentAmmoCount() end)
        pcall(function() r = cur.weapon:IsReloading() end)
        if c ~= nil and c ~= cur.breakAction.expect then
            info(string.format("break action: clip changed by the game %d -> %d at %.2f s (reloading %s, state %s)",
                cur.breakAction.expect, c, now - cur.breakAction.t0, tostring(r), state))
            cur.breakAction.expect = c
        end
    end
    -- diagnostic (2026-11-19, the canister pour effect): every component that shows up under the arms, the gun or the
    -- game's prop while a prop reload runs, logged once with class / asset / parent / socket
    if state ~= S_IDLE and cur.profile ~= nil and cur.profile.style == "prop" and cur.pawn ~= nil then
        pcall(function()
            cur.seenComps = cur.seenComps or {}
            local roots = { cur.pawn.FPVMesh, cur.gun }
            for _, root in ipairs(roots) do
                local all = {}
                local function walk(c, depth)
                    if depth > 6 then return end
                    for _, k in ipairs(children(c)) do all[#all + 1] = k walk(k, depth + 1) end
                end
                walk(root, 0)
                for _, c in ipairs(all or {}) do
                    local key = tostring(addr(c))
                    if not cur.seenComps[key] then
                        cur.seenComps[key] = true
                        if cur.seenInit then
                            local asset = "-"
                            pcall(function() asset = fullName(c.Asset or c.Template or meshAsset(c)) end)
                            local parent, socket, active = "-", "-", "-"
                            pcall(function() parent = fullName(c.AttachParent) end)
                            pcall(function() socket = c.AttachSocketName:to_string() end)
                            pcall(function() active = tostring(c:IsActive()) end)
                            log(string.format("pour diag: new %s asset %s parent %s socket %s active %s (state %s)",
                                c:get_class():get_fname():to_string(), asset, parent, socket, active, state))
                            if state == S_POUR and cur.profile.pour and c:get_class():get_fname():to_string():find("Niagara", 1, true) then
                                if cur.propFx == nil then spawnPourFxOnProp(c) end
                                -- the game's own stream at the gun's opening goes (2026-11-19); ours on the
                                -- canister stays. Unhidden at cleanup (the game pools these components).
                                if cur.propFx == nil or addr(c) ~= addr(cur.propFx) then
                                    pcall(function() c:SetHiddenInGame(true, true) end)
                                    cur.hidden[#cur.hidden + 1] = c
                                end
                            end
                        end
                    end
                end
            end
            cur.seenInit = true
        end)
    end
    if state ~= S_IDLE and cur.profile ~= nil and cur.profile.style == "prop" and cur.pawn ~= nil then
        pcall(function()
            local arms = cur.pawn.FPVMesh
            local want = cur.profile.item.prop.asset
            for _, c in ipairs(children(arms)) do
                if fullName(meshAsset(c)) == want and not c.bHiddenInGame then
                    c:SetHiddenInGame(true, true)
                    cur.hidden[#cur.hidden + 1] = c
                end
            end
        end)
    end
    if state ~= S_IDLE and cur.breakAction ~= nil and cur.breakAction.phase == "complete" then
        local okB, errB = pcall(updateBreakComplete, now)
        if not okB then info("break action: " .. tostring(errB)) cur.breakAction.phase = "manual" end
    end
    if state ~= S_IDLE and cur.gun ~= nil and cur.profile ~= nil and cur.profile.style == "rounds" then
        local okR, errR = pcall(updateTransitRounds, cur.gun)
        if not okR and not cur.transitErr then cur.transitErr = true info("transit rounds: " .. tostring(errR)) end
    end
    updateFallers(dt)
    local pawn = uevr.api:get_local_pawn(0)
    if pawn ~= lastPawn then
        if lastPawn ~= nil and state ~= S_IDLE then
            cur.hidden, cur.hiddenBones = {}, {}
            for _, k in ipairs({ "held", "seated", "slide" }) do if cur[k] ~= nil and not exists(cur[k].comp) then cur[k].comp = nil end end
            cleanup(false, "pawn changed")
        end
        lastPawn = pawn
    end
    if pawn == nil then destroyPouch() return end

    local weapon, gun = nil, nil
    pcall(function() weapon = pawn:GetCurrentWeapon() end)
    pcall(function() gun = weapon.FPVWeaponMesh end)
    local profile = (weapon ~= nil and _G.ow2ReloadAnalyzer ~= nil) and _G.ow2ReloadAnalyzer.getProfile(weapon) or nil
    local enabled = configui.getValue("mr_enabled") ~= false
    local reason = blocked()

    if state ~= S_IDLE then
        if weapon ~= cur.weapon or gun ~= cur.gun or not exists(cur.gun) then
            cleanup(false, "weapon changed")
        elseif reason == "cutscene" or not enabled then
            cleanup(true, reason or "disabled")
        elseif state ~= S_FINISH and cur.breakAction == nil then
            local am = cur.armsAnim ~= nil and montageOf(cur.armsAnim) or nil
            local gm = cur.gunAnim ~= nil and montageOf(cur.gunAnim) or nil
            local armsOn = cur.armsMontage ~= nil and am ~= nil and addr(am) == addr(cur.armsMontage)
            local gunOn = cur.gunMontage ~= nil and gm ~= nil and addr(gm) == addr(cur.gunMontage)
            -- the game can swap to another reload montage after the first frames (AR empty reload caught at 0.00 s,
            -- then released as "ended" while the native reload played on, 2026-11-19): a new reload montage on a mesh
            -- is adopted and held too; only no reload montage left (and no reload state) ends the manual reload
            local function adopt(anim, m, field, label)
                if m ~= nil and isReloadMontage(m) and (cur[field] == nil or addr(m) ~= addr(cur[field])) then
                    -- held, except while one round is feeding (a section montage swapped in mid-feed keeps running)
                    if state == S_FEED then
                        pcall(function() anim:Montage_SetPlayRate(m, cfgNum("mr_feed_rate", 10.0)) end)
                    else
                        holdMontage(anim, m, cur.profile ~= nil and (cur.profile.style == "rounds" or cur.profile.style == "prop"))
                    end
                    info("holding " .. label .. " montage " .. tostring(montageName(m)) .. (cur[field] ~= nil and (" (replaced " .. tostring(montageName(cur[field])) .. ")") or ""))
                    cur[field] = m
                    return true
                end
                return false
            end
            local adoptedArms = (not armsOn) and adopt(cur.armsAnim, am, "armsMontage", "arm") or false
            local adoptedGun = (not gunOn) and adopt(cur.gunAnim, gm, "gunMontage", "weapon") or false
            if not armsOn and not gunOn and not adoptedArms and not adoptedGun then
                local reloading = false
                pcall(function() reloading = cur.weapon:IsReloading() end)
                cleanup(false, "the game ended its reload (arms " .. tostring(montageName(am)) .. ", weapon " ..
                    tostring(montageName(gm)) .. ", reloading " .. tostring(reloading) .. ")")
            end
        end
    end

    local ok, why = supported(profile)
    -- round-by-round guns: the native fill timer is held off while manual reload will take the reload (set while idle:
    -- the timer is armed when the reload starts); the analyzer recording a reload gets the game's own timing
    if state == S_IDLE and weapon ~= nil then
        local wants = false
        pcall(function() wants = _G.ow2ReloadAnalyzer ~= nil and _G.ow2ReloadAnalyzer.wantsReload() == true end)
        -- any variant still to learn keeps the game's own timing: an empty magazine starts its reload in the same frame
        -- the clip hits 0, before this idle tick sees the analyzer want it - the Holographic Repeating Rifle's empty
        -- re-learn armed with 1000 s and crawled at 0.00225x (2026-11-19)
        if profile ~= nil then
            local rec_ = profile.recorded or {}
            if rec_.tactical == nil or (profile.hasEmptyReload and rec_.empty == nil) then wants = true end
        end
        local hold = enabled and ok and profile ~= nil and (profile.style == "rounds" or (profile.style == "prop" and profile.reloadType == 1)) and profile.reloadType ~= 2 and not wants
        local okT, errT = pcall(updateRoundsTimer, weapon, hold)
        if not okT then log("rounds timer: " .. tostring(errT)) end
    end
    if not enabled or weapon == nil or gun == nil or not ok or reason ~= nil then
        if state == S_IDLE then
            destroyPouch()
            status(not enabled and "off" or (weapon == nil and "no gun") or (reason ~= nil and ("paused (" .. reason .. ")")) or ("native reload: " .. tostring(why)))
        end
        if state == S_IDLE then return end
    end

    if state == S_IDLE then
        tryIntercept(pawn, weapon, gun, profile)
    end
    local spare = spareAmmo(pawn, weapon) or 0
    if spare > 0 and (state == S_IDLE or state == S_AWAIT) and ok then updatePouch(gun, profile) else destroyPouch() end

    if state == S_IDLE then
        status(string.format("%s ready (%d spare)", tostring(profile and profile.name), spare))
    elseif state == S_AWAIT then
        status(cur.profile.style == "rounds" and string.format("take a round from the left hip (%d in, trigger = done)", cur.loaded or 0)
               or "take a magazine from the left hip (left grip)")
        if pressed and nearPouch then
            if not grabFromPouch() then swallowGrip = false end
        end
    elseif state == S_HOLD then
        status(cur.profile.style == "rounds" and "push the round into the gun" or "push the magazine into the gun")
        if not updateHeld() then
            enter(S_AWAIT)
        elseif released or not gripDown then
            dropHeld()
            enter(S_AWAIT)
        elseif wellDistance() <= (cur.profile.style == "rounds" and cfgNum("mr_round_insert_radius", 12.0) or cfgNum("mr_insert_radius", 7.0)) then
            startInsert()
        end
    elseif state == S_INSERT then
        if updateInsert() then
            haptic(0.04, 0.8)
            log("seated")
            if cur.profile.style == "prop" then
                -- docked: the canister stays over the opening, the native reload pours (Charged Bio-Mass Shotgun 2026-11-19:
                -- one round every ~0.06 s for 1.3 s at 1x)
                local clipP = nil
                pcall(function() clipP = cur.weapon:GetCurrentAmmoCount() end)
                cur.pour = { t0 = now, clip = clipP or 0 }
                local rate = cfgNum("mr_pour_rate", 3.0)
                pcall(function() if cur.armsMontage ~= nil then cur.armsAnim:Montage_SetPlayRate(cur.armsMontage, rate) cur.armsAnim:Montage_Resume(cur.armsMontage) end end)
                pcall(function() if cur.gunMontage ~= nil then cur.gunAnim:Montage_SetPlayRate(cur.gunMontage, rate) cur.gunAnim:Montage_Resume(cur.gunMontage) end end)
                enter(S_POUR)
            elseif cur.profile.style == "rounds" then
                -- the round went in: the copy is gone, the native reload runs until the clip is one up
                if cur.seated ~= nil then destroyProxy(cur.seated) cur.seated = nil end
                if cur.seatBone ~= nil then
                    for _, o in ipairs(cur.openers or {}) do proxyBoneVisible(o.p, cur.seatBone, true) end
                end
                if cur.breakAction ~= nil then
                    local clipB = nil
                    if cur.breakAction.phase == "complete" then
                        cur.breakAction.pending = (cur.breakAction.pending or 0) + 1
                        clipB = cur.breakAction.clip0 + (cur.loaded or 0) + 1
                    else
                        clipB = grantBreakShell()
                    end
                    cur.loaded = (cur.loaded or 0) + 1
                    local fullB = (cur.profile.poolSize ~= nil and clipB ~= nil and clipB >= cur.profile.poolSize) or cur.loaded >= (cur.missing or 0)
                    local spareB = spareAmmo(cur.pawn, cur.weapon) or 0
                    if fullB or spareB <= 0 then
                        cur.closeT0 = now
                        enter(S_CLOSE)
                    else
                        selectRoundSeat()
                        enter(S_AWAIT)
                    end
                    return
                end
                local clip = nil
                pcall(function() clip = cur.weapon:GetCurrentAmmoCount() end)
                cur.feed = { clip = clip or 0, t0 = now }
                local rate = cfgNum("mr_feed_rate", 10.0)
                pcall(function() if cur.armsMontage ~= nil then cur.armsAnim:Montage_SetPlayRate(cur.armsMontage, rate) cur.armsAnim:Montage_Resume(cur.armsMontage) end end)
                pcall(function() if cur.gunMontage ~= nil then cur.gunAnim:Montage_SetPlayRate(cur.gunMontage, rate) cur.gunAnim:Montage_Resume(cur.gunMontage) end end)
                enter(S_FEED)
            elseif cur.openers ~= nil and #cur.openers > 0 then
                cur.closeT0 = now
                enter(S_CLOSE)
            elseif cur.rack ~= nil then enter(S_AWAIT_RACK) else startFinish() end
        end
    elseif state == S_POUR then
        status("pouring")
        local clip = nil
        pcall(function() clip = cur.weapon:GetCurrentAmmoCount() end)
        if clip ~= nil and clip > cur.pour.clip then cur.pour.clip, cur.pour.lastInc = clip, now end
        local full = cur.profile.poolSize ~= nil and clip ~= nil and clip >= cur.profile.poolSize
        local dry = (spareAmmo(cur.pawn, cur.weapon) or 0) <= 0
        local stalled = cur.pour.lastInc ~= nil and now - cur.pour.lastInc > 0.6
        if full or dry or stalled or now - cur.pour.t0 > 8.0 then
            holdMontage(cur.armsAnim, cur.armsMontage, true)
            holdMontage(cur.gunAnim, cur.gunMontage, true)
            log(string.format("pour done: clip %s (%s)", tostring(clip), full and "full" or (dry and "no spare" or (stalled and "stalled" or "timeout"))))
            -- the empty canister drops away, the lid closes by itself (a flick is for cylinders and barrels)
            stopPourFx()
            if cur.seated ~= nil then
                local p = cur.seated
                cur.seated = nil
                if cur.profile.pour then
                    startFall(p, { X = 0, Y = 0, Z = -40 }) -- the empty canister
                else
                    destroyProxy(p) -- an inserted prop (the Shock MG's rod) went into the gun
                end
            end
            if cur.openers ~= nil and #cur.openers > 0 then
                cur.closeT0 = now
                cur.openAnim = { t0 = now, from = 1, to = 0, dur = 0.15 }
                enter(S_CLOSE)
            else
                startFinish()
            end
        end
    elseif state == S_FEED then
        status("loading")
        local clip = nil
        pcall(function() clip = cur.weapon:GetCurrentAmmoCount() end)
        -- the round counted: keep running for the learned settle time (the cylinder turns to the next chamber), then hold
        if clip ~= nil and clip > cur.feed.clip and cur.feed.settleAt == nil then
            -- the settle runs at 1x: at the feed rate one frame is ~0.1 s of montage, too coarse for the quiet moment
            -- the first round of a reload runs the montage's first section, the rest its loop section
            local settle = cur.profile.feedSettle or 0
            if (cur.loaded or 0) == 0 and cur.profile.feedSettleFirst ~= nil then settle = cur.profile.feedSettleFirst end
            if settle > 0 then
                pcall(function() if cur.armsMontage ~= nil then cur.armsAnim:Montage_SetPlayRate(cur.armsMontage, 1.0) end end)
                pcall(function() if cur.gunMontage ~= nil then cur.gunAnim:Montage_SetPlayRate(cur.gunMontage, 1.0) end end)
            end
            cur.feed.settleAt = now + settle
        end
        if cur.feed.settleAt ~= nil and now >= cur.feed.settleAt then
            holdMontage(cur.armsAnim, cur.armsMontage, true)
            holdMontage(cur.gunAnim, cur.gunMontage, true)
            clip = clip or (cur.feed.clip + 1)
            cur.loaded = (cur.loaded or 0) + (clip - cur.feed.clip)
            local full = cur.profile.poolSize ~= nil and clip >= cur.profile.poolSize
            local spare = spareAmmo(cur.pawn, cur.weapon) or 0
            log(string.format("round in: clip %d (%d loaded, %d spare)", clip, cur.loaded, spare))
            if full or spare <= 0 then
                if cur.profile.item.seats ~= nil and cur.openers ~= nil and #cur.openers > 0 then
                    cur.closeT0 = now
                    enter(S_CLOSE)
                else
                    startFinish()
                end
            else
                selectRoundSeat()
                enter(S_AWAIT)
            end
        elseif cur.feed.settleAt == nil and now - cur.feed.t0 > FEED_TIMEOUT_S then
            log("feed: no round counted - finishing natively")
            startFinish()
        end
    elseif state == S_CLOSE then
        -- the docked item stays a moment (rounds go in), leaves, then the part swings shut
        status("closing")
        if cur.seated ~= nil and cur.profile.item.docked and now - cur.closeT0 >= 0.15 then
            destroyProxy(cur.seated)
            cur.seated = nil
            for _, o in ipairs(cur.openers or {}) do
                for _, r in ipairs(o.rounds or {}) do proxyBoneVisible(o.p, r.name, true) end
            end
        end
        if cur.openAnim == nil and now - cur.closeT0 >= 0.15 then
            -- 2026-11-19: a flick of the gun in the part's closing direction swings it shut
            local dir = nil
            -- the part that holds the rounds sets the direction (the Charged Triple Barrel Shotgun's barrel, not its
            -- lock lever, which has no rounds and only a guessed direction)
            -- Only a part that carries the rounds is flicked shut (cylinder, break barrel). Parts without rounds have
            -- only a guessed direction and close by themselves (2026-11-20, Remote Detonator: the game holds its two
            -- clip release latches open from 0.035 s to after the ammo, so they were learned as openers, and the reload
            -- sat at "flick the gun to close it" while the player worked the bolt).
            for _, o in ipairs(cur.openers) do if o.closeDir ~= nil and #o.rounds > 0 then dir = o.closeDir break end end
            local flicked = configui.getValue("mr_flick_close") == false or dir == nil
            if not flicked then
                status("flick the gun to close it")
                local gunW = worldOf(cur.gun)
                if cur.flickPrev ~= nil and dt > 0 then
                    local v = mulV(subV(gunW.loc, cur.flickPrev), 1 / dt)
                    local speed = dotV(v, qrot(gunW.q, dir))
                    if speed >= cfgNum("mr_flick_speed", 110.0) then flicked = true end
                end
                cur.flickPrev = gunW.loc
            end
            if flicked then cur.openAnim = { t0 = now, from = 1, to = 0, dur = 0.12 } end
        end
        if cur.openAnim ~= nil and cur.openAnim.to == 0 and now - cur.openAnim.t0 >= cur.openAnim.dur then
            haptic(0.04, 0.7)
            if cur.breakAction ~= nil then
                local clipE = nil
                pcall(function() clipE = cur.weapon:GetCurrentAmmoCount() end)
                info(string.format("reload done: clip %s -> %s (break action)", tostring(cur.clipBefore), tostring(clipE)))
                cleanup(false, "done")
            elseif cur.rack ~= nil then enter(S_AWAIT_RACK) else startFinish() end
        end
    elseif state == S_AWAIT_RACK or state == S_RACK then
        if cur.rack ~= nil and cur.rack.crank then status(state == S_RACK and "wind it round (re-grab to keep going)" or "wind the crank (left grip on it)")
        else status(state == S_RACK and "pull it back and let go" or "rack the slide (left grip on it)") end
        updateRack(now, pressed, released)
    elseif state == S_FINISH then
        status("reloading...")
        if finishDone() or now - cur.finishT0 > FINISH_TIMEOUT_S then
            local clip = nil
            pcall(function() clip = cur.weapon:GetCurrentAmmoCount() end)
            info(string.format("reload done: clip %s -> %s", tostring(cur.clipBefore), tostring(clip)))
            haptic(0.02, 0.3)
            cleanup(false, "done")
        end
    end
end

local function tick()
    local now = os.clock()
    local dt = lastTick ~= nil and math.min(0.1, now - lastTick) or 0.016
    lastTick = now
    local pressed, released, locked = gripPressed, gripReleased, pressLocked
    gripPressed, gripReleased, pressLocked = false, false, false
    local ok, err = pcall(tickBody, now, dt, pressed, released)
    if not ok then info(string.format("tick error (state %s): %s", state, tostring(err))) end
    pcall(tickRackHand, now)
    -- a press locked the hand for a grab that did not happen: give the hand its input back
    if locked and not fingers.active and state ~= S_HOLD and state ~= S_RACK then lockLeftInput(false) end
end

local ranThisTick = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisTick = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ranThisTick or not vr.is_hmd_active() then return end
    ranThisTick = true
    tick()
end)

-- Reset scripts: the Lua state goes, the components stay. Every copy alive at that moment (the hip copy above all) was
-- left standing in the world, one per reset (2026-11-19: 3 Volted Sniper clips + Repeating Rifle rounds at old hip
-- spots, loose and visible). A reload in progress goes back to the game, every copy is destroyed, the finger pose is
-- undone and a round-by-round gun gets its own reload times back.
uevr.sdk.callbacks.on_script_reset(function()
    pcall(restoreBreakPoolSize)
    pcall(function() if state ~= S_IDLE then cleanup(true, "script reset") end end)
    pcall(destroyPouch)
    for i = #proxies, 1, -1 do pcall(destroyProxy, proxies[i]) end
    proxies, fallers = {}, {}
    pcall(restoreFingerLocals, fingers)
    pcall(function() lockLeftInput(false) end)
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local weapon = pawn ~= nil and pawn:GetCurrentWeapon() or nil
        if weapon ~= nil then updateRoundsTimer(weapon, false) end
    end)
end)

uevrUtils.registerPreLevelChangeCallback(function()
    -- everything belonged to the old world: forget without touching it
    proxies, fallers, pouch = {}, {}, nil
    fingers = {}
    lockLeftInput(false)
    rackHand = nil
    cur = {}
    lastPawn, swallowGrip, nearPouch, nearRack = nil, false, false, false
    enter(S_IDLE)
end)

info("loaded")
