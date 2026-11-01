-- CPU sampling. UpdateAddOnCPUUsage walks the whole Lua object list, so it is only called once per
-- sample tick (and once more when a lag spike needs attribution), never every frame.
local ADDON, OMP = ...

OMP.store = OMP.Series.New(GetTime())
OMP.loading = true   -- a fresh Lua state (login, /reload) starts inside a loading screen
OMP.lastRates = {}

local prev, cur, delta, acc, baseline = {}, {}, {}, {}, {}
local loadedIdx, dirty = {}, true
local accTime, snapTime = 0, 0
local spikeInAcc = false
local lastMem = collectgarbage("count")
local prevLatency = 0
local resync = true
local graceUntil = 0   -- other addons finish initialising right after entering the world
local avgFrameMs = 0   -- smoothed recent frame time, so a steady low frame rate is not logged as spikes

OMP.cpuNow = cur  -- cumulative ms per addon index at the last snapshot

local function rebuildLoaded()
	loadedIdx = {}
	for i = 1, OMP.numAddons or 0 do
		if IsAddOnLoaded(i) then loadedIdx[#loadedIdx + 1] = i end
	end
	OMP.loadedIdx = loadedIdx
	dirty = false
end

-- Reads cumulative CPU for every loaded addon into `into` (index -> ms).
function OMP:SnapshotCPU(into)
	if not self.profiling then return into end
	UpdateAddOnCPUUsage()
	if dirty then rebuildLoaded() end
	for k = 1, #loadedIdx do
		local i = loadedIdx[k]
		into[i] = GetAddOnCPUUsage(i)
	end
	return into
end

-- Takes a snapshot, adds the change since the previous one to `acc`, fills `delta` (index -> ms).
local function takeSnapshot()
	UpdateAddOnCPUUsage()
	for k = 1, #loadedIdx do
		local i = loadedIdx[k]
		local c = GetAddOnCPUUsage(i)
		local p = prev[i]
		local d = p and (c - p) or 0
		if d < 0 then d = 0 end
		prev[i], cur[i], delta[i] = c, c, d
		acc[i] = (acc[i] or 0) + d
	end
	snapTime = GetTime()
end

function OMP:ResetData()
	self.store = self.Series.New(GetTime())
	self.db.liveData = nil
	for k in pairs(acc) do acc[k] = nil end
	accTime = 0
	self.lastRates = {}
	self:Fire("RESET")
	self:Print("graph data cleared")
end

OMP:On("DB_READY", function()
	OMP.profiling = OMP:ProfilingEnabled()
	rebuildLoaded()
	local saved = OMP.db.liveData
	OMP.db.liveData = nil   -- re-written on logout; never keep a stale copy
	if OMP.db.saveLive and saved then
		local ok, store = pcall(OMP.Persist.Import, saved, GetTime(), time(), 86400, OMP.savedStrings)
		if ok and store then OMP.store = store end
	end
end)

-- Runs on /reload and logout. Uses the data-size cap from the options.
OMP:On("PLAYER_LOGOUT", function()
	local db = OMP.db
	if not db then return end
	db.liveData = nil
	if db.saveLive then
		local ok, data = pcall(OMP.Persist.Export, OMP.store, GetTime(), time(), db.saveMaxKB * 1024, OMP.savePool)
		if ok then db.liveData = data end
	end
end)
OMP:On("ADDON_LOADED", function() dirty = true end)
OMP:On("PLAYER_LEAVING_WORLD", function() OMP.loading = true end)
OMP:On("PLAYER_ENTERING_WORLD", function()
	OMP.loading = false
	graceUntil = GetTime() + 3
	resync = true
	dirty = true
end)

-- A spike frame: attribute the CPU that appeared since the last snapshot, minus what each
-- addon normally burns in that much time (its baseline rate), to the spike.
local function onSpike(elapsed)
	local age = GetTime() - snapTime
	takeSnapshot()
	local attribution = {}
	local calm = math.max(0, age - elapsed)
	for k = 1, #loadedIdx do
		local i = loadedIdx[k]
		local a = delta[i] - (baseline[i] or 0) * calm
		attribution[i] = a > 0 and a or 0
	end
	spikeInAcc = true
	return attribution
end

local frame = CreateFrame("Frame")
frame:SetScript("OnUpdate", function(_, elapsed)
	local db = OMP.db
	if not db or elapsed <= 0 then return end
	if dirty then rebuildLoaded() end

	local mem = collectgarbage("count")
	local memDrop = lastMem - mem
	lastMem = mem

	if resync then
		resync = false
		accTime = 0
		for k in pairs(acc) do acc[k] = nil end
		if OMP.profiling then takeSnapshot() end
		for k in pairs(acc) do acc[k] = nil end
		return
	end

	local ms = elapsed * 1000
	local spike = OMP.Classify.IsSpike(ms, avgFrameMs, db.lagThreshold)
	avgFrameMs = avgFrameMs * 0.9 + ms * 0.1
	if spike and not OMP.loading and GetTime() >= graceUntil then
		local attribution = OMP.profiling and onSpike(elapsed) or nil
		OMP.LagDetector:Spike(elapsed, attribution, loadedIdx, memDrop, prevLatency)
	end

	accTime = accTime + elapsed
	if accTime < db.sampleInterval then return end

	local rates = {}
	if OMP.profiling then
		takeSnapshot()
		local names = OMP.addons
		local sum = 0
		for k = 1, #loadedIdx do
			local i = loadedIdx[k]
			local a = acc[i]
			if a and a > 0 then
				local r = a / accTime
				rates[names[i]] = r
				sum = sum + a
			end
			if not spikeInAcc then
				-- baseline = smoothed normal rate in ms/s (ignores intervals that contained a spike)
				baseline[i] = (baseline[i] or 0) * 0.7 + ((a or 0) / accTime) * 0.3
			end
			acc[i] = 0
		end
		rates.__total = sum / accTime
		spikeInAcc = false
	end
	rates.__fps = GetFramerate()
	local _, _, latency = GetNetStats()
	rates.__lat = latency
	prevLatency = latency

	OMP.store:Add(GetTime(), accTime, rates)
	OMP.lastRates = rates
	accTime = 0
	OMP:Fire("SAMPLE", rates)
end)
