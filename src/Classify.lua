-- Pure logic: decide what caused a frame-time spike. No WoW API.
local ADDON, OMP = ...
local Classify = {}
OMP.Classify = Classify

-- A frame is a lag spike when it passes the threshold and is clearly longer than the recent frames (avgMs). At a
-- steady low frame rate (weak PC, raid, low background FPS cap) every frame passes the threshold, yet none is a spike:
-- without this check they would flood the log and the chat.
Classify.SPIKE_FACTOR = 2
function Classify.IsSpike(ms, avgMs, threshold)
	return ms >= threshold and ms >= (avgMs or 0) * Classify.SPIKE_FACTOR
end

--[[ spike = {
	dur       = frame time in ms,
	deltas    = { addonName = ms of Lua CPU spent during the spike frame } (nil when scriptProfile is off),
	memDropKB = memory freed during the frame (garbage collection indicator),
	latency / prevLatency = ms,
	loading   = true when a loading screen / zone change was in progress,
	combat    = bool
}
Returns { kind = "addon"|"mixed"|"engine"|"unknown", culprits = {{name, ms}...}, luaMs, hint }
]]
function Classify.Spike(spike)
	local res = { culprits = {}, luaMs = 0 }
	local hints = {}

	if spike.deltas then
		local list, total = {}, 0
		for name, ms in pairs(spike.deltas) do
			if ms > 0.05 then
				list[#list + 1] = { name = name, ms = ms }
				total = total + ms
			end
		end
		table.sort(list, function(a, b) return a.ms > b.ms end)
		res.luaMs = total
		for i = 1, math.min(#list, 5) do
			if i == 1 or list[i].ms >= total * 0.1 then res.culprits[#res.culprits + 1] = list[i] end
		end
		local share = total / spike.dur
		if share >= 0.5 then res.kind = "addon"
		elseif share >= 0.2 then res.kind = "mixed"
		else res.kind = "engine" end
	else
		res.kind = "unknown"
	end

	if spike.loading then hints[#hints + 1] = "loading screen / zone change" end
	if (spike.memDropKB or 0) > 512 then
		hints[#hints + 1] = string.format("garbage collection (%.1f MB freed)", spike.memDropKB / 1024)
	end
	if spike.latency and spike.prevLatency and spike.latency - spike.prevLatency > 150 then
		hints[#hints + 1] = string.format("network latency jump %d -> %d ms", spike.prevLatency, spike.latency)
	end
	if res.kind == "engine" or res.kind == "mixed" then
		if #hints == 0 then hints[#hints + 1] = "client work outside Lua (rendering, disk, model loading)" end
	end
	if spike.combat and res.kind ~= "addon" then hints[#hints + 1] = "in combat" end
	res.hint = table.concat(hints, "; ")
	return res
end

function Classify.Describe(res, dur)
	local parts = {}
	for _, c in ipairs(res.culprits) do
		parts[#parts + 1] = string.format("%s %.0fms", c.name, c.ms)
	end
	local head
	if res.kind == "addon" then head = "Addon: " .. table.concat(parts, ", ")
	elseif res.kind == "mixed" then head = "Mixed: " .. table.concat(parts, ", ")
	elseif res.kind == "engine" then head = "Not addon Lua"
	else head = "Unknown cause" end
	if res.hint ~= "" then head = head .. " (" .. res.hint .. ")" end
	return head
end
