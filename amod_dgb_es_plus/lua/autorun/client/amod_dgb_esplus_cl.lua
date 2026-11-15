if SERVER then return end

D_AM = D_AM or {}
if D_AM.ESPlus and D_AM.ESPlus.StopAll then pcall(D_AM.ESPlus.StopAll) end

D_AM.ESPlus = D_AM.ESPlus or {}
local ESPlus = D_AM.ESPlus
ESPlus.Version = "2.1"
ESPlus.Configs, ESPlus.Index, ESPlus.Active = {}, {}, {}

local VEC_ZERO, ANG_ZERO = Vector(0, 0, 0), Angle(0, 0, 0)
local COLOR_WHITE, COLOR_LIGHT = Color(255, 255, 255), Color(255, 200, 100)
local DEFAULT_MODEL = "models/editor/player_ball.mdl"
local DEFAULT_MATERIAL = "sprites/light_glow02_add"
local DEFAULT_FPS = 30
local GRACE = 0.5
local STOP_GRACE = 0.25

local cvEnabled = CreateConVar("amod_esplus_enabled", "1", FCVAR_ARCHIVE, "Enable ES+ (0/1)")
local cvDebug = CreateConVar("amod_esplus_debug", "0", FCVAR_ARCHIVE, "Print ES+ events (0/1)")
local cvHud = CreateConVar("amod_esplus_hud", "0", FCVAR_NONE, "Show the dance time/frame on screen")

-- logging
local warned = {}

local function Log(...)
    if cvDebug:GetBool() then print("[ES+]", ...) end
end

local function Warn(...)
    print("[ES+ WARNING]", ...)
end

local function WarnOnce(key, ...)
    if warned[key] then return end
    warned[key] = true
    Warn(...)
end

local function Try(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    Warn(res)
end

-- config validation
local EMPTY = {}
local function Tbl(v) return istable(v) and v or EMPTY end

local function KeySet(...)
    local set = {}
    for _, list in ipairs({ ... }) do
        for _, k in ipairs(list) do set[k] = true end
    end
    return set
end

local TOP_KEYS = KeySet({ "models", "lights", "particles", "pcfs", "enabled", "fps", "framesource", "totalframes" })
local COMMON_KEYS = { "enabled", "target", "attach", "bone", "boneId", "pos", "offset", "ang", "start", "stop", "startframe", "stopframe", "timeline" }
local KEYS = {
    model = KeySet(COMMON_KEYS, { "model", "scale", "color", "alpha", "mat", "anim", "playbackrate", "syncanim", "shadow", "frameadvance" }),
    light = KeySet(COMMON_KEYS, { "color", "brightness", "distance", "size", "decay", "noworld",
        "blink", "blinkduty", "colors", "colorinterval", "colorfade" }),
    particle = KeySet(COMMON_KEYS, { "material", "count", "speed", "gravity", "life", "size", "sizeend", "alpha", "alphaend",
        "color", "colors", "spread", "interval", "bones", "bonepick", "colorpick",
        "roll", "rolldelta", "airres", "collide", "bounce", "lighting", "startlength", "endlength", "velocityscale" }),
    pcf = KeySet(COMMON_KEYS, { "effect", "pcf", "attachment", "cps" }),
}
local LIST_KIND = { models = "model", lights = "light", particles = "particle", pcfs = "pcf" }

local function ValidateConfig(name, cfg)
    local function W(...) Warn("[" .. name .. "]", ...) end

    for k in pairs(cfg) do
        if not TOP_KEYS[k] then W("unknown key:", k) end
    end
    if cfg.framesource ~= nil and cfg.framesource ~= "time" and cfg.framesource ~= "cycle" then
        W('framesource must be "time" or "cycle"')
    end

    for listKey, kind in pairs(LIST_KIND) do
        local known = KEYS[kind]
        for i, def in ipairs(Tbl(cfg[listKey])) do
            def = Tbl(def)
            local label = kind .. " " .. i .. ":"

            for k in pairs(def) do
                if not known[k] then W(label, "unknown key:", k) end
            end
            for si, step in ipairs(Tbl(def.timeline)) do
                local set = Tbl(Tbl(step).set)
                if next(set) == nil then W(label, "timeline step", si, "needs a 'set' table") end
                for k in pairs(set) do
                    if k == "timeline" or not known[k] then W(label, "timeline step", si, "invalid key:", k) end
                end
            end

            if kind == "model" then
                local path = def.model or DEFAULT_MODEL
                -- util.IsValidModel alone gives false negatives while loading...
                if not (isstring(path) and (file.Exists(path, "GAME") or util.IsValidModel(path))) then
                    W(label, "model not found:", tostring(path))
                end
            elseif kind == "particle" then
                local mat = def.material or DEFAULT_MATERIAL
                if not isstring(mat) or Material(mat):IsError() then W(label, "invalid material:", tostring(mat)) end
            elseif kind == "pcf" and not isstring(def.effect) and not def.timeline then
                W(label, "missing 'effect' name")
            end
            if def.target and not Tbl(cfg.models)[def.target] then W(label, "invalid target:", def.target) end
        end
    end
end

-- config loading
function ESPlus.Register(tbl)
    if not istable(tbl) then return 0 end
    local n = 0
    for name, cfg in pairs(tbl) do
        if isstring(name) and istable(cfg) then
            n = n + 1
            local existing = ESPlus.Configs[name]
            if not existing then
                ESPlus.Configs[name] = cfg
            else
                for _, key in ipairs({ "models", "lights", "particles", "pcfs" }) do
                    if istable(cfg[key]) then
                        existing[key] = existing[key] or {}
                        table.Add(existing[key], cfg[key])
                    end
                end
                for _, key in ipairs({ "fps", "framesource", "totalframes", "enabled" }) do
                    if cfg[key] ~= nil then existing[key] = cfg[key] end
                end
            end
            ESPlus.Index[string.lower(name)] = name
            Try(ValidateConfig, name, ESPlus.Configs[name])
        end
    end
    return n
end

local function LoadFile(path)
    local fn = CompileFile(path)
    if not fn then
        Warn("failed to compile (syntax error, or the server did not AddCSLuaFile it):", path)
        return
    end
    local ok, tbl = xpcall(fn, debug.traceback)
    if not ok then
        Warn("error running config", path, "\n" .. tostring(tbl))
    elseif not istable(tbl) then
        Warn("config must return a table:", path)
    else
        Log("loaded", path, "->", ESPlus.Register(tbl), "dance(s)")
    end
end

local function ScanDir(dir, depth)
    local files, dirs = file.Find(dir .. "/*", "LUA")
    files, dirs = files or {}, dirs or {}
    for _, name in ipairs(files) do
        if string.lower(string.sub(name, -4)) == ".lua" then LoadFile(dir .. "/" .. name) end
    end
    if depth < 4 then
        for _, sub in ipairs(dirs) do ScanDir(dir .. "/" .. sub, depth + 1) end
    end
end

local function LoadConfigs()
    ESPlus.Configs, ESPlus.Index = {}, {}
    ScanDir("actmod/am_es", 0)
    local total = table.Count(ESPlus.Configs)
    Log(total, "dance(s) configured")
    if total == 0 then
        Warn("no configs loaded (check lua/actmod/am_es and AddCSLuaFile on the server)")
    end
end

local function ResolveConfig(actName)
    if not isstring(actName) then return end
    if ESPlus.Configs[actName] then return ESPlus.Configs[actName], actName end

    local lname = string.lower(actName)
    local variants = { lname }
    local base = string.match(lname, "^(.-)_leader$") or string.match(lname, "^(.-)_joiner$")
    if base then variants[2] = base end

    for _, v in ipairs(variants) do
        local key = ESPlus.Index[v]
        if key then return ESPlus.Configs[key], key end

        -- actmod prefixes names
        local bestKey, bestLen
        for lk, k in pairs(ESPlus.Index) do
            if #lk < #v and string.sub(v, -(#lk + 1)) == "_" .. lk and (not bestLen or #lk > bestLen) then
                bestKey, bestLen = k, #lk
            end
        end
        if bestKey then return ESPlus.Configs[bestKey], bestKey end
    end
end

-- dance clock
local function GetAnimMeta(state)
    local ent = state.ent
    local seq = ent:GetSequence()
    if state.metaSeq ~= seq then
        state.metaSeq = seq
        state.metaFrames, state.metaFps = nil, nil

        local okI, info = pcall(ent.GetSequenceInfo, ent, seq)
        if okI and istable(info) and istable(info.anims) and info.anims[1] and ent.GetAnimInfo then
            local okA, ai = pcall(ent.GetAnimInfo, ent, info.anims[1])
            if okA and istable(ai) then
                if isnumber(ai.numframes) and ai.numframes > 1 then state.metaFrames = ai.numframes - 1 end
                if isnumber(ai.fps) and ai.fps > 0 then state.metaFps = ai.fps end
            end
        end
        if not state.metaFrames then
            local okD, dur = pcall(ent.SequenceDuration, ent, seq)
            if okD and isnumber(dur) and dur > 0 then
                state.metaFrames = dur * (state.cfgFps or state.metaFps or DEFAULT_FPS)
            end
        end
    end
    return state.metaFrames, state.metaFps
end

-- returns seconds since the dance started, current frame, fps used
local function GetClock(state)
    local ent = state.ent
    local t = CurTime() - state.startTime
    local frames, animFps
    if IsValid(ent) then frames, animFps = GetAnimMeta(state) end
    local fps = state.cfgFps or animFps or DEFAULT_FPS

    local f
    if state.framesource == "cycle" and IsValid(ent) then
        local total = state.cfgTotal or frames
        if total and total > 0 then f = ent:GetCycle() * total end
    end
    return t, f or t * fps, fps
end

-- windows, timeline, timed colors
local function IsEffectActive(def, t, f)
    if def.enabled == false then return false end
    if def.start and t < def.start then return false end
    if def.startframe and f < def.startframe then return false end
    if def.stop and def.stop > 0 and t > def.stop then return false end
    if def.stopframe and def.stopframe > 0 and f > def.stopframe then return false end
    return true
end

-- fallback "previous value" for blends when the base config doesn't define the field
local DEFAULTS = {
    model = { scale = 1, alpha = 255, color = COLOR_WHITE, pos = VEC_ZERO, ang = ANG_ZERO, playbackrate = 1 },
    light = { brightness = 2, distance = 200, size = 200, decay = 1, color = COLOR_LIGHT, pos = VEC_ZERO, ang = ANG_ZERO },
    particle = { count = 20, speed = 30, gravity = 100, life = 1, size = 3, sizeend = 0, alpha = 255, alphaend = 0,
        spread = 1, color = COLOR_WHITE, pos = VEC_ZERO, ang = ANG_ZERO },
    pcf = { pos = VEC_ZERO, ang = ANG_ZERO },
}

local function LerpValue(a, b, p)
    if isnumber(a) and isnumber(b) then return Lerp(p, a, b) end
    if isvector(a) and isvector(b) then return LerpVector(p, a, b) end
    if isangle(a) and isangle(b) then return LerpAngle(p, a, b) end
    if IsColor(a) and IsColor(b) then
        return Color(Lerp(p, a.r, b.r), Lerp(p, a.g, b.g), Lerp(p, a.b, b.b), Lerp(p, a.a or 255, b.a or 255))
    end
end

-- Returns def itself when it has no timeline (zero cost); otherwise a reused table
-- that falls back to def for every key the timeline hasn't touched yet
local function ResolveDef(def, rec, t, f, fps)
    local steps = def.timeline
    if not istable(steps) then return def end

    local eff = rec.eff
    if not eff then
        eff = setmetatable({}, { __index = def })
        rec.eff, rec.settled = eff, {}
    end
    local settled = rec.settled
    table.Empty(eff)
    table.Empty(settled)
    local defaults = DEFAULTS[rec.kind]

    for _, step in ipairs(steps) do
        local set = istable(step) and step.set
        if istable(set) then
            local at = step.at or step.time
            local elapsed, dur
            if at ~= nil then
                elapsed = t - at
                dur = step.blend or (step.blendframes and step.blendframes / fps) or 0
            elseif step.frame ~= nil then
                elapsed = f - step.frame
                dur = step.blendframes or (step.blend and step.blend * fps) or 0
            else
                elapsed, dur = t, step.blend or 0
            end

            if elapsed >= 0 then
                for k, v in pairs(set) do
                    local prev = settled[k]
                    if prev == nil then prev = def[k] end
                    if prev == nil and defaults then prev = defaults[k] end
                    settled[k] = v

                    local val = v
                    if dur > 0 and elapsed < dur and prev ~= nil then
                        local lv = LerpValue(prev, v, elapsed / dur)
                        if lv ~= nil then val = lv end
                    end
                    eff[k] = val
                end
            end
        end
    end
    return eff
end

local function BuildActiveColors(def, rec, t, f)
    local src = def.colors
    if not istable(src) or #src == 0 then return nil end
    local list = rec.colorScratch
    if not list then
        list = {}
        rec.colorScratch = list
    end
    for i = #list, 1, -1 do list[i] = nil end
    for _, e in ipairs(src) do
        if istable(e) then
            if e.r ~= nil then
                list[#list + 1] = e
            elseif e.color ~= nil and IsEffectActive(e, t, f) then
                list[#list + 1] = e.color
            end
        end
    end
    return list
end

-- transform
local function LocalOffset(ang, off)
    return ang:Right() * off.x + ang:Forward() * off.y + ang:Up() * off.z
end

local function BaseAngles(ent)
    if ent:IsPlayer() then return Angle(0, ent:GetRenderAngles().y, 0) end
    return ent:GetAngles()
end

local function GetEntityFor(state, def)
    if def.target then
        local m = state.models[def.target]
        if m and IsValid(m.ent) then return m.ent end
    end
    return state.ent
end

local function GetBoneIndex(ent, def, rec)
    local b = def.bone
    if b == nil then return nil end
    if isnumber(b) then return b end
    if rec.boneEnt ~= ent or rec.boneName ~= b then
        local id = ent:LookupBone(b)
        if id and id < 0 then id = nil end
        rec.boneId, rec.boneEnt, rec.boneName = id, ent, b
        if not id then Warn("bone not found:", b, "on", ent:GetModel()) end
    end
    return rec.boneId
end

local function GetBonePosAng(ent, bone)
    local m = ent:GetBoneMatrix(bone)
    if m then return m:GetTranslation(), m:GetAngles() end
    return ent:GetBonePosition(bone)
end

local function BonePos(ent, bone, off)
    local bp, ba = GetBonePosAng(ent, bone)
    if not bp then return ent:GetPos() end
    if off and ba then bp = bp + LocalOffset(ba, off) end
    return bp
end

local function ComputeTransform(state, def, rec)
    local ent = GetEntityFor(state, def)
    if not IsValid(ent) then return end
    local off = def.pos or def.offset or VEC_ZERO
    local aoff = def.ang or ANG_ZERO
    local attach = def.attach or "bone"

    if attach == "static" then
        return (state.worldPos or ent:GetPos()) + off, aoff
    end

    local pPos, pAng = ent:GetPos(), BaseAngles(ent)
    if attach == "world" then
        return pPos + LocalOffset(pAng, off), pAng + aoff
    end
    if attach == "manual" then
        return pPos + LocalOffset(pAng, off), pAng + aoff
    end

    local bone = def.boneId
    if bone == nil then bone = GetBoneIndex(ent, def, rec) end
    if bone then
        local bp, ba = GetBonePosAng(ent, bone)
        if bp and ba then
            return bp + LocalOffset(ba, off), ba + aoff
        end
        WarnOnce("nobone" .. tostring(ent) .. tostring(bone), "no position for bone", bone, "- using fallback")
    end
    return pPos + pAng:Up() * 50 + off, pAng + aoff
end

-- creation
local function CreateModelEffect(def, idx)
    local path = def.model or DEFAULT_MODEL
    util.PrecacheModel(path)
    local mdl = ents.CreateClientProp(path)
    if not IsValid(mdl) then
        Warn("model", idx, "- CreateClientProp failed for", path)
        return
    end
    mdl:Spawn()
    mdl:SetSolid(SOLID_NONE)
    mdl:SetMoveType(MOVETYPE_NONE)
    pcall(mdl.PhysicsDestroy, mdl)
    mdl:SetNoDraw(true)
    return mdl
end

local function ResolveParticleBones(ent, bones)
    local out = {}
    if bones == "all" or bones == true then
        for i = 0, ent:GetBoneCount() - 1 do
            local name = ent:GetBoneName(i)
            if name and name ~= "" and name ~= "__INVALIDBONE__" then out[#out + 1] = i end
        end
    else
        for _, b in ipairs(istable(bones) and bones or { bones }) do
            local id = isnumber(b) and b or (isstring(b) and ent:LookupBone(b))
            if id and id >= 0 then out[#out + 1] = id else Warn("particle: bone not found:", tostring(b)) end
        end
    end
    if #out == 0 then out[1] = 0 end
    return out
end

local function CreateParticleEffect(state, def, idx)
    local ent = GetEntityFor(state, def)
    if not IsValid(ent) then
        Warn("particle", idx, "- invalid target entity")
        return
    end
    local em = ParticleEmitter(ent:GetPos(), false)
    if not em then
        Warn("particle", idx, "- ParticleEmitter failed")
        return
    end
    return { em = em, cursor = 1, acc = 0 }
end

local function CreateAll(ply, cfg, actName)
    local state = {
        ent = ply,
        cfg = cfg,
        dance = actName,
        startTime = CurTime(),
        worldPos = ply:GetPos(),
        models = {},
        lights = {},
        particles = {},
        pcfs = {},
        framesource = (cfg.framesource == "cycle") and "cycle" or "time",
        cfgFps = (isnumber(cfg.fps) and cfg.fps > 0) and cfg.fps or nil,
        cfgTotal = (isnumber(cfg.totalframes) and cfg.totalframes > 0) and cfg.totalframes or nil,
        t = 0, f = 0, fps = DEFAULT_FPS,
    }
    for i, def in ipairs(Tbl(cfg.models)) do
        state.models[i] = { def = def, id = i, kind = "model", curModel = def.model or DEFAULT_MODEL, ent = Try(CreateModelEffect, def, i) }
    end
    for i, def in ipairs(Tbl(cfg.lights)) do
        state.lights[i] = { def = def, id = i, kind = "light", dlid = 20000 + ply:EntIndex() * 16 + i }
    end
    for i, def in ipairs(Tbl(cfg.particles)) do
        state.particles[i] = { def = def, id = i, kind = "particle", fx = Try(CreateParticleEffect, state, def, i) }
    end
    for i, def in ipairs(Tbl(cfg.pcfs)) do
        state.pcfs[i] = { def = def, id = i, kind = "pcf" }
    end
    return state
end

-- update
local function UpdateModel(state, m, t, f, fps, dt)
    local mdl = m.ent
    if not IsValid(mdl) then return end

    local def = ResolveDef(m.def, m, t, f, fps)
    local active = IsEffectActive(def, t, f)
    m.visible = active
    mdl:SetNoDraw(not active)
    if not active then return end

    local path = def.model or DEFAULT_MODEL
    if isstring(path) and m.curModel ~= path then
        util.PrecacheModel(path)
        mdl:SetModel(path)
        m.curModel = path
        m.lastScale, m.lastAnim, m.lastRate = nil, nil, nil
    end

    local pos, ang = ComputeTransform(state, def, m)
    if pos then
        mdl:SetPos(pos)
        mdl:SetAngles(ang)
    end

    local scale = def.scale or 1
    if m.lastScale ~= scale then
        mdl:SetModelScale(scale, 0)
        m.lastScale = scale
    end

    local col, alpha = def.color or COLOR_WHITE, def.alpha or 255
    if m.lastColor ~= col or m.lastAlpha ~= alpha then
        mdl:SetRenderMode(alpha < 255 and RENDERMODE_TRANSALPHA or RENDERMODE_NORMAL)
        mdl:SetColor(Color(col.r or 255, col.g or 255, col.b or 255, alpha))
        m.lastColor, m.lastAlpha = col, alpha
    end

    local shadow = def.shadow ~= false
    if m.lastShadow ~= shadow then
        if m.lastShadow ~= nil or not shadow then mdl:DrawShadow(shadow) end
        m.lastShadow = shadow
    end

    local mat = def.mat or false
    if m.lastMat ~= mat then
        if mat or m.lastMat then mdl:SetMaterial(mat or "") end
        m.lastMat = mat
    end

    local anim = def.anim or false
    if m.lastAnim ~= anim then
        m.lastAnim = anim
        if anim then
            local seq = mdl:LookupSequence(anim)
            if seq and seq >= 0 then
                mdl:ResetSequence(seq)
                mdl:SetCycle(0)
                m.lastRate = nil
            else
                Warn("model", m.id, "- sequence not found:", tostring(anim))
            end
        end
    end

    if def.syncanim then
        mdl:SetCycle(state.ent:GetCycle())
        mdl:SetPlaybackRate(0)
        m.lastRate = 0
    elseif anim then
        local rate = def.playbackrate or 1
        if m.lastRate ~= rate then
            mdl:SetPlaybackRate(rate)
            m.lastRate = rate
        end
        if def.frameadvance ~= false then mdl:FrameAdvance(dt) end
    end
end

local function UpdateLight(state, l, t, f, fps)
    local def = ResolveDef(l.def, l, t, f, fps)
    if not IsEffectActive(def, t, f) then return end

    local pos = ComputeTransform(state, def, l)
    if not pos then return end

    if def.blink and def.blink > 0 and (t / def.blink) % 1 >= (def.blinkduty or 0.5) then return end

    local dl = DynamicLight(l.dlid)
    if not dl then
        WarnOnce("dlight" .. l.dlid, "light", l.id, "- DynamicLight returned nil (light limit?)")
        return
    end
    local col = def.color or COLOR_LIGHT
    local list = def.colors
    if istable(list) and #list > 0 then
        local step = t / (def.colorinterval or 0.5)
        local i = math.floor(step) % #list
        local a, b = list[i + 1], list[(i + 1) % #list + 1]
        col = (def.colorfade and LerpValue(a, b, step % 1)) or a
    end
    dl.pos = pos
    dl.r, dl.g, dl.b = col.r or 255, col.g or 200, col.b or 100
    dl.brightness = def.brightness or 2
    dl.Size = def.distance or def.size or 200
    dl.Decay = def.decay or 1
    dl.noworld = def.noworld == true
    dl.DieTime = CurTime() + math.max(FrameTime() * 2, 0.03) -- short, so blinking cuts off cleanly
end

local function Roll(v, default)
    if v == nil then return default end
    if istable(v) then
        local a, b = v[1] or v.min, v[2] or v.max
        if a and b then return math.Rand(math.min(a, b), math.max(a, b)) end
        return a or b or default
    end
    return v
end

local function UpdateParticles(state, p, t, f, fps, dt)
    local fx = p.fx
    if not fx then return end

    local def = ResolveDef(p.def, p, t, f, fps)
    if not IsEffectActive(def, t, f) then
        fx.nextBurst, fx.acc = nil, 0
        return
    end

    local ent = GetEntityFor(state, def)
    if not IsValid(ent) then return end

    if def.target then
        local tm = state.models[def.target]
        if tm and IsValid(tm.ent) and not tm.visible then
            fx.nextBurst, fx.acc = nil, 0
            return
        end
    end

    local now = CurTime()
    local count = 0
    if istable(def.interval) or (def.interval or 0) > 0 then
        if not fx.nextBurst then fx.nextBurst = now + math.max(Roll(def.interval, 1), 0.02) end
        if now >= fx.nextBurst then
            fx.nextBurst = now + math.max(Roll(def.interval, 1), 0.02)
            count = math.floor(Roll(def.count, 10) + 0.5)
        end
    else
        fx.acc = fx.acc + dt * Roll(def.count, 20)
        count = math.floor(fx.acc)
        fx.acc = fx.acc - count
    end
    count = math.min(count, 300)

    fx.em:SetPos(ent:GetPos())
    if count <= 0 then return end
    if ent ~= state.ent then ent:SetupBones() end

    local bones
    if def.bones then
        local mdlName = ent:GetModel()
        if fx.bonesSrc ~= def.bones or fx.bonesEnt ~= ent or fx.bonesMdl ~= mdlName then
            fx.bones, fx.bonesSrc, fx.bonesEnt, fx.bonesMdl = ResolveParticleBones(ent, def.bones), def.bones, ent, mdlName
            fx.cursor = 1
        end
        bones = fx.bones
    end
    local nb = bones and #bones or 0

    local basePos
    if nb == 0 then
        basePos = ComputeTransform(state, def, p)
        if not basePos then return end
    end

    local matSrc = def.material or DEFAULT_MATERIAL
    if fx.matSrc ~= matSrc then
        fx.matSrc, fx.mat = matSrc, matSrc
        if not isstring(matSrc) or Material(matSrc):IsError() then
            Warn("particle", p.id, "- material not found:", tostring(matSrc), "(using fallback)")
            fx.mat = DEFAULT_MATERIAL
        end
    end

    local alpha, alphaend = def.alpha or 255, def.alphaend or 0
    local spread = math.Clamp(def.spread or 1, 0, 1)
    local off = def.pos

    -- bonepick: "cycle" (default), "random" (per particle), "burst" (one bone per burst)
    local pick = def.bonepick
    local burstBone = (nb > 0 and pick == "burst") and bones[math.random(nb)] or nil

    -- colorpick: "particle" (default), "burst" (one color per burst)
    local colorList = BuildActiveColors(def, p, t, f)
    local nc = colorList and #colorList or 0
    local burstColor = (def.colorpick == "burst" and nc > 0) and colorList[math.random(nc)] or nil

    for _ = 1, count do
        local pos = basePos
        if nb > 0 then
            local bone
            if pick == "burst" then
                bone = burstBone
            elseif pick == "random" then
                bone = bones[math.random(nb)]
            else
                bone = bones[fx.cursor]
                fx.cursor = fx.cursor % nb + 1
            end
            pos = BonePos(ent, bone, off)
        end

        local part = fx.em:Add(fx.mat, pos)
        if part then
            local c = (nc > 0 and (burstColor or colorList[math.random(nc)])) or def.color or COLOR_WHITE
            local v = Vector(0, 0, 1) * (1 - spread) + VectorRand():GetNormalized() * spread
            v:Normalize()

            part:SetVelocity(v * Roll(def.speed, 30))
            part:SetDieTime(Roll(def.life, 1))
            part:SetStartAlpha(alpha)
            part:SetEndAlpha(alphaend)
            part:SetStartSize(Roll(def.size, 3))
            part:SetEndSize(Roll(def.sizeend, 0))
            part:SetColor(c.r, c.g, c.b)
            part:SetRoll(Roll(def.roll, math.Rand(0, 360)))
            if def.rolldelta then part:SetRollDelta(Roll(def.rolldelta, 0)) end
            if def.airres then part:SetAirResistance(Roll(def.airres, 0)) end
            if def.collide then
                part:SetCollide(true)
                part:SetBounce(Roll(def.bounce, 0.3))
            end
            if def.lighting then part:SetLighting(true) end
            if def.startlength or def.endlength then
                part:SetStartLength(Roll(def.startlength, 0))
                part:SetEndLength(Roll(def.endlength, 0))
            end
            if def.velocityscale then part:SetVelocityScale(true) end
            part:SetGravity(Vector(0, 0, -Roll(def.gravity, 100)))
        else
            WarnOnce("padd" .. p.id, "particle", p.id, "- emitter:Add returned nil (invalid material or particle limit)")
        end
    end
end

-- PCF (engine) particle systems.
local PCF_ATTACH = {
    origin = PATTACH_ABSORIGIN,
    follow = PATTACH_ABSORIGIN_FOLLOW,
    point = PATTACH_POINT_FOLLOW,
    rootbone = PATTACH_ROOTBONE_FOLLOW,
}
local pcfAdded = {}

local function StopPCF(rec)
    if rec.fx and rec.fx:IsValid() then rec.fx:StopEmission(false, true) end
    rec.fx, rec.fxName, rec.fxEnt = nil, nil, nil
end

local function UpdatePCF(state, rec, t, f, fps)
    local def = ResolveDef(rec.def, rec, t, f, fps)
    local name = def.effect
    local ent = GetEntityFor(state, def)

    local active = isstring(name) and IsValid(ent) and IsEffectActive(def, t, f)
    if active and def.target then
        local tm = state.models[def.target]
        active = not (tm and IsValid(tm.ent) and not tm.visible)
    end

    if rec.fx and (not active or rec.fxName ~= name or rec.fxEnt ~= ent) then StopPCF(rec) end
    if not active then
        rec.failed = nil
        return
    end

    local mode = PCF_ATTACH[def.attach or "follow"]
    local origin, ang
    if not mode then origin, ang = ComputeTransform(state, def, rec) end

    if not rec.fx then
        if rec.failed == name then return end
        if isstring(def.pcf) and not pcfAdded[def.pcf] then
            pcfAdded[def.pcf] = true
            game.AddParticles(def.pcf)
        end
        PrecacheParticleSystem(name)

        local attId = 0
        if mode == PATTACH_POINT_FOLLOW then
            attId = isnumber(def.attachment) and def.attachment or ent:LookupAttachment(def.attachment or "")
            if attId <= 0 then
                Warn("pcf", rec.id, "- attachment not found:", tostring(def.attachment), "(using origin)")
                mode, attId = PATTACH_ABSORIGIN_FOLLOW, 0
            end
        end

        local fx = CreateParticleSystem(ent, name, mode or PATTACH_CUSTOMORIGIN, attId,
            mode and (def.pos or VEC_ZERO) or origin or ent:GetPos())
        if not fx or not fx:IsValid() then
            rec.failed = name
            Warn("pcf", rec.id, "- could not create", name, "(is the .pcf mounted / added?)")
            return
        end
        rec.fx, rec.fxName, rec.fxEnt = fx, name, ent

        for n, cp in pairs(Tbl(def.cps)) do
            if istable(cp) and cp.entity then fx:SetControlPointEntity(n, cp.entity == true and ent or cp.entity) end
        end
    end

    local fx = rec.fx
    if not fx:IsValid() then return end

    if origin then
        fx:SetControlPoint(0, origin)
        if ang then fx:SetControlPointOrientation(0, ang:Forward(), ang:Right(), ang:Up()) end
    end
    for n, cp in pairs(Tbl(def.cps)) do
        if istable(cp) and not cp.entity then
            rec.cpRecs = rec.cpRecs or {}
            rec.cpRecs[n] = rec.cpRecs[n] or {}
            local p = ComputeTransform(state, cp, rec.cpRecs[n])
            if p then fx:SetControlPoint(n, p) end
        end
    end
end

local function UpdateState(state, dt)
    local ok, t, f, fps = pcall(GetClock, state)
    if not ok then
        WarnOnce("clock", t)
        t = CurTime() - state.startTime
        fps = state.cfgFps or DEFAULT_FPS
        f = t * fps
    end
    state.t, state.f, state.fps = t, f, fps

    if IsValid(state.ent) then state.ent:SetupBones() end
    for _, m in ipairs(state.models) do
        local pass, err = pcall(UpdateModel, state, m, t, f, fps, dt)
        if not pass then WarnOnce("model" .. m.id, err) end
    end
    for _, l in ipairs(state.lights) do
        local pass, err = pcall(UpdateLight, state, l, t, f, fps)
        if not pass then WarnOnce("light" .. l.id, err) end
    end
    for _, p in ipairs(state.particles) do
        local pass, err = pcall(UpdateParticles, state, p, t, f, fps, dt)
        if not pass then WarnOnce("particle" .. p.id, err) end
    end
    for _, c in ipairs(state.pcfs) do
        local pass, err = pcall(UpdatePCF, state, c, t, f, fps)
        if not pass then WarnOnce("pcf" .. c.id, err) end
    end
end

-- start / stop
local function CleanupState(state)
    for _, m in ipairs(state.models) do
        if IsValid(m.ent) then m.ent:Remove() end
    end
    for _, p in ipairs(state.particles) do
        if p.fx then p.fx.em:Finish() end
    end
    for _, c in ipairs(state.pcfs) do StopPCF(c) end
    state.models, state.lights, state.particles, state.pcfs = {}, {}, {}, {}
end

local stopping = {}
local function StopEffects(ply, reason)
    if ply == nil or stopping[ply] then return end
    stopping[ply] = true -- co-op recursion guard (A -> B -> A)

    local state = ESPlus.Active[ply]
    if state then
        ESPlus.Active[ply] = nil
        Log("stop", ply, state.dance, reason)
        CleanupState(state)
    end

    if IsValid(ply) then
        local partner = ply.actmod_Coop_Tply
        if IsValid(partner) and partner ~= ply then StopEffects(partner, "co-op partner") end
    end
    stopping[ply] = nil
end

function ESPlus.StopAll()
    for ply, state in pairs(ESPlus.Active) do
        ESPlus.Active[ply] = nil
        CleanupState(state)
    end
end

local function StartEffects(ply, actName, force)
    if not IsValid(ply) or not isstring(actName) then return false end

    if not force then
        if not cvEnabled:GetBool() then return false end
        local cvSv = GetConVar("actmod_sv_enabled_addef")
        if cvSv and cvSv:GetInt() < 1 then return false end
        if isfunction(ply.A_ActModEffects) and not ply:A_ActModEffects() then return false end
    end

    local cfg, key = ResolveConfig(actName)
    if not cfg then
        Log("no config for", actName)
        return false
    end
    if cfg.enabled == false then return false end

    local cur = ESPlus.Active[ply]
    if cur then
        if cur.dance == actName then return true end
        StopEffects(ply, "new dance")
    end

    table.Empty(warned)
    local ok, state = pcall(CreateAll, ply, cfg, actName)
    if not ok then
        Warn("failed to create effects:", state)
        return false
    end
    state.test = force or nil
    ESPlus.Active[ply] = state
    Log("start", ply, actName, "-> config", key)
    return true
end

ESPlus.Start, ESPlus.Stop, ESPlus.Reload = StartEffects, StopEffects, LoadConfigs

-- hooks
local function FindArgs(...)
    local ply, name
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if not ply and isentity(v) and IsValid(v) then ply = v end
        if not name and isstring(v) then name = v end
    end
    return ply, name
end

hook.Add("ActMod_cl_StartAniAct_A", "amod_esplus_start", function(...)
    local ply, name = FindArgs(...)
    StartEffects(ply or LocalPlayer(), name)
end)

local function StopHook(...)
    local ply = FindArgs(...) or LocalPlayer()
    local st = ESPlus.Active[ply]
    -- actmod can fire a stop hook right after the start hook, ignore it
    if st and not st.test and CurTime() - st.startTime < STOP_GRACE then return end
    StopEffects(ply, "ActMod stop hook")
end

hook.Add("ActMod_RunStopAct", "amod_esplus_stop", StopHook)
hook.Add("ActMod_cl_RunaPlyEmot", "amod_esplus_stop", StopHook)

hook.Add("Think", "amod_esplus_think", function()
    local now = CurTime()
    for ent, state in pairs(ESPlus.Active) do
        local age = now - state.startTime
        local finished = not IsValid(ent)
            or (ent:IsPlayer() and not ent:Alive())
            or (not state.test and age > GRACE and ent:IsPlayer()
                and isfunction(ent.A_ActMod_IsActing) and not ent:A_ActMod_IsActing())

        if finished then
            ESPlus.Active[ent] = nil
            CleanupState(state)
        else
            local dt = math.Clamp(now - (state.lastThink or now), 0, 0.1)
            state.lastThink = now
            UpdateState(state, dt > 0 and dt or 0.016)
        end
    end

    -- co-op, the partner may take a moment to be assigned, so retry for a few seconds...
    local lp = LocalPlayer()
    local state = IsValid(lp) and ESPlus.Active[lp]
    if state and not state.partnerDone and now - state.startTime < 3 then
        local partner = lp.actmod_Coop_Tply
        if IsValid(partner) and partner ~= lp then
            state.partnerDone = true
            if not ESPlus.Active[partner] then StartEffects(partner, state.dance) end
        end
    end
end)

hook.Add("EntityRemoved", "amod_esplus_removed", function(ent)
    if ESPlus.Active[ent] then StopEffects(ent, "entity removed") end
end)

hook.Add("PostCleanupMap", "amod_esplus_cleanup", ESPlus.StopAll)

hook.Add("HUDPaint", "amod_esplus_hud", function()
    if not cvHud:GetBool() then return end
    local st = ESPlus.Active[LocalPlayer()]
    if not st then return end
    draw.SimpleTextOutlined(
        string.format("ES+  t = %.2fs   frame = %d   (fps %.0f, %s)", st.t, math.floor(st.f), st.fps, st.framesource),
        "DermaLarge", ScrW() / 2, ScrH() * 0.86, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(0, 0, 0, 220))
end)

-- commands
local TYPE_MAP = { model = "models", light = "lights", particle = "particles", pcf = "pcfs" }

local function LocalState()
    local lp = LocalPlayer()
    return IsValid(lp) and ESPlus.Active[lp] or nil
end

local function CmdDef(kind, n)
    local state = LocalState()
    local list = state and TYPE_MAP[kind] and state[TYPE_MAP[kind]]
    local rec = list and list[tonumber(n)]
    if not rec then
        print("[ES+] Effect not found.")
        return
    end
    return rec.def
end

local function VecArg(args, i)
    return Vector(tonumber(args[i]) or 0, tonumber(args[i + 1]) or 0, tonumber(args[i + 2]) or 0)
end

concommand.Add("esplus_reload", LoadConfigs)

concommand.Add("esplus_list", function()
    local state = LocalState()
    if not state then print("[ES+] No active dance.") return end
    print(string.format("[ES+] %s (t=%.2fs frame=%.0f)", state.dance, state.t, state.f))
    for kind, listKey in pairs(TYPE_MAP) do
        for i, rec in ipairs(state[listKey]) do
            print(string.format("  [%s %d] %s", kind, i, tostring(rec.def.model or rec.def.material or rec.def.effect or "")))
        end
    end
end)

concommand.Add("esplus_time", function()
    local st = LocalState()
    if not st then print("[ES+] No active dance.") return end
    print(string.format("[ES+] t = %.2fs | frame = %.1f | fps = %.1f | source = %s | dance = %s",
        st.t, st.f, st.fps, st.framesource, st.dance))
end)

concommand.Add("esplus_stop", function()
    StopEffects(LocalPlayer(), "esplus_stop")
end)

concommand.Add("esplus_test", function(_, _, args)
    if not args[1] then
        print("[ES+] Usage: esplus_test <dance>  (esplus_stop to end)")
        return
    end
    StartEffects(LocalPlayer(), table.concat(args, " "), true)
end)

concommand.Add("esplus_toggle", function(_, _, args)
    local def = CmdDef(args[1], args[2])
    if not def then return end
    def.enabled = (def.enabled == false)
    print("[ES+] enabled =", def.enabled)
end)

concommand.Add("esplus_move", function(_, _, args)
    local def = CmdDef(args[1], args[2])
    if not def then return end
    def.pos = (def.pos or VEC_ZERO) + VecArg(args, 3)
    print("[ES+] pos =", def.pos)
end)

concommand.Add("esplus_setpos", function(_, _, args)
    local def = CmdDef(args[1], args[2])
    if not def then return end
    def.pos = VecArg(args, 3)
    print("[ES+] pos =", def.pos)
end)

concommand.Add("esplus_scale", function(_, _, args)
    local def = CmdDef("model", args[1])
    if not def then return end
    def.scale = tonumber(args[2]) or 1
    print("[ES+] scale =", def.scale)
end)

concommand.Add("esplus_alpha", function(_, _, args)
    local def = CmdDef("model", args[1])
    if not def then return end
    def.alpha = math.Clamp(tonumber(args[2]) or 255, 0, 255)
    print("[ES+] alpha =", def.alpha)
end)

concommand.Add("esplus_color", function(_, _, args)
    local def = CmdDef("model", args[1])
    if not def then return end
    def.color = Color(tonumber(args[2]) or 255, tonumber(args[3]) or 255, tonumber(args[4]) or 255)
    print("[ES+] color =", def.color)
end)

LoadConfigs()
Log("ES+ " .. ESPlus.Version .. " ready")
