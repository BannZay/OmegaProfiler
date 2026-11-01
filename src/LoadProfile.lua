-- Loading-screen profiling: per-addon cost of the login/reload and of zone loading screens.
-- Entry = { kind="login"|"zone", stamp, wall (ms), luaMs, addons = { name = {cpu=ms, wall=ms, mem=KB} } }
local ADDON, OMP = ...
local LP = {}
OMP.LoadProfile = LP

local debugprofilestop = debugprofilestop

local adLoadedAt = {}     -- addon -> wall ms at ADDON_LOADED
local adWall = {}         -- addon -> wall ms spent loading it (delta to the previous ADDON_LOADED)
local firstEvent, lastEvent
local snapLeave, leaveWall

OMP:On("ADDON_LOADED", function(name)
	local now = debugprofilestop()
	if not firstEvent then
		firstEvent = now
	else
		-- Time since the previous ADDON_LOADED = file parsing/execution of this addon.
		adWall[name] = now - lastEvent
	end
	lastEvent = now
end)

local function newEntry(kind)
	return { kind = kind, stamp = date("%Y-%m-%d %H:%M:%S"), addons = {}, wall = 0, luaMs = 0 }
end

local function push(entry)
	local db = OMP.db
	db.loads = db.loads or {}
	db.loads[#db.loads + 1] = entry
	while #db.loads > db.maxLoadHistory do table.remove(db.loads, 1) end
	OMP.lastLoad = entry
	OMP:Fire("LOAD_PROFILE", entry)
end

-- Login / reload: cumulative CPU at PLAYER_LOGIN is the load cost (scriptProfile must be on).
OMP:On("PLAYER_LOGIN", function()
	local entry = newEntry("login")
	local cpu = OMP:SnapshotCPU({})
	local names = OMP.addons
	local wallTotal = 0
	for i = 1, OMP.numAddons do
		local n = names[i]
		if IsAddOnLoaded(i) then
			local a = { cpu = cpu[i] or 0, wall = adWall[n] or 0 }
			entry.addons[n] = a
			entry.luaMs = entry.luaMs + a.cpu
			wallTotal = wallTotal + a.wall
		end
	end
	-- Wall time between the first ADDON_LOADED we saw and now (addons loaded before us are not covered).
	entry.wall = firstEvent and (debugprofilestop() - firstEvent) or wallTotal
	entry.profiled = OMP.profiling and true or false
	entry.partial = true
	entry.coveredAddons = firstEvent and "from " .. ADDON .. " onward" or nil
	push(entry)
end)

-- Zone loading screens.
OMP:On("PLAYER_LEAVING_WORLD", function()
	leaveWall = debugprofilestop()
	snapLeave = OMP:SnapshotCPU({})
end)

OMP:On("PLAYER_ENTERING_WORLD", function()
	if not leaveWall then return end -- initial login enter; covered by the login entry
	local entry = newEntry("zone")
	entry.wall = debugprofilestop() - leaveWall
	entry.zone = GetRealZoneText()
	entry.profiled = OMP.profiling and true or false
	if OMP.profiling then
		local after = OMP:SnapshotCPU({})
		for i = 1, OMP.numAddons do
			local d = (after[i] or 0) - (snapLeave[i] or 0)
			if d > 0.01 then
				entry.addons[OMP.addons[i]] = { cpu = d, wall = 0 }
				entry.luaMs = entry.luaMs + d
			end
		end
	end
	leaveWall, snapLeave = nil, nil
	push(entry)
end)

-- Rows sorted for display: returns array of {name, cpu, wall}.
function LP:Rows(entry, sortBy)
	local rows = {}
	for n, a in pairs(entry.addons) do rows[#rows + 1] = { name = n, cpu = a.cpu, wall = a.wall, total = a.cpu + a.wall } end
	table.sort(rows, function(a, b)
		if a[sortBy] ~= b[sortBy] then return a[sortBy] > b[sortBy] end
		return a.name < b.name
	end)
	return rows
end
