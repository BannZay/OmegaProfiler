-- Time-series storage with three resolutions, plus zoom/pan window maths.
-- Pure Lua (no WoW API) so it can be tested offline.
local ADDON, OMP = ...
local Series = {}
OMP.Series = Series

local floor, max, min = math.floor, math.max, math.min

-- bucket width (s) and bucket count per resolution
Series.TIERS = {
	{ w = 1,  cap = 1800 },  -- 30 min
	{ w = 10, cap = 2160 },  -- 6 h
	{ w = 60, cap = 1440 },  -- 24 h ("All time" = this session, up to 24 h)
}

-- Window length is given in minutes; 0 (or less) means "all time". Longest history kept is the last tier.
Series.MAX_MINUTES = 1440
Series.MIN_MINUTES = 0.1

-- Minutes -> seconds, or "all".
function Series.Span(minutes)
	if type(minutes) ~= "number" or minutes <= 0 then return "all" end
	return min(minutes, Series.MAX_MINUTES) * 60
end

-- Wheel step: minutes after zooming in (dir > 0) or out (dir < 0) by about a quarter (0.1 min at least).
-- `history` (s) is the data available; from "all time" zooming in starts just under the history length.
function Series.StepMinutes(minutes, dir, history)
	if type(minutes) ~= "number" or minutes <= 0 then
		if dir > 0 then return min(Series.MAX_MINUTES, max(1, math.ceil(history / 60 * 0.75))) end
		return 0
	end
	local function round1(v) return floor(v * 10 + 0.5) / 10 end
	local step = max(0.1, round1(minutes * 0.25))
	local m = round1(dir > 0 and minutes - step or minutes + step)
	return max(Series.MIN_MINUTES, min(Series.MAX_MINUTES, m))
end

local Store = {}
Store.__index = Store

function Series.New(startTime)
	local self = setmetatable({ startTime = startTime or 0, tiers = {}, keyList = {}, keySet = {} }, Store)
	for i, def in ipairs(Series.TIERS) do
		self.tiers[i] = { w = def.w, cap = def.cap, dur = {}, vals = {}, cur = nil, first = nil }
		for s = 0, def.cap - 1 do self.tiers[i].dur[s] = 0 end
	end
	return self
end

local function clearSlot(tier, slot)
	tier.dur[slot] = 0
	for _, arr in pairs(tier.vals) do arr[slot] = 0 end
end

local function advance(tier, idx)
	if not tier.cur then
		tier.cur, tier.first, tier.start = idx, idx, idx
		clearSlot(tier, idx % tier.cap)
	elseif idx > tier.cur then
		for i = max(tier.cur + 1, idx - tier.cap + 1), idx do
			clearSlot(tier, i % tier.cap)
		end
		tier.cur = idx
		tier.first = max(tier.first, idx - tier.cap + 1)
	end
end

-- Record one sample. `values` maps key -> rate (units per second) over the last `dt` seconds.
function Store:Add(t, dt, values)
	if dt <= 0 then return end
	for k in pairs(values) do
		if not self.keySet[k] then
			self.keySet[k] = true
			self.keyList[#self.keyList + 1] = k
		end
	end
	for _, tier in ipairs(self.tiers) do
		local idx = floor(t / tier.w)
		advance(tier, idx)
		local slot = tier.cur % tier.cap
		tier.dur[slot] = tier.dur[slot] + dt
		for k, rate in pairs(values) do
			local arr = tier.vals[k]
			if not arr then
				if rate == 0 then arr = nil
				else
					arr = {}
					for s = 0, tier.cap - 1 do arr[s] = 0 end
					tier.vals[k] = arr
				end
			end
			if arr then arr[slot] = arr[slot] + rate * dt end
		end
	end
end

function Store:Keys() return self.keyList end

-- True unless the tier has already overwritten (wrapped past) data at time t.
local function covers(tier, t)
	return not tier.cur or tier.first == tier.start or tier.first * tier.w <= t
end

-- Coarsest tier whose bucket is not wider than one output column. With `t0`, falls back to coarser tiers while the
-- picked one no longer reaches back to t0, so old data shows at lower detail instead of not at all.
function Store:PickTier(span, n, t0)
	local target = span / n
	local tiers = self.tiers
	local i = 1
	for k, tier in ipairs(tiers) do
		if tier.w <= target then i = k end
	end
	if t0 then
		while i < #tiers and not covers(tiers[i], t0) do i = i + 1 end
	end
	return tiers[i]
end

-- Column grid for drawing [t0, t1) in about n columns: each column is a whole number of slots of the picked tier and
-- starts on a multiple of its own width, so a window that slides with time maps every column to the same slots on
-- each redraw (otherwise columns alternate between 1 and 2 slots and the picture shimmers). Returns t0, t1, n.
-- When old data only survives in a coarser tier, a column is a whole fraction of a slot instead: each slot then
-- fills several columns, so a window shorter than a slot still shows a line rather than a single dot.
function Store:Grid(t0, t1, n)
	local fine = self:PickTier(t1 - t0, n).w
	local function snap(w)
		local step = max(1, floor((t1 - t0) / n / w)) * w
		if w > fine then step = w / max(1, floor(w * n / (t1 - t0))) end
		local c1 = math.ceil(t1 / step)
		local cn = max(1, math.ceil((t1 - t0) / step - 1e-9))
		return (c1 - cn) * step, c1 * step, cn
	end
	local tier = self:PickTier(t1 - t0, n, t0)
	local a, b, cn = snap(tier.w)
	-- snapping moves the start back a little: pick again from there so Query (given this grid) uses the same tier
	local tier2 = self:PickTier(t1 - t0, n, a)
	if tier2 ~= tier then a, b, cn = snap(tier2.w) end
	return a, b, cn
end

-- Returns an array of n values (false where there is no data) covering [t0, t1).
-- complete: also false for columns that include the newest bucket, which is still filling (its value changes
-- with every sample, so a live graph would redraw its newest segments each time).
function Store:Query(key, t0, t1, n, complete)
	local out = {}
	local tier = self:PickTier(t1 - t0, n, t0)
	local arr = tier.vals[key]
	local w, cap = tier.w, tier.cap
	local step = (t1 - t0) / n
	for c = 1, n do
		local v = false
		if tier.cur then
			local a = t0 + (c - 1) * step
			local i0 = floor(a / w)
			local i1 = max(i0, floor((a + step - 1e-9) / w))
			if complete and i1 >= tier.cur then i1 = i0 - 1 end
			i0, i1 = max(i0, tier.first), min(i1, tier.cur)
			local sum, dur = 0, 0
			for i = i0, i1 do
				local slot = i % cap
				dur = dur + tier.dur[slot]
				if arr then sum = sum + arr[slot] end
			end
			if dur > 0 then v = sum / dur end
		end
		out[c] = v
	end
	return out, tier.w
end

-- Nearest edge of recorded data strictly before t (dir < 0: end of the newest earlier slot) or after t (dir > 0:
-- start of the oldest later slot). Finest tier first, falling back to coarser ones for old data. nil if none.
function Store:DataEdge(t, dir)
	local tiers = self.tiers
	for k, tier in ipairs(tiers) do
		local w, cap = tier.w, tier.cap
		if not tier.cur then return nil end
		if dir < 0 then
			for i = min(floor(t / w) - 1, tier.cur), tier.first, -1 do
				if tier.dur[i % cap] > 0 then return (i + 1) * w end
			end
		elseif covers(tier, t) or k == #tiers then
			-- a tier that no longer reaches back to t would skip the data between t and its oldest slot
			for i = max(math.ceil(t / w), tier.first), tier.cur do
				if tier.dur[i % cap] > 0 then return i * w end
			end
			return nil
		end
	end
end

-- Average rate of `key` over [t0, t1).
function Store:Average(key, t0, t1)
	local v = self:Query(key, t0, t1, 1)
	return v[1] or 0
end

----------------------------------------------------------------------
-- Polyline simplification
----------------------------------------------------------------------

-- Simplifies points i..j of (xs, ys), x increasing, so that every dropped point lies within `tol` (vertically) of the
-- drawn line. Appends the kept indices in order to `out`. Flat or straight stretches collapse to one segment, so the
-- graph needs far fewer textures. One pass, no allocation: from the last kept point, each later point narrows the
-- cone of slopes that pass within `tol` of it; a point whose own slope leaves the cone ends the segment before it.
function Series.Simplify(xs, ys, i, j, tol, out)
	out = out or {}
	out[#out + 1] = i
	if j <= i then return out end
	local huge = math.huge
	local xa, ya, lo, hi = xs[i], ys[i], -huge, huge
	local k = i + 1
	while k <= j do
		local dx = xs[k] - xa
		local s = (ys[k] - ya) / dx
		if s < lo or s > hi then
			out[#out + 1] = k - 1
			xa, ya, lo, hi = xs[k - 1], ys[k - 1], -huge, huge
		else
			local d = tol / dx
			if s - d > lo then lo = s - d end
			if s + d < hi then hi = s + d end
			k = k + 1
		end
	end
	out[#out + 1] = j
	return out
end

----------------------------------------------------------------------
-- Zoom / pan window
----------------------------------------------------------------------

-- zoom: window length in minutes (0 = all time); offset: seconds the window end is behind live.
-- Returns t0, t1, span, offset (offset clamped to the available history).
function Series.Window(now, startTime, zoom, offset)
	local span = Series.Span(zoom)
	if span == "all" then
		return startTime, now, max(now - startTime, 60), 0
	end
	local history = now - startTime
	offset = max(0, min(offset or 0, max(0, history - span)))
	return now - offset - span, now - offset, span, offset
end

-- Offset after zooming to `zoom` around time `tc`, kept at `frac` (0 = left edge, 1 = right edge) of the window,
-- so the point under the cursor stays under it. Clamped to the available history.
function Series.ZoomAt(now, startTime, zoom, tc, frac)
	local span = Series.Span(zoom)
	if span == "all" then return 0 end
	frac = max(0, min(1, frac or 1))
	local _, _, _, o = Series.Window(now, startTime, zoom, now - (tc + (1 - frac) * span))
	return o
end

-- Offset while dragging the graph: the window that ended at `endTime` when the drag began, moved back in time by
-- `frac` of a window (dragging right shows older data, left newer). Clamped to the available history.
function Series.DragOffset(now, startTime, zoom, endTime, frac)
	local span = Series.Span(zoom)
	if span == "all" then return 0 end
	local _, _, _, o = Series.Window(now, startTime, zoom, now - (endTime - frac * span))
	return o
end

-- Offset that brings data edge `edge` (from Store:DataEdge) into an empty window, leaving about JUMP_GAP of the
-- window without data: dir < 0 puts the end of older data near the right edge, dir > 0 the start of newer data
-- near the left edge. Clamped to the available history.
Series.JUMP_GAP = 0.1
function Series.JumpOffset(now, startTime, zoom, edge, dir)
	local span = Series.Span(zoom)
	if span == "all" then return 0 end
	local t1 = dir < 0 and edge + span * Series.JUMP_GAP or edge - span * Series.JUMP_GAP + span
	local _, _, _, o = Series.Window(now, startTime, zoom, now - t1)
	return o
end

-- dir: "back1" | "back" | "fwd" | "fwd1" | "live" ; back/fwd move by a quarter window, 1 = a whole window
function Series.Pan(now, startTime, zoom, offset, dir)
	local span = Series.Span(zoom)
	if span == "all" then return 0 end
	if dir == "live" then return 0 end
	local step = (dir == "back1" or dir == "fwd1") and span or span / 4
	if dir == "fwd" or dir == "fwd1" then step = -step end
	local _, _, _, o = Series.Window(now, startTime, zoom, (offset or 0) + step)
	return o
end
