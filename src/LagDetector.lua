-- Records frame-time spikes and what caused them. Fed by the Sampler's per-frame deltas.
local ADDON, OMP = ...
local LD = {}
OMP.LagDetector = LD

local lastAlert = 0

OMP:On("DB_READY", function()
	OMP.db.lags = OMP.db.lags or {}
	OMP.sessionId = time()
end)

-- delta: addon index -> Lua ms spent in the spike frame; idxList: indices present in delta.
function LD:Spike(elapsed, delta, idxList, memDropKB, prevLatency)
	local db = OMP.db
	local dur = elapsed * 1000

	local deltas
	if OMP.profiling then
		deltas = {}
		local names = OMP.addons
		for k = 1, #idxList do
			local i = idxList[k]
			local d = delta[i]
			if d and d > 0 then deltas[names[i]] = d end
		end
	end

	local _, _, latency = GetNetStats()
	local combat = UnitAffectingCombat("player") and true or false
	local res = OMP.Classify.Spike({
		dur = dur, deltas = deltas, memDropKB = memDropKB,
		latency = latency, prevLatency = prevLatency,
		loading = OMP.loading, combat = combat,
	})

	local culprits = {}
	for i, c in ipairs(res.culprits) do culprits[i] = { name = c.name, ms = c.ms } end
	local entry = {
		t = GetTime(), session = OMP.sessionId, stamp = date("%m-%d %H:%M:%S"),
		dur = dur, kind = res.kind, culprits = culprits, luaMs = res.luaMs, hint = res.hint,
		fps = GetFramerate(), latency = latency, combat = combat,
		zone = GetRealZoneText(), memDropKB = memDropKB > 0 and memDropKB or 0,
	}
	entry.text = OMP.Classify.Describe(res, dur)

	local log = db.lags
	log[#log + 1] = entry
	while #log > db.maxLagLog do table.remove(log, 1) end

	if db.lagAlert and entry.t - lastAlert > 2 then
		lastAlert = entry.t
		OMP:Print(string.format("|cffff6060lag %.0f ms|r - %s", dur, entry.text))
	end
	OMP:Fire("LAG", entry)
end

function LD:Clear()
	OMP.db.lags = {}
	OMP:Fire("LAG")
end
