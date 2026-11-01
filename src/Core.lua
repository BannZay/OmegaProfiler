-- OmegaProfiler core: namespace, saved variables, addon list, event dispatch.
local ADDON, OMP = ...
_G.OmegaProfiler = OMP

OMP.name = ADDON
OMP.callbacks = {}

local DEFAULTS = {
	sampleInterval = 0.5,   -- seconds between graph samples
	lagThreshold = 100,     -- ms; frames longer than this are lag spikes
	lagAlert = true,        -- print a chat line on each lag spike
	maxLagLog = 1000,
	maxLoadHistory = 50,
	saveLive = true,      -- keep the graph data across /reload and relog
	saveMaxKB = 1024,       -- size cap for the saved graph data
	showMinimap = true,
	minimapAngle = 215,
	zoom = 5,               -- live graph window in minutes; 0 = all time
	yMax = 0,               -- top of the live graph's vertical scale; 0 = fit the visible data
	includeSelf = false,    -- show OmegaProfiler itself on the graph
	selected = {},
	firstRunDone = false,
}

local function CopyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			if type(v) == "table" then
				dst[k] = {}
				CopyDefaults(dst[k], v)
			else
				dst[k] = v
			end
		end
	end
end

-- Minimal callback registry so modules stay decoupled (UI listens to data modules).
function OMP:On(event, fn)
	local list = self.callbacks[event]
	if not list then list = {}; self.callbacks[event] = list end
	list[#list + 1] = fn
end

function OMP:Fire(event, ...)
	local list = self.callbacks[event]
	if list then
		for i = 1, #list do list[i](...) end
	end
end

function OMP:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffOmegaProfiler|r: " .. tostring(msg))
end

function OMP:ProfilingEnabled()
	return GetCVar("scriptProfile") == "1"
end

----------------------------------------------------------------------
-- Addon list (indices are stable for a session)
----------------------------------------------------------------------
OMP.addons = {}      -- [i] = name
OMP.addonIndex = {}  -- name -> i

function OMP:RefreshAddonList()
	local n = GetNumAddOns()
	for i = 1, n do
		local name = GetAddOnInfo(i)
		self.addons[i] = name
		self.addonIndex[name] = i
	end
	self.numAddons = n
end

local colors = {
	{0.20, 0.60, 1.00}, {1.00, 0.55, 0.10}, {0.30, 0.85, 0.30}, {0.95, 0.25, 0.30},
	{0.70, 0.45, 1.00}, {0.95, 0.85, 0.15}, {0.20, 0.85, 0.85}, {1.00, 0.45, 0.80},
	{0.60, 0.80, 0.20}, {0.55, 0.55, 0.95}, {0.90, 0.60, 0.45}, {0.45, 0.75, 0.65},
}
-- Drawn addons get distinct colours: each keeps its palette slot while it stays drawn, a newly drawn one takes the
-- lowest free slot. Others fall back to a colour from their addon index.
OMP.colorSlot = {}
function OMP:AssignColors(names)
	local slots, used, keep = self.colorSlot, {}, {}
	for _, n in ipairs(names) do keep[n] = true end
	for n, s in pairs(slots) do
		if keep[n] then used[s] = true else slots[n] = nil end
	end
	local free = 1
	for _, n in ipairs(names) do
		if not slots[n] then
			while used[free] do free = free + 1 end
			slots[n], used[free] = free, true
		end
	end
end

function OMP:ColorFor(name)
	local i = self.colorSlot[name] or self.addonIndex[name] or 1
	local c = colors[(i - 1) % #colors + 1]
	return c[1], c[2], c[3]
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local frame = CreateFrame("Frame")
OMP.eventFrame = frame
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
-- Saved form: db.strings holds every repeated string once; db.lagRows / db.loadRows / db.liveData refer to it
-- by index (see Pack.lua). In memory db.lags / db.loads are full tables.
local function UnpackSaved(db)
	local list = db.strings or {}
	if db.lagRows then
		local ok, log = pcall(OMP.Pack.UnpackLags, db.lagRows, list)
		db.lags = ok and log or db.lags
	end
	if db.loadRows then
		local ok, loads = pcall(OMP.Pack.UnpackLoads, db.loadRows, list)
		db.loads = ok and loads or db.loads
	end
	db.lagRows, db.loadRows, db.strings = nil, nil, nil
	OMP.savedStrings = list   -- for the liveData import in DB_READY
end

-- OMP.savePool collects the strings while PLAYER_LOGOUT handlers write their data.
local function PackSaved(db)
	local pool = OMP.savePool
	local ok, lagRows = pcall(OMP.Pack.Lags, db.lags or {}, pool)
	local ok2, loadRows = pcall(OMP.Pack.Loads, db.loads or {}, pool)
	if ok and ok2 then
		db.lagRows, db.loadRows, db.lags, db.loads = lagRows, loadRows, nil, nil
	end
	db.strings = #pool.list > 0 and pool.list or nil
end

frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			OmegaProfilerDB = OmegaProfilerDB or {}
			OMP.db = OmegaProfilerDB
			CopyDefaults(OMP.db, DEFAULTS)
			UnpackSaved(OMP.db)
			OMP:RefreshAddonList()
			OMP:Fire("DB_READY")
			OMP.savedStrings = nil
		end
		OMP:Fire("ADDON_LOADED", arg1)
	elseif event == "PLAYER_LOGOUT" then
		if not OMP.db then return end
		OMP.savePool = OMP.Pack.NewPool()
		OMP:Fire(event, arg1)
		PackSaved(OMP.db)
	else
		OMP:Fire(event, arg1)
	end
end)

SLASH_OMEGAPROFILER1 = "/omp"
SLASH_OMEGAPROFILER2 = "/profiler"
SlashCmdList["OMEGAPROFILER"] = function(msg)
	msg = strlower(strtrim(msg or ""))
	if msg == "reset" then
		OMP:ResetData()
	elseif msg == "lags" then
		OMP:ShowUI("Lags")
	elseif msg == "load" then
		OMP:ShowUI("Load")
	elseif msg == "enable" then
		SetCVar("scriptProfile", "1")
		ReloadUI()
	elseif msg == "disable" then
		SetCVar("scriptProfile", "0")
		ReloadUI()
	else
		OMP:ToggleUI()
	end
end
