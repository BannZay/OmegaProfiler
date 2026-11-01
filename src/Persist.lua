-- Compact save/restore of a Series store for SavedVariables. Pure Lua (no WoW API).
-- Each tier is stored as strings: values are quantised to 0.01 units/s, written as 5-bit varints in a
-- printable base-64 alphabet, with runs of zeros collapsed. The newest buckets are kept first, and the
-- amount is trimmed until the encoded size fits the caller's byte budget.
-- Series keys are saved as ids into a shared string pool (OMP.Pack) when one is given.
local ADDON, OMP = ...
local Persist = {}
OMP.Persist = Persist

local floor, max, min = math.floor, math.max, math.min
local sub, byte = string.sub, string.byte

local VERSION = 1
local RATE_Q = 100   -- rate resolution: 1/100 unit per second
local DUR_Q = 10     -- bucket duration resolution: 0.1 s
local AGE_Q = 10     -- ages are stored as integer tenths of a second

-- newest buckets saved per tier before the size budget is applied
Persist.MAX_BUCKETS = { 1800, 2160, 1440 }

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local CHARS, VALUE = {}, {}
for i = 1, 64 do
	local c = sub(ALPHA, i, i)
	CHARS[i - 1] = c
	VALUE[byte(c)] = i - 1
end

local function putVarint(out, v)
	while v >= 32 do
		out[#out + 1] = CHARS[v % 32 + 32]
		v = floor(v / 32)
	end
	out[#out + 1] = CHARS[v]
end

-- ints: array of non-negative integers -> string (a 0 is followed by the length of its run)
local function encode(ints, n)
	local out, i = {}, 1
	while i <= n do
		local v = ints[i]
		if v == 0 then
			local j = i
			while j < n and ints[j + 1] == 0 do j = j + 1 end
			putVarint(out, 0)
			putVarint(out, j - i + 1)
			i = j + 1
		else
			putVarint(out, v)
			i = i + 1
		end
	end
	return table.concat(out)
end

-- Returns an array of exactly n integers, or nil when the string is malformed.
local function decode(str, n)
	local res, count, pos, len = {}, 0, 1, #str
	local function varint()
		local v, mul = 0, 1
		while pos <= len do
			local d = VALUE[byte(str, pos)]
			pos = pos + 1
			if not d then return nil end
			v = v + (d % 32) * mul
			if d < 32 then return v end
			mul = mul * 32
		end
	end
	while count < n do
		local v = varint()
		if not v then return nil end
		if v == 0 then
			local run = varint()
			if not run or run < 1 or count + run > n then return nil end
			for _ = 1, run do count = count + 1; res[count] = 0 end
		else
			count = count + 1
			res[count] = v
		end
	end
	return res
end

local function exportTier(tier, n, pool)
	if not tier.cur then return nil end
	local from = max(tier.first, tier.cur - n + 1, tier.cur - tier.cap + 1)
	local cnt = tier.cur - from + 1
	if cnt < 1 then return nil end
	local durs, durQ = {}, {}
	for k = 1, cnt do
		local d = tier.dur[(from + k - 1) % tier.cap]
		durs[k] = d
		durQ[k] = floor(d * DUR_Q + 0.5)
	end
	local t = { w = tier.w, n = cnt, age = tier.cur * tier.w, dur = encode(durQ, cnt), keys = {} }
	for key, arr in pairs(tier.vals) do
		local q, any = {}, false
		for k = 1, cnt do
			local d = durs[k]
			local v = d > 0 and floor(arr[(from + k - 1) % tier.cap] / d * RATE_Q + 0.5) or 0
			if v < 0 then v = 0 end
			q[k] = v
			if v > 0 then any = true end
		end
		if any then t.keys[pool and OMP.Pack.Id(pool, key) or key] = encode(q, cnt) end
	end
	return t
end

local function sizeOf(t)
	local s = #t.dur + 40
	for key, str in pairs(t.keys) do s = s + #tostring(key) + #str + 12 end
	return s
end

-- Returns a table for SavedVariables whose encoded size is about <= budget bytes.
-- now: current GetTime(); wall: current time(); pool: optional OMP.Pack string pool for the key names.
function Persist.Export(store, now, wall, budget, pool)
	local n = {}
	for i, m in ipairs(Persist.MAX_BUCKETS) do n[i] = m end
	local data
	for _ = 1, 8 do
		data = { v = VERSION, wall = wall, start = floor((now - store.startTime) * AGE_Q + 0.5), tiers = {} }
		local total = 60
		for i, tier in ipairs(store.tiers) do
			local t = exportTier(tier, n[i] or tier.cap, pool)
			if t then
				t.age = floor((now - t.age) * AGE_Q + 0.5)
				data.tiers[i] = t
				total = total + sizeOf(t)
			end
		end
		if total <= budget then break end
		local f = max(0.05, budget / total * 0.95)
		for i = 1, #n do n[i] = max(1, floor(n[i] * f)) end
	end
	return data
end

-- Rebuilds a store from saved data; the time the data was saved maps to (now - gap).
-- Returns nil when the data is unusable or older than maxGap seconds.
-- names: the string pool list that numeric keys refer to.
function Persist.Import(data, now, wall, maxGap, names)
	if type(data) ~= "table" or data.v ~= VERSION or type(data.tiers) ~= "table" then return nil end
	local gap = wall - (data.wall or 0)
	if gap < 0 or gap > maxGap then return nil end
	local base = now - gap
	local store = OMP.Series.New(base - (data.start or 0) / AGE_Q)
	local keySet = {}
	for i, tier in ipairs(store.tiers) do
		local t = data.tiers[i]
		if t and t.w == tier.w and type(t.n) == "number" and type(t.keys) == "table" then
			local durQ = decode(t.dur, t.n)
			if not durQ then return nil end
			local newCur = floor((base - t.age / AGE_Q) / tier.w + 0.5)
			local skip = max(0, t.n - tier.cap)   -- oldest buckets that no longer fit
			local cnt = t.n - skip
			local from = newCur - cnt + 1
			for k = 1, cnt do
				tier.dur[(from + k - 1) % tier.cap] = durQ[skip + k] / DUR_Q
			end
			for id, str in pairs(t.keys) do
				local key = id
				if type(id) == "number" then key = names and names[id] end
				if not key then return nil end
				local q = decode(str, t.n)
				if not q then return nil end
				local arr = {}
				for s = 0, tier.cap - 1 do arr[s] = 0 end
				for k = 1, cnt do
					local slot = (from + k - 1) % tier.cap
					arr[slot] = q[skip + k] / RATE_Q * tier.dur[slot]
				end
				tier.vals[key] = arr
				keySet[key] = true
			end
			tier.cur, tier.first = newCur, from
		end
	end
	local list = {}
	for key in pairs(keySet) do list[#list + 1] = key end
	table.sort(list)
	for _, key in ipairs(list) do
		store.keySet[key] = true
		store.keyList[#store.keyList + 1] = key
	end
	return store
end
