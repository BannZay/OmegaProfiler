-- Compact SavedVariables form of the lag log and load history. Pure Lua (no WoW API).
-- Each entry becomes one comma-separated string. Repeated strings (addon names, zones, hints) are stored
-- once in a shared string list and referenced by their index there (0 = none).
-- Lag entries drop t/session (only meaningful in the session that recorded them) and text (rebuilt by
-- Classify.Describe).
local ADDON, OMP = ...
local Pack = {}
OMP.Pack = Pack

local format, find, sub, gsub = string.format, string.find, string.sub, string.gsub
local concat = table.concat

function Pack.NewPool()
	return { list = {}, ids = {} }
end

function Pack.Id(pool, s)
	if s == nil or s == "" then return 0 end
	local id = pool.ids[s]
	if not id then
		id = #pool.list + 1
		pool.list[id] = s
		pool.ids[s] = id
	end
	return id
end

local function str(list, id)
	id = tonumber(id)
	return id and id > 0 and list[id] or nil
end

-- Number with at most 2 decimals and no trailing zeros.
local function num(x)
	local s = gsub(format("%.2f", x or 0), "%.?0+$", "")
	return s == "" and "0" or s
end

local function split(s, sep)
	local out, pos = {}, 1
	while true do
		local i = find(s, sep, pos, true)
		if not i then out[#out + 1] = sub(s, pos); return out end
		out[#out + 1] = sub(s, pos, i - 1)
		pos = i + 1
	end
end

local KIND = { addon = "a", mixed = "m", engine = "e", unknown = "u" }
local KIND_NAME = { a = "addon", m = "mixed", e = "engine", u = "unknown" }

-- row: stamp,dur,kind,luaMs,hint,fps,latency,combat,zone,memDropKB,name:ms;name:ms
function Pack.Lags(log, pool)
	local rows = {}
	for i, e in ipairs(log) do
		local cs = {}
		for k, c in ipairs(e.culprits or {}) do cs[k] = Pack.Id(pool, c.name) .. ":" .. num(c.ms) end
		rows[i] = concat({
			e.stamp or "", num(e.dur), KIND[e.kind] or "u", num(e.luaMs), Pack.Id(pool, e.hint),
			num(e.fps), num(e.latency), e.combat and 1 or 0, Pack.Id(pool, e.zone), num(e.memDropKB),
			concat(cs, ";"),
		}, ",")
	end
	return rows
end

function Pack.UnpackLags(rows, list)
	local log = {}
	for _, row in ipairs(rows) do
		local f = split(row, ",")
		local culprits = {}
		if f[11] and f[11] ~= "" then
			for _, c in ipairs(split(f[11], ";")) do
				local id, ms = c:match("^(%d+):(.+)$")
				local name = str(list, id)
				if name then culprits[#culprits + 1] = { name = name, ms = tonumber(ms) or 0 } end
			end
		end
		local e = {
			stamp = f[1], dur = tonumber(f[2]) or 0, kind = KIND_NAME[f[3]] or "unknown",
			luaMs = tonumber(f[4]) or 0, hint = str(list, f[5]) or "", fps = tonumber(f[6]),
			latency = tonumber(f[7]), combat = f[8] == "1", zone = str(list, f[9]),
			memDropKB = tonumber(f[10]) or 0, culprits = culprits,
		}
		e.text = OMP.Classify.Describe(e, e.dur)
		log[#log + 1] = e
	end
	return log
end

-- row: kind,stamp,wall,luaMs,flags,zone,coveredAddons,name:cpu:wall;name:cpu:wall
-- flags: p = profiled, x = partial
function Pack.Loads(loads, pool)
	local rows = {}
	for i, e in ipairs(loads) do
		local as = {}
		for name, a in pairs(e.addons or {}) do
			as[#as + 1] = Pack.Id(pool, name) .. ":" .. num(a.cpu) .. ":" .. num(a.wall)
		end
		rows[i] = concat({
			e.kind == "login" and "l" or "z", e.stamp or "", num(e.wall), num(e.luaMs),
			(e.profiled and "p" or "") .. (e.partial and "x" or ""),
			Pack.Id(pool, e.zone), Pack.Id(pool, e.coveredAddons), concat(as, ";"),
		}, ",")
	end
	return rows
end

function Pack.UnpackLoads(rows, list)
	local loads = {}
	for _, row in ipairs(rows) do
		local f = split(row, ",")
		local flags = f[5] or ""
		local e = {
			kind = f[1] == "l" and "login" or "zone", stamp = f[2], wall = tonumber(f[3]) or 0,
			luaMs = tonumber(f[4]) or 0, profiled = find(flags, "p", 1, true) ~= nil,
			partial = find(flags, "x", 1, true) ~= nil or nil,
			zone = str(list, f[6]), coveredAddons = str(list, f[7]), addons = {},
		}
		if f[8] and f[8] ~= "" then
			for _, a in ipairs(split(f[8], ";")) do
				local id, cpu, wall = a:match("^(%d+):([^:]*):([^:]*)$")
				local name = str(list, id)
				if name then e.addons[name] = { cpu = tonumber(cpu) or 0, wall = tonumber(wall) or 0 } end
			end
		end
		loads[#loads + 1] = e
	end
	return loads
end
