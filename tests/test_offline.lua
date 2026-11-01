-- Offline tests (no WoW): lua tests/test_offline.lua  (run from the addon folder)
local OMP = {}
for _, f in ipairs({ "Series.lua", "Persist.lua", "Classify.lua", "Pack.lua" }) do
	assert(loadfile("src/" .. f))("OmegaProfiler", OMP)
end
local Series, Classify = OMP.Series, OMP.Classify

local fails, count = 0, 0
local function check(cond, msg)
	count = count + 1
	if not cond then fails = fails + 1; print("FAIL: " .. msg) end
end
local function near(a, b, eps) return a and math.abs(a - b) <= (eps or 1e-6) end

-- Series: constant rate recorded for 10 minutes at 0.5s samples
local s = Series.New(0)
for i = 1, 1200 do s:Add(i * 0.5, 0.5, { A = 10, B = (i > 600) and 20 or 0 }) end
local now = 600
local v = s:Query("A", now - 300, now, 150)
check(#v == 150, "query returns n columns")
check(near(v[1], 10, 1e-6) and near(v[150], 10, 1e-6), "constant rate preserved")
local b = s:Query("B", 0, 600, 60)
check(near(b[1], 0, 1e-6), "B zero in first half (got " .. tostring(b[1]) .. ")")
check(near(b[60], 20, 1e-6), "B 20 in last column")
check(near(s:Average("A", 0, 600), 10, 1e-6), "average over all")
check(near(s:Average("B", 0, 600), 10, 0.5), "average of half-active series ~10 (got " .. s:Average("B", 0, 600) .. ")")
check(s:Query("A", -400, -100, 10)[1] == false, "no data before start -> false")

-- complete: the newest bucket is still filling, so a live graph leaves its column out
do
	local f = Series.New(0)
	f:Add(1.5, 0.5, { A = 4 }); f:Add(2.0, 0.5, { A = 4 }); f:Add(2.5, 0.5, { A = 9 })
	local all, done = f:Query("A", 0, 3, 3), f:Query("A", 0, 3, 3, true)
	check(all[3] == 6.5 and done[3] == false, "filling bucket hidden (got " .. tostring(done[3]) .. ")")
	check(done[2] == 4 and all[2] == 4, "finished buckets kept")
	f:Add(3.0, 0.5, { A = 1 })
	check(f:Query("A", 0, 3, 3, true)[3] == 6.5, "bucket shows once the next one starts")
end

-- tier selection: wide window uses coarser tier and still returns right values
local wide = s:Query("A", 0, 600, 60)
check(near(wide[30], 10, 1e-6), "wide window value")

-- ring wrap: 2 hours of data, raw tier (30m) must still answer for the last 5 min
local long = Series.New(0)
for i = 1, 7200 do long:Add(i, 1, { A = 5 }) end
check(near(long:Query("A", 7200 - 300, 7200, 100)[100], 5, 1e-6), "recent after wrap")
check(near(long:Query("A", 0, 7200, 100)[50], 5, 1e-6), "all-time after wrap (coarse tier)")
check(long:Query("A", 0, 600, 10)[1] ~= nil, "old window returns something")

-- drawing grid: a window sliding by fractions of a column must not change the values of the columns it keeps
do
	local g = Series.New(0)
	for i = 1, 900 do g:Add(i, 1, { A = (i * 7919) % 13 }) end -- spiky data, one sample per 1 s slot
	local function draw(tEnd)
		local t0, t1, n = g:Grid(tEnd - 300, tEnd, 200) -- 1.5 s per column requested
		local byTime = {}
		local vals = g:Query("A", t0, t1, n)
		for c = 1, n do byTime[t0 + (c - 1) * (t1 - t0) / n] = vals[c] end
		return byTime, t0, t1, n
	end
	local ref, t0, t1, n = draw(800)
	check((t1 - t0) / n == 1 and t1 >= 800 and t0 <= 500, "grid: whole slots per column, covers the window")
	local same = true
	for k = 1, 9 do
		local cur = draw(800 + k * 0.37)
		for t, val in pairs(cur) do
			if ref[t] ~= nil and t < 800 and val ~= ref[t] then same = false end
		end
	end
	check(same, "grid: sliding window keeps column values stable")
end

-- keys listing
local keys = s:Keys()
check(#keys == 2, "two keys tracked")

-- Window / Pan
local t0, t1, span, off = Series.Window(1000, 0, 5, 0)
check(t0 == 700 and t1 == 1000 and span == 300 and off == 0, "5m live window")
t0, t1 = Series.Window(1000, 0, 0, 50)
check(t0 == 0 and t1 == 1000, "all time ignores offset")
local o = Series.Pan(1000, 0, 5, 0, "back")
check(o == 75, "pan back = quarter window (got " .. o .. ")")
o = Series.Pan(1000, 0, 5, o, "back1")
check(o == 375, "pan back a full window")
o = Series.Pan(1000, 0, 5, 700, "back1")
check(o == 700, "pan clamped to history (1000-300 = 700)")
o = Series.Pan(1000, 0, 5, 100, "fwd1")
check(o == 0, "pan forward clamped to live")
check(Series.Pan(1000, 0, 5, 400, "live") == 0, "live resets offset")
check(Series.Pan(100, 0, 30, 0, "back") == 0, "no panning when history shorter than span")

-- Persist: round trip, gap shift, size cap
local P = OMP.Persist
local ps = Series.New(0)
for i = 1, 14400 do ps:Add(i * 0.5, 0.5, { A = 10.25, B = (i % 200 < 100) and 3 or 0, __fps = 60 }) end
local data = P.Export(ps, 7200, 5000, 10 * 1024 * 1024)
local back = P.Import(data, 100, 5030, 86400) -- saved 30s ago; "now" is GetTime 100
check(back ~= nil, "import ok")
check(near(back:Average("A", 100 - 30 - 300, 100 - 30), 10.25, 0.01), "restored rate before gap")
check(back:Average("A", 100 - 20, 100 - 5) == 0, "gap is empty")
check(near(back:Average("__fps", 100 - 30 - 600, 100 - 30), 60, 0.01), "fps restored")
check(#back:Keys() == 3, "keys restored")
check(P.Import(data, 100, 5000 + 90000, 86400) == nil, "too old -> discarded")
check(P.Import({ v = 99 }, 0, 0, 1) == nil, "bad version rejected")
local small = P.Export(ps, 7200, 5000, 4 * 1024)
local function bytes(d) local n = 0 for _, t in pairs(d.tiers) do n = n + #t.dur for k, v in pairs(t.keys) do n = n + #k + #v end end return n end
check(bytes(small) <= 4 * 1024, "budget respected (got " .. bytes(small) .. ")")
check(bytes(data) < 30000, "full export is compact (got " .. bytes(data) .. " bytes)")
check(P.Import(small, 100, 5030, 86400) ~= nil, "trimmed data still imports")

-- Wheel steps
check(Series.StepMinutes(5, 1, 0) == 3.7 and Series.StepMinutes(5, -1, 0) == 6.3, "step by a quarter")
check(Series.StepMinutes(1, 1, 0) == 0.7, "sub-minute steps")
check(Series.StepMinutes(0.1, 1, 0) == 0.1 and Series.StepMinutes(0.1, -1, 0) == 0.2, "floor at 0.1 minute")
check(Series.StepMinutes(0, 1, 1200) == 15, "from all time zoom in below history")
check(Series.StepMinutes(0, -1, 1200) == 0, "all time stays all time")
check(Series.StepMinutes(1440, -1, 0) == 1440, "capped at max")

-- Zooming in on data the fine tier has already overwritten falls back to a coarser tier
do
	local st = Series.New(0)
	for t = 0.5, 3600, 0.5 do st:Add(t, 0.5, { a = 1 }) end   -- 1 h: the 1 s tier keeps only the last 30 min
	local function filled(t0, t1)
		local a, b, n = st:Grid(t0, t1, 160)
		local v, w = st:Query("a", a, b, n)
		local c = 0
		for i = 1, n do if v[i] then c = c + 1 end end
		return c, n, w
	end
	local c, n, w = filled(3594, 3600)
	check(c == n and w == 1, "live close zoom uses 1 s buckets")
	c, n, w = filled(1200, 1206)
	check(c == n and w == 10, "40 min ago, 6 s window falls back to 10 s buckets (" .. c .. "/" .. n .. ")")
	check(n >= 150, "a window inside one coarse bucket still gets about n columns (" .. n .. ")")
	local a, b = st:Grid(1200, 1206, 160)
	check(a <= 1200 and b >= 1206 and b - a <= 7, "sub-slot grid stays close to the window (" .. a .. ".." .. b .. ")")
	c, n = filled(1200, 2400)
	check(c == n, "window crossing the 1 s tier's start is fully drawn (" .. c .. "/" .. n .. ")")
	local young = Series.New(100)
	for t = 200.5, 300, 0.5 do young:Add(t, 0.5, { a = 1 }) end
	check(young:PickTier(60, 160, 100).w == 1, "session start before first sample keeps the fine tier")
end

-- Zoom at cursor: the time under the cursor keeps its place in the window
do
	local now, start = 10000, 0
	local o = Series.ZoomAt(now, start, 2, 9000, 0.5)          -- 2 min window centred on t = 9000
	local t0, t1 = Series.Window(now, start, 2, o)
	check(t0 == 8940 and t1 == 9060, "centred on cursor time")
	check(Series.ZoomAt(now, start, 2, now, 1) == 0, "cursor at live edge stays live")
	check(Series.ZoomAt(now, start, 2, 9990, 0.1) == 0, "clamped to live")
	o = Series.ZoomAt(now, start, 2, 30, 0.5)
	check(o == now - 120, "clamped to history start")
	check(Series.ZoomAt(now, start, 0, 5000, 0.5) == 0, "all time has no offset")
end

-- Right-drag panning
do
	local now, start = 10000, 0
	check(Series.DragOffset(now, start, 2, now, 0.5) == 60, "drag right goes back in time")
	check(Series.DragOffset(now, start, 2, 9000, -0.5) == 940, "drag left comes closer to now")
	check(Series.DragOffset(now, start, 2, now, -1) == 0, "cannot drag past live")
	check(Series.DragOffset(now, start, 2, 200, 5) == now - 120, "cannot drag before history start")
	check(Series.DragOffset(now, start, 0, now, 0.5) == 0, "all time does not pan")
end

-- Polyline simplification
do
	local xs, ys = {}, {}
	for k = 1, 200 do xs[k], ys[k] = k * 3, 1 end
	local idx = Series.Simplify(xs, ys, 1, 200, 0.5)
	check(#idx == 2 and idx[1] == 1 and idx[2] == 200, "flat line -> one segment")
	for k = 1, 200 do ys[k] = k * 0.7 + ((k % 2 == 0) and 0.3 or 0) end
	check(#Series.Simplify(xs, ys, 1, 200, 0.5) == 2, "sub-tolerance jitter on a slope -> one segment")
	for k = 1, 200 do ys[k] = 1 end
	ys[100] = 50
	idx = Series.Simplify(xs, ys, 1, 200, 0.5)
	local has = {}
	for _, k in ipairs(idx) do has[k] = true end
	check(has[99] and has[100] and has[101] and #idx == 5, "spike kept with its neighbours (got " .. #idx .. ")")
	for k = 2, #idx do check(idx[k] > idx[k - 1], "indices increasing") end
	local noisy = {}
	for k = 1, 200 do noisy[k] = (k * 7919) % 13 end
	idx = Series.Simplify(xs, noisy, 1, 200, 0.5)
	local maxErr = 0
	for s = 2, #idx do
		local a, b = idx[s - 1], idx[s]
		for k = a, b do
			local y = noisy[a] + (noisy[b] - noisy[a]) * (k - a) / (b - a)
			maxErr = math.max(maxErr, math.abs(noisy[k] - y))
		end
	end
	check(maxErr <= 0.5, "every dropped point within tolerance (err " .. maxErr .. ")")
	check(#Series.Simplify(xs, ys, 7, 7, 0.5) == 1, "single point run")
end

-- Classify
local r = Classify.Spike({ dur = 300, deltas = { Bad = 250, Ok = 5, Meh = 30 } })
check(r.kind == "addon" and r.culprits[1].name == "Bad", "addon culprit detected")
r = Classify.Spike({ dur = 300, deltas = { Bad = 10 }, memDropKB = 4096 })
check(r.kind == "engine" and r.hint:find("garbage"), "gc hint on engine spike")
r = Classify.Spike({ dur = 400, deltas = { A = 100 }, latency = 500, prevLatency = 50 })
check(r.kind == "mixed" and r.hint:find("latency"), "mixed with latency hint")
r = Classify.Spike({ dur = 400, deltas = {}, loading = true })
check(r.kind == "engine" and r.hint:find("loading"), "loading hint")
r = Classify.Spike({ dur = 200 })
check(r.kind == "unknown", "no profiling -> unknown")
check(Classify.Describe(Classify.Spike({ dur = 300, deltas = { Bad = 250 } })):find("Bad 250ms"), "describe text")

-- spike = over the threshold and clearly longer than recent frames; a steady low frame rate is not a spike
check(Classify.IsSpike(300, 16, 100), "spike at a normal frame rate")
check(not Classify.IsSpike(80, 16, 100), "under the threshold")
check(not Classify.IsSpike(130, 125, 100), "steady 8 FPS is not a spike")
check(Classify.IsSpike(400, 125, 100), "spike on top of a low frame rate")
do -- 10 s at a steady 8 FPS (EMA as in Sampler.lua): only the first frames may count
	local avg, n = 16, 0
	for _ = 1, 80 do
		if Classify.IsSpike(125, avg, 100) then n = n + 1 end
		avg = avg * 0.9 + 125 * 0.1
	end
	check(n <= 8, "steady low FPS does not flood the log (got " .. n .. ")")
end

-- Pack: lag log, load history and live data share one string pool
do
	local Pack = OMP.Pack
	local pool = Pack.NewPool()
	local res = Classify.Spike({ dur = 412.37, deltas = { WeakAuras = 300.123, MoveAnything = 80 }, combat = true, memDropKB = 2048 })
	local lag = { t = 5, session = 1, stamp = "18:44:34", dur = 412.37, kind = res.kind, culprits = res.culprits,
		luaMs = res.luaMs, hint = res.hint, fps = 115.3846, latency = 30, combat = true, zone = "The Ruby Sanctum",
		memDropKB = 0 }
	lag.text = Classify.Describe(res, lag.dur)
	local plain = { stamp = "18:45:00", dur = 174, kind = "unknown", culprits = {}, luaMs = 0, hint = "",
		fps = 1000, latency = 0, combat = false, zone = "The Ruby Sanctum", memDropKB = 0 }
	local rows = Pack.Lags({ lag, plain }, pool)
	local zoneRow = Pack.Loads({ { kind = "zone", stamp = "2026-10-30 00:04:15", wall = 1234.5678, luaMs = 50,
		profiled = true, zone = "The Ruby Sanctum", addons = { WeakAuras = { cpu = 40.25, wall = 0 } } } }, pool)
	local loginRow = Pack.Loads({ { kind = "login", stamp = "x", wall = 9, luaMs = 0, profiled = false, partial = true,
		coveredAddons = "from X onward", addons = {} } }, pool)
	check(#pool.list == 5 and res.kind == "addon", "each string pooled once (got " .. #pool.list .. ")")
	check(#rows[1] < 80, "lag row is short (" .. rows[1] .. ")")

	local back = Pack.UnpackLags(rows, pool.list)
	local b = back[1]
	check(b.stamp == "18:44:34" and b.dur == 412.37 and b.kind == "addon" and b.combat == true, "lag fields")
	check(b.zone == "The Ruby Sanctum" and b.hint == res.hint and near(b.fps, 115.38, 1e-9), "lag strings")
	check(b.culprits[1].name == "WeakAuras" and b.culprits[1].ms == 300.12 and b.culprits[2].name == "MoveAnything",
		"culprits in order")
	check(b.text == lag.text, "text rebuilt (" .. b.text .. ")")
	check(b.session == nil and back[2].hint == "" and #back[2].culprits == 0 and back[2].combat == false, "plain lag")

	local z = Pack.UnpackLoads(zoneRow, pool.list)[1]
	check(z.kind == "zone" and z.wall == 1234.57 and z.profiled and not z.partial and z.zone == "The Ruby Sanctum",
		"zone load fields")
	check(z.addons.WeakAuras.cpu == 40.25 and z.addons.WeakAuras.wall == 0, "zone load addons")
	local l = Pack.UnpackLoads(loginRow, pool.list)[1]
	check(l.kind == "login" and l.partial and not l.profiled and l.coveredAddons == "from X onward"
		and next(l.addons) == nil, "login load fields")

	local before = #pool.list
	local live = P.Export(ps, 7200, 5000, 10 * 1024 * 1024, pool)
	check(#pool.list == before + 3, "live keys pooled")
	for _, t in pairs(live.tiers) do for k in pairs(t.keys) do check(type(k) == "number", "live key is an id") break end end
	local lb = P.Import(live, 100, 5030, 86400, pool.list)
	check(lb and #lb:Keys() == 3 and near(lb:Average("A", 100 - 30 - 300, 100 - 30), 10.25, 0.01), "pooled live import")
	check(P.Import(live, 100, 5030, 86400) == nil, "pooled live data without names rejected")
end

-- DataEdge / JumpOffset: data 0..100 s, a gap, then 500..600 s
do
	local g = Series.New(0)
	for t = 0.5, 99.5, 0.5 do g:Add(t, 0.5, { A = 1 }) end
	for t = 500.5, 599.5, 0.5 do g:Add(t, 0.5, { A = 1 }) end
	check(g:DataEdge(300, -1) == 100, "edge of older data (got " .. tostring(g:DataEdge(300, -1)) .. ")")
	check(g:DataEdge(300, 1) == 500, "edge of newer data (got " .. tostring(g:DataEdge(300, 1)) .. ")")
	check(g:DataEdge(0, -1) == nil and g:DataEdge(700, 1) == nil, "no data beyond the ends")
	local o = Series.JumpOffset(600, 0, 1, 100, -1)
	local t0, t1 = Series.Window(600, 0, 1, o)
	check(near(t1, 106) and near(t0, 46), "jump back leaves 10% empty on the right")
	o = Series.JumpOffset(600, 0, 1, 500, 1)
	t0, t1 = Series.Window(600, 0, 1, o)
	check(near(t0, 494) and near(t1, 554), "jump forward leaves 10% empty on the left")
	check(Series.JumpOffset(600, 0, 1, 590, 1) == 0, "jump clamped to live")
	-- old data that only the 60 s tier still holds
	local w = Series.New(0)
	for t = 0.5, 99.5, 0.5 do w:Add(t, 0.5, { A = 1 }) end
	w:Add(30000, 0.5, { A = 1 })
	check(w:DataEdge(20000, -1) == 120, "older data found in the coarse tier")
	check(w:DataEdge(10, 1) == 60, "newer data found in the coarse tier")
end

print(string.format("%d checks, %d failed", count, fails))
os.exit(fails == 0 and 0 or 1)
