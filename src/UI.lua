-- Main window: Live graph, Load Time, Lags, Memory and Options tabs.
local ADDON, OMP = ...
local Series = OMP.Series
local UI = {}
OMP.UI = UI

local WHITE = "Interface\\Buttons\\WHITE8X8"
local max, min, floor = math.max, math.min, math.floor
local view = { zoom = 5, anchor = nil, paused = false }
UI.view = view

----------------------------------------------------------------------
-- Widget helpers
----------------------------------------------------------------------
local function Button(parent, text, w, h, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(w, h)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function Label(parent, text, font, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	fs:SetText(text or "")
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

local listCount = 0
-- Scrollable list of fixed-height rows. build(row) creates row widgets; fill(row, data, index) updates them.
local function CreateList(parent, x, y, w, nRows, rowH, build, fill)
	listCount = listCount + 1
	local scroll = CreateFrame("ScrollFrame", "OmegaProfilerList" .. listCount, parent, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", x, y)
	scroll:SetSize(w - 24, nRows * rowH)
	local list = { rows = {}, data = {}, scroll = scroll }
	for i = 1, nRows do
		local row = CreateFrame("Button", nil, parent)
		row:SetSize(w - 24, rowH)
		row:SetPoint("TOPLEFT", scroll, 0, -(i - 1) * rowH)
		build(row)
		list.rows[i] = row
	end
	function list:Update()
		FauxScrollFrame_Update(scroll, #self.data, nRows, rowH)
		local off = FauxScrollFrame_GetOffset(scroll)
		for i, row in ipairs(self.rows) do
			local d = self.data[off + i]
			if d then
				row.data, row.index = d, off + i
				row:Show()
				fill(row, d, off + i)
			else
				row.data = nil
				row:Hide()
			end
		end
	end
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, rowH, function() list:Update() end)
	end)
	return list
end

local function fmtMs(ms)
	if ms >= 1000 then return string.format("%.2f s", ms / 1000) end
	return string.format("%.1f ms", ms)
end

----------------------------------------------------------------------
-- Main frame + tabs
----------------------------------------------------------------------
local main = CreateFrame("Frame", "OmegaProfilerFrame", UIParent)
UI.frame = main
main:SetSize(780, 500)
main:SetPoint("CENTER")
main:SetFrameStrata("HIGH")
main:SetMovable(true)
main:EnableMouse(true)
main:SetClampedToScreen(true)
main:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", main.StartMoving)
main:SetScript("OnDragStop", main.StopMovingOrSizing)
main:Hide()
tinsert(UISpecialFrames, "OmegaProfilerFrame")

local icon = main:CreateTexture(nil, "ARTWORK")
icon:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\media\\icon")
icon:SetSize(28, 28)
icon:SetPoint("TOPLEFT", 19, -12) -- clear of the dialog border (insets 11/12), above the divider at -40
local title = Label(main, "OmegaProfiler", "GameFontNormalLarge")
title:SetPoint("LEFT", icon, "RIGHT", 6, -1)
UI.icon, UI.title = icon, title
local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

local TABS = { "Live", "Load", "Lags", "Memory", "Options" }
local TAB_TITLES = { Live = "Graph", Load = "Load Time", Lags = "Lags", Memory = "Memory", Options = "Options" }
local panels, tabButtons = {}, {}
UI.tabButtons = tabButtons
local currentTab

local function SelectTab(name)
	currentTab = name
	for _, t in ipairs(TABS) do
		if t == name then panels[t]:Show() else panels[t]:Hide() end
		if t == name then tabButtons[t]:LockHighlight() else tabButtons[t]:UnlockHighlight() end
	end
	UI:Refresh()
end

local divider = main:CreateTexture(nil, "ARTWORK")
divider:SetTexture(WHITE)
divider:SetVertexColor(1, 1, 1, 0.25)
divider:SetHeight(1)
divider:SetPoint("TOPLEFT", 16, -40)
divider:SetPoint("TOPRIGHT", -16, -40)

for i, t in ipairs(TABS) do
	local b = Button(main, TAB_TITLES[t], 84, 22, function() SelectTab(t) end)
	b:SetPoint("TOPLEFT", 216 + (i - 1) * 86, -14)
	tabButtons[t] = b
	local p = CreateFrame("Frame", nil, main)
	p:SetPoint("TOPLEFT", 16, -48)
	p:SetPoint("BOTTOMRIGHT", -16, 14)
	p:Hide()
	panels[t] = p
end

-- Profiling-off bar under the tab panels, shown on every tab; the frame grows by its height while it is shown.
local BAR_H = 30
local enableBtn = Button(main, "Enable profiling + reload", 170, 22, function()
	SetCVar("scriptProfile", "1")
	ReloadUI()
end)
enableBtn:SetPoint("BOTTOMRIGHT", -18, 16)
local warn = Label(main, "|cffff6060Script profiling is off.|r CPU per addon needs it (reloads the UI).", "GameFontNormalSmall", "RIGHT")
warn:SetPoint("RIGHT", enableBtn, "LEFT", -8, 0)

local function UpdateProfilingBar()
	local off = not OMP.profiling
	main:SetHeight(500 + (off and BAR_H or 0))
	for _, p in pairs(panels) do p:SetPoint("BOTTOMRIGHT", -16, 14 + (off and BAR_H or 0)) end
	if off then enableBtn:Show(); warn:Show() else enableBtn:Hide(); warn:Hide() end
end

----------------------------------------------------------------------
-- Live tab
----------------------------------------------------------------------
local live = panels.Live
-- Non-addon series, listed under "Other"; selection is stored in db.selected like addons.
local OTHER = {
	{ key = "__total", name = "Total CPU", fmt = "%.2f", r = 1, g = 1, b = 1, unit = "ms/s CPU" },
	{ key = "__fps", name = "FPS", fmt = "%.0f", r = 0.3, g = 0.9, b = 0.5, unit = "FPS" },
	{ key = "__lat", name = "Latency", fmt = "%.0f", r = 0.95, g = 0.75, b = 0.3, unit = "latency ms" },
}
local OTHER_BY_KEY = {}
for _, o in ipairs(OTHER) do OTHER_BY_KEY[o.key] = o end

local zoomBox
local function SetZoom(m)
	view.zoom = m
	OMP.db.zoom = m
	if m <= 0 then view.anchor = nil end
	UI:Refresh()
end

-- playback-style controls along the bottom of the tab
-- the two buttons are centred under the graph (520 wide)
local presentBtn = Button(live, ">>", 40, 22, function()
	view.anchor = nil
	SetZoom(5)
end)
presentBtn:SetPoint("BOTTOM", live, "BOTTOMLEFT", 247, 0)

local pauseBtn = CreateFrame("Button", nil, live)
pauseBtn:SetSize(22, 22)
pauseBtn:SetNormalTexture("Interface\\TimeManager\\PauseButton")
pauseBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
-- the icon's round frame is part of its texture, so a paused ">" gets a panel-button frame of its own
pauseBtn.frame = pauseBtn:CreateTexture(nil, "BACKGROUND")
pauseBtn.frame:SetTexture("Interface\\Buttons\\UI-Panel-Button-Up")
pauseBtn.frame:SetTexCoord(0, 0.625, 0, 0.6875)
pauseBtn.frame:SetAllPoints()
pauseBtn.frame:Hide()
pauseBtn.play = Label(pauseBtn, ">", "GameFontNormalLarge", "CENTER")
pauseBtn.play:SetPoint("CENTER")
pauseBtn:SetScript("OnClick", function()
	view.paused = not view.paused
	UI:Refresh()
end)
pauseBtn:SetPoint("BOTTOM", live, "BOTTOMLEFT", 282, 0)

local zoomLbl = Label(live, "Scale:", "GameFontHighlightSmall")
zoomLbl:SetPoint("BOTTOMLEFT", 0, 5)
zoomBox = CreateFrame("EditBox", nil, live, "InputBoxTemplate")
zoomBox:SetSize(46, 20)
zoomBox:SetPoint("LEFT", zoomLbl, "RIGHT", 10, 0)
zoomBox:SetAutoFocus(false)
zoomBox:SetMaxLetters(7)
zoomBox:SetScript("OnEnterPressed", function(self)
	local v = tonumber(self:GetText())
	if v then SetZoom(v <= 0 and 0 or max(Series.MIN_MINUTES, min(Series.MAX_MINUTES, v))) end
	self:ClearFocus()
	UI:Refresh()
end)
zoomBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); UI:Refresh() end)
zoomBox:SetScript("OnEditFocusLost", function() UI:Refresh() end)
zoomBox:EnableMouseWheel(true)
zoomBox:SetScript("OnMouseWheel", function(_, d) UI.graph.onWheel(d) end)

local graph = OMP.CreateGraph(live)
UI.graph = graph
graph.frame:SetPoint("TOPLEFT", 0, 0)
graph.frame:SetPoint("BOTTOMRIGHT", live, "BOTTOMLEFT", 520, 30)
graph.hints = { "Wheel: zoom", "Left-drag: zoom to period", "Right-drag: move in time" }

-- vertical scale buttons left of the y labels: fixed top (db.yMax) so the graph does not rescale on every spike
local function SetYMax(v)
	OMP.db.yMax = (v and v > 0) and v or 0
	UI:Refresh()
end
local function Tip(b, title, text)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title)
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
local function ScaleArrow(dir, y)
	local b = CreateFrame("Button", nil, graph.frame)
	b:SetSize(18, 16)
	b:SetPoint("LEFT", graph.frame, "LEFT", 3, y)
	local tex = "Interface\\Buttons\\UI-ScrollBar-Scroll" .. (dir > 0 and "Up" or "Down") .. "Button-"
	b:SetNormalTexture(tex .. "Up")
	b:SetPushedTexture(tex .. "Down")
	b:SetHighlightTexture(tex .. "Highlight", "ADD")
	b:SetScript("OnClick", function()
		-- steps from the scale currently shown, so the first click from auto keeps the view close
		SetYMax(OMP.NiceStep(OMP.db.yMax > 0 and OMP.db.yMax or graph.ymax or 1, dir))
	end)
	return b
end
Tip(presentBtn, "Back to live", "Jumps to the present and resets the scale to 5 minutes.")
Tip(pauseBtn, "Pause / resume", "Freezes the graph (shows > while paused); click again to resume.")
Tip(zoomBox, "Scale", "Width of the graph in minutes; 0 shows everything recorded.")
local scaleUp = ScaleArrow(1, 18)
Tip(scaleUp, "Raise the scale top", "Fixes the top of the vertical scale at the next higher value: lines get flatter.")
local autoBtn = Button(graph.frame, "A", 20, 18, function() SetYMax(0) end)
autoBtn:SetPoint("LEFT", graph.frame, "LEFT", 2, 0)
Tip(autoBtn, "Auto scale", "The vertical scale follows the highest visible value (lit while on). The arrows fix it instead, so it stops jumping when spikes come and go.")
local scaleDown = ScaleArrow(-1, -18)
Tip(scaleDown, "Lower the scale top", "Fixes the top of the vertical scale at the next lower value: small lines get taller, lines above it are clipped.")

graph.onWheel = function(d, tc, frac)
	-- wheel up zooms in (smaller window), wheel down zooms out; over the graph the time under the cursor stays put
	local now = GetTime()
	local m = Series.StepMinutes(view.zoom, d > 0 and 1 or -1, now - OMP.store.startTime)
	if tc and m > 0 then
		local offset = Series.ZoomAt(now, OMP.store.startTime, m, tc, frac)
		view.anchor = offset > 0.5 and (now - offset) or nil
	end
	SetZoom(m)
end

-- right-drag on the graph: move the window along time like grabbing the plot
local panEnd
graph.onPanStart = function()
	panEnd = view.anchor or GetTime()
end
graph.onPan = function(frac)
	if view.zoom <= 0 or not panEnd then return end
	local now = GetTime()
	local offset = Series.DragOffset(now, OMP.store.startTime, view.zoom, panEnd, frac)
	view.anchor = offset > 0.5 and (now - offset) or nil
	UI:Refresh()
end

-- "<" / ">" over an empty window: move to the nearest data, leaving about 10% of the window empty
graph.onJump = function(dir, edge)
	local now = GetTime()
	local offset = Series.JumpOffset(now, OMP.store.startTime, view.zoom, edge, dir)
	view.anchor = offset > 0.5 and (now - offset) or nil
	UI:Refresh()
end

-- drag on the graph: focus on the selected period (at least 6 s = 0.1 min)
graph.onSelect = function(ta, tb)
	local now = GetTime()
	ta = max(ta, OMP.store.startTime)
	tb = min(tb, now)
	local sec = max(Series.MIN_MINUTES * 60, floor(tb - ta + 0.5))
	if sec / 60 > Series.MAX_MINUTES then return end
	view.anchor = (now - tb > 0.5) and tb or nil
	SetZoom(sec / 60)
end

local status = Label(live, "", "GameFontHighlightSmall", "RIGHT")
status:SetPoint("BOTTOMRIGHT", 0, 0)
status:SetWidth(210)

-- addon list
local listHeader = Label(live, "Addons (click to graph)", "GameFontNormalSmall")
listHeader:SetPoint("TOPLEFT", 536, 0)
local listData = {}

local function SelectTop(n)
	local sel = OMP.db.selected
	for k in pairs(sel) do if k:sub(1, 2) ~= "__" then sel[k] = nil end end
	for i = 1, min(n, #listData) do
		sel[listData[i].name] = true
	end
	UI:Refresh()
end
local b1 = Button(live, "Top 5", 54, 20, function() SelectTop(5) end)
b1:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", 0, -3)
local b2 = Button(live, "All", 40, 20, function()
	for _, d in ipairs(listData) do OMP.db.selected[d.name] = true end
	UI:Refresh()
end)
b2:SetPoint("LEFT", b1, "RIGHT", 2, 0)
local b3 = Button(live, "None", 44, 20, function()
	local sel = OMP.db.selected
	for k in pairs(sel) do if k:sub(1, 2) ~= "__" then sel[k] = nil end end
	UI:Refresh()
end)
b3:SetPoint("LEFT", b2, "RIGHT", 2, 0)

-- rows are shared by the addon list and the "Other" rows; data.key (other) or data.name (addon) is the series key
local function BuildRow(row)
	row.sw = row:CreateTexture(nil, "ARTWORK")
	row.sw:SetSize(10, 10)
	row.sw:SetPoint("LEFT", 2, 0)
	row.name = Label(row, "", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", row.sw, "RIGHT", 4, 0)
	row.name:SetWidth(120)
	row.val = Label(row, "", "GameFontHighlightSmall", "RIGHT")
	row.val:SetPoint("RIGHT", -2, 0)
	row:SetHighlightTexture(WHITE)
	row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.12)
	row:SetScript("OnClick", function(self)
		local k = self.data.key or self.data.name
		OMP.db.selected[k] = not OMP.db.selected[k] or nil
		UI:Refresh()
	end)
	row:SetScript("OnEnter", function(self)
		local n = self.data.name
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		if self.data.key then
			GameTooltip:SetText(n)
			GameTooltip:AddDoubleLine("Average in window", string.format(self.data.fmt, self.data.avg), 1, 1, 1, 1, 1, 1)
			GameTooltip:AddLine("Shares the graph's vertical scale with the other lines.", 0.7, 0.7, 0.7, true)
		else
			local _, t = GetAddOnInfo(n)
			GameTooltip:SetText(t or n)
			GameTooltip:AddDoubleLine("Avg CPU in window", string.format("%.2f ms/s", self.data.avg), 1, 1, 1, 1, 1, 1)
			local i = OMP.addonIndex[n]
			if i and OMP.profiling then GameTooltip:AddDoubleLine("CPU since start", fmtMs(OMP.cpuNow[i] or 0), 1, 1, 1, 1, 1, 1) end
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function FillRow(row, d)
	local key = d.key or d.name
	local sel = OMP.db.selected[key]
	local r, g, b
	if d.key then r, g, b = d.r, d.g, d.b else r, g, b = OMP:ColorFor(d.name) end
	if sel then row.sw:SetTexture(r, g, b, 1) else row.sw:SetTexture(0.2, 0.2, 0.2, 1) end
	row.name:SetText(d.name)
	row.name:SetTextColor(sel and 1 or 0.6, sel and 1 or 0.6, sel and 1 or 0.6)
	row.val:SetText(string.format(d.fmt or "%.2f", d.avg))
end

local addonList = CreateList(live, 532, -50, 216, 12, 18, BuildRow, FillRow)

local otherHeader = Label(live, "Other (click to graph)", "GameFontNormalSmall")
otherHeader:SetPoint("TOPLEFT", addonList.scroll, "BOTTOMLEFT", 0, -8)
local otherRows = {}
for i, o in ipairs(OTHER) do
	local row = CreateFrame("Button", nil, live)
	row:SetSize(208, 18)
	row:SetPoint("TOPLEFT", otherHeader, "BOTTOMLEFT", 0, -2 - (i - 1) * 18)
	BuildRow(row)
	row.data = o
	otherRows[i] = row
end

local lastListUpdate = 0
local function UpdateLiveList(t0, t1)
	local store = OMP.store
	listData = {}
	local sel = OMP.db.selected
	for _, key in ipairs(store:Keys()) do
		if key:sub(1, 2) ~= "__" and (key ~= ADDON or OMP.db.includeSelf or sel[key]) then
			listData[#listData + 1] = { name = key, avg = store:Average(key, t0, t1) }
		end
	end
	table.sort(listData, function(a, b)
		if a.avg ~= b.avg then return a.avg > b.avg end
		return a.name < b.name
	end)
	addonList.data = listData
	addonList:Update()
	for i, o in ipairs(OTHER) do
		o.avg = store:Average(o.key, t0, t1)
		FillRow(otherRows[i], o)
	end
end

local MAX_DRAWN = 20
local function RefreshLive(sampleOnly)
	local db = OMP.db
	local sel = db.selected
	local now = GetTime()
	local store = OMP.store
	local offset = view.anchor and (now - view.anchor) or 0
	local t0, t1, span
	t0, t1, span, offset = Series.Window(now, store.startTime, view.zoom, offset)
	if offset <= 0 then view.anchor = nil end

	if not zoomBox:HasFocus() then
		zoomBox:SetText((string.format("%.2f", view.zoom):gsub("%.?0+$", "")))
		zoomBox:SetCursorPosition(0)
	end
	pauseBtn:GetNormalTexture():SetAlpha(view.paused and 0 or 1)
	if view.paused then pauseBtn.play:Show(); pauseBtn.frame:Show() else pauseBtn.play:Hide(); pauseBtn.frame:Hide() end
	if db.yMax > 0 then autoBtn:UnlockHighlight() else autoBtn:LockHighlight() end
	if view.paused and sampleOnly then return end

	local series = {}
	for _, o in ipairs(OTHER) do
		if db.selected[o.key] then
			series[#series + 1] = { key = o.key, label = o.name, other = true, r = o.r, g = o.g, b = o.b }
		end
	end
	local names = {}
	for n in pairs(db.selected) do
		if n:sub(1, 2) ~= "__" then names[#names + 1] = n end
	end
	table.sort(names)
	if #names > MAX_DRAWN then
		-- every drawn point is a texture: keep only the heaviest addons (listData is sorted by average)
		local keep, kept = {}, 0
		for _, d in ipairs(listData) do
			if sel[d.name] and kept < MAX_DRAWN then keep[d.name] = true; kept = kept + 1 end
		end
		local top = {}
		for _, n in ipairs(names) do if keep[n] then top[#top + 1] = n end end
		names = top
	end
	OMP:AssignColors(names)
	for _, n in ipairs(names) do
		local r, g, b = OMP:ColorFor(n)
		series[#series + 1] = { key = n, label = n, r = r, g = g, b = b }
	end
	graph:Draw(store, t0, t1, series, db.lags, db.yMax)

	if not sampleOnly or now - lastListUpdate >= 1 then
		lastListUpdate = now
		UpdateLiveList(t0, t1)
	end

	local rates = OMP.lastRates
	if OMP.profiling then
		status:SetText(string.format("Total Lua CPU: |cffffffff%.1f ms/s|r\nFPS: |cffffffff%.0f|r\nLatency: |cffffffff%d ms|r",
			rates.__total or 0, rates.__fps or 0, rates.__lat or 0))
	else
		status:SetText(string.format("FPS: |cffffffff%.0f|r\nLatency: |cffffffff%d ms|r", rates.__fps or 0, rates.__lat or 0))
	end
end

----------------------------------------------------------------------
-- Load tab
----------------------------------------------------------------------
local load = panels.Load
local loadState = { index = nil, sort = "total", rows = {} }
local loadHeader = Label(load, "", "GameFontHighlight")
loadHeader:SetPoint("TOPLEFT", 0, -30)
loadHeader:SetWidth(720)
local loadNote = Label(load, "", "GameFontNormalSmall")
loadNote:SetPoint("TOPLEFT", loadHeader, "BOTTOMLEFT", 0, -4)
loadNote:SetWidth(720)

local function ShowLoad(delta)
	local loads = OMP.db.loads or {}
	local i = (loadState.index or #loads) + delta
	loadState.index = max(1, min(#loads, i))
	if #loads == 0 then loadState.index = nil end
	UI:Refresh()
end
local olderBtn = Button(load, "< Older", 70, 22, function() ShowLoad(-1) end)
olderBtn:SetPoint("TOPLEFT", 0, 0)
local newerBtn = Button(load, "Newer >", 70, 22, function() ShowLoad(1) end)
newerBtn:SetPoint("LEFT", olderBtn, "RIGHT", 2, 0)
local reloadBtn = Button(load, "Reload UI (measure again)", 170, 22, function()
	OMP.db.reopenLoad = true
	ReloadUI()
end)
reloadBtn:SetPoint("TOPRIGHT", 0, 0)

local loadMax = 1
local LOAD_BAR_W = 380 -- stays clear of the total / CPU / wall numbers on the right
local loadList = CreateList(load, 0, -70, 736, 18, 18, function(row)
	row.barWall = row:CreateTexture(nil, "BACKGROUND")
	row.barWall:SetPoint("LEFT")
	row.barWall:SetHeight(14)
	row.barWall:SetTexture(0.20, 0.60, 1.00, 0.55)
	row.barCpu = row:CreateTexture(nil, "BACKGROUND")
	row.barCpu:SetPoint("LEFT", row.barWall, "RIGHT")
	row.barCpu:SetHeight(14)
	row.barCpu:SetTexture(1.00, 0.55, 0.10, 0.75)
	row.name = Label(row, "", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 4, 0)
	row.total = Label(row, "", "GameFontHighlightSmall", "RIGHT")
	row.total:SetPoint("RIGHT", -216, 0)
	row.cpu = Label(row, "", "GameFontHighlightSmall", "RIGHT")
	row.cpu:SetPoint("RIGHT", -110, 0)
	row.wall = Label(row, "", "GameFontHighlightSmall", "RIGHT")
	row.wall:SetPoint("RIGHT", -4, 0)
end, function(row, d)
	-- Two-part bar: wall (blue) first, then Lua CPU (orange).
	row.barWall:SetWidth(max(0.01, (d.wall / loadMax) * LOAD_BAR_W))
	row.barCpu:SetWidth(max(0.01, (d.cpu / loadMax) * LOAD_BAR_W))
	row.name:SetText(d.name)
	row.total:SetText(fmtMs(d.total))
	row.cpu:SetText(fmtMs(d.cpu))
	row.wall:SetText(d.wall > 0 and fmtMs(d.wall) or "-")
end)
-- Clickable column headers: click to sort by that column (active one is marked with v).
local loadHeaders = {}
local function SortHeader(key, text, color, rightOffset)
	local b = CreateFrame("Button", nil, load)
	b:SetSize(100, 16)
	b:SetPoint("BOTTOMRIGHT", loadList.scroll, "TOPRIGHT", rightOffset, 0)
	b.label = Label(b, "", "GameFontNormalSmall", "RIGHT")
	b.label:SetAllPoints()
	b:SetScript("OnClick", function() loadState.sort = key; UI:Refresh() end)
	b:SetScript("OnEnter", function(self) self.label:SetAlpha(0.7) end)
	b:SetScript("OnLeave", function(self) self.label:SetAlpha(1) end)
	loadHeaders[key] = function()
		b.label:SetText("|cff" .. color .. text .. (loadState.sort == key and " v" or "") .. "|r")
	end
	return b
end
SortHeader("total", "Total", "ffffff", -214)
SortHeader("cpu", "Lua CPU", "ff8c1a", -108)
SortHeader("wall", "Wall (load)", "3399ff", -2)

local function RefreshLoad()
	for _, update in pairs(loadHeaders) do update() end
	local loads = OMP.db.loads or {}
	local e = loads[loadState.index or #loads]
	local cur = loadState.index or #loads
	if cur > 1 then olderBtn:Enable() else olderBtn:Disable() end
	if cur < #loads then newerBtn:Enable() else newerBtn:Disable() end
	if not e then
		loadHeader:SetText("No loading data yet. Type /reload or zone to record a loading screen.")
		loadNote:SetText("")
		loadList.data = {}
		loadList:Update()
		return
	end
	loadState.index = loadState.index or #loads
	local rows = OMP.LoadProfile:Rows(e, loadState.sort)
	loadMax = 1
	for _, r in ipairs(rows) do loadMax = max(loadMax, r.wall + r.cpu) end
	loadList.data = rows
	loadList:Update()
	loadHeader:SetText(string.format("%d/%d  %s%s  |  %s  |  wall |cffffffff%s|r  |  Lua CPU |cffffffff%s|r",
		loadState.index, #loads, e.kind == "login" and "Login / reload" or "Zone load",
		e.zone and (" - " .. e.zone) or "", e.stamp, fmtMs(e.wall), fmtMs(e.luaMs)))
	if e.kind == "login" then
		loadNote:SetText("")
	else
		loadNote:SetText("Lua CPU spent by each addon between leaving and entering the world.")
	end
end

OMP:On("LOAD_PROFILE", function()
	loadState.index = nil
	if currentTab == "Load" and main:IsShown() then RefreshLoad() end
end)

----------------------------------------------------------------------
-- Lags tab
----------------------------------------------------------------------
local lags = panels.Lags
local lagState = { selected = nil, list = {} }
local lagInfo = Label(lags, "", "GameFontHighlightSmall")
lagInfo:SetPoint("TOPLEFT", 0, 0)
lagInfo:SetWidth(736)
local lagList = CreateList(lags, 0, -22, 736, 11, 18, function(row)
	row.time = Label(row, "", "GameFontHighlightSmall")
	row.time:SetPoint("LEFT", 4, 0)
	row.dur = Label(row, "", "GameFontHighlightSmall", "RIGHT")
	row.dur:SetPoint("LEFT", 90, 0)   -- after a "12-31 23:59:59" stamp
	row.dur:SetWidth(60)
	row.cause = Label(row, "", "GameFontHighlightSmall")
	row.cause:SetPoint("LEFT", 160, 0)
	row.cause:SetWidth(550)
	row:SetHighlightTexture(WHITE)
	row:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.12)
	row.sel = row:CreateTexture(nil, "BACKGROUND")
	row.sel:SetAllPoints()
	row.sel:SetTexture(0.2, 0.4, 0.8, 0.3)
	row:SetScript("OnClick", function(self)
		lagState.selected = self.data
		UI:Refresh()
	end)
end, function(row, e)
	row.time:SetText(e.stamp)
	row.dur:SetText(string.format("%.0f ms", e.dur))
	row.cause:SetText(e.text or "")
	if lagState.selected == e then row.sel:Show() else row.sel:Hide() end
end)
local lagDetail = Label(lags, "", "GameFontHighlightSmall")
lagDetail:SetPoint("TOPLEFT", lagList.scroll, "BOTTOMLEFT", 4, -10)
lagDetail:SetWidth(720)
lagDetail:SetHeight(110)
lagDetail:SetJustifyV("TOP")
local showBtn = Button(lags, "Show on graph", 110, 22, function()
	local e = lagState.selected
	if not e or e.session ~= OMP.sessionId then return end
	local now = GetTime()
	local age = now - e.t
	local minutes = math.ceil((age * 1.2 + 30) / 60)
	if minutes > Series.MAX_MINUTES then
		view.zoom, view.anchor = 0, nil
	else
		view.zoom = minutes
		view.anchor = min(now, e.t + minutes * 30)
	end
	SelectTab("Live")
end)
showBtn:SetPoint("BOTTOMLEFT", 0, 0)
local clearLags = Button(lags, "Clear log", 90, 22, function() OMP.LagDetector:Clear() end)
clearLags:SetPoint("LEFT", showBtn, "RIGHT", 4, 0)
local lagHelp = Label(lags, "", "GameFontNormalSmall")
lagHelp:SetPoint("LEFT", clearLags, "RIGHT", 10, 0)

local function RefreshLags()
	local log = OMP.db.lags or {}
	local data = {}
	for i = #log, 1, -1 do data[#data + 1] = log[i] end
	lagList.data = data
	lagList:Update()
	lagInfo:SetText(string.format("%d recorded lag spikes (frame > %d ms). Newest first.", #log, OMP.db.lagThreshold))
	local e = lagState.selected
	if e then
		local lines = { string.format("|cffffffff%s|r  frame time %.0f ms  (%s)", e.stamp, e.dur, e.zone or "?") }
		lines[#lines + 1] = "Cause: " .. (e.text or "")
		if e.kind ~= "unknown" then
			lines[#lines + 1] = string.format("Addon Lua time in that frame: %.0f ms of %.0f ms (%.0f%%)", e.luaMs, e.dur, e.luaMs / e.dur * 100)
		end
		for _, c in ipairs(e.culprits or {}) do
			lines[#lines + 1] = string.format("   %s: %.1f ms", c.name, c.ms)
		end
		lines[#lines + 1] = string.format("FPS %.0f   latency %d ms   %s   memory freed %.1f MB",
			e.fps or 0, e.latency or 0, e.combat and "in combat" or "out of combat", (e.memDropKB or 0) / 1024)
		lagDetail:SetText(table.concat(lines, "\n"))
	else
		lagDetail:SetText("Select a lag spike to see what caused it.")
	end
	if e and e.session == OMP.sessionId then showBtn:Enable() else showBtn:Disable() end
end

OMP:On("LAG", function(entry)
	if not entry then lagState.selected = nil end   -- log cleared
	if currentTab == "Lags" and main:IsShown() then RefreshLags() end
end)

----------------------------------------------------------------------
-- Memory tab
----------------------------------------------------------------------
local mem = panels.Memory
local memState = { last = {}, lastT = 0 }
local memTotal = Label(mem, "", "GameFontHighlight")
memTotal:SetPoint("TOPLEFT", 0, -2)
local gcBtn = Button(mem, "Collect garbage", 120, 22, function()
	collectgarbage("collect")
	memState.lastT = 0
	UI:Refresh()
end)
gcBtn:SetPoint("TOPRIGHT", 0, 0)
local memList = CreateList(mem, 0, -50, 736, 18, 18, function(row)
	row.bar = row:CreateTexture(nil, "BACKGROUND")
	row.bar:SetPoint("LEFT")
	row.bar:SetHeight(14)
	row.name = Label(row, "", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 4, 0)
	row.kb = Label(row, "", "GameFontHighlightSmall", "RIGHT")
	row.kb:SetPoint("RIGHT", -110, 0)
	row.d = Label(row, "", "GameFontHighlightSmall", "RIGHT")
	row.d:SetPoint("RIGHT", -4, 0)
end, function(row, d)
	local r, g, b = OMP:ColorFor(d.name)
	row.bar:SetTexture(r, g, b, 0.45)
	row.bar:SetWidth(max(1, d.kb / memState.max * 600))
	row.name:SetText(d.name)
	row.kb:SetText(d.kb >= 1024 and string.format("%.2f MB", d.kb / 1024) or string.format("%.0f KB", d.kb))
	local c = d.delta > 0 and "|cffff8040+" or "|cff80ff80"
	row.d:SetText(string.format("%s%.1f KB/s|r", c, d.delta))
end)
Label(mem, "Memory", "GameFontNormalSmall", "RIGHT"):SetPoint("BOTTOMRIGHT", memList.scroll, "TOPRIGHT", -108, 2)
Label(mem, "Change", "GameFontNormalSmall", "RIGHT"):SetPoint("BOTTOMRIGHT", memList.scroll, "TOPRIGHT", -2, 2)

local function RefreshMemory()
	local now = GetTime()
	if now - memState.lastT < 2 and memState.rows then return end
	UpdateAddOnMemoryUsage()
	local dt = max(now - memState.lastT, 0.001)
	local rows, total, mx = {}, 0, 1
	for i = 1, OMP.numAddons do
		if IsAddOnLoaded(i) then
			local n = OMP.addons[i]
			local kb = GetAddOnMemoryUsage(i)
			local prev = memState.last[n]
			rows[#rows + 1] = { name = n, kb = kb, delta = (prev and memState.lastT > 0) and (kb - prev) / dt or 0 }
			memState.last[n] = kb
			total = total + kb
			mx = max(mx, kb)
		end
	end
	memState.lastT, memState.max, memState.rows = now, mx, rows
	table.sort(rows, function(a, b) return a.kb > b.kb end)
	memList.data = rows
	memList:Update()
	memTotal:SetText(string.format("Addon memory total: |cffffffff%.1f MB|r    Lua heap: |cffffffff%.1f MB|r", total / 1024, collectgarbage("count") / 1024))
end

----------------------------------------------------------------------
-- Options tab
----------------------------------------------------------------------
local opt = panels.Options
local optY = 0
local optRefresh = {}

local function Stepper(text, get, set, step, lo, hi, fmt)
	local lbl = Label(opt, text, "GameFontHighlight")
	lbl:SetPoint("TOPLEFT", 0, optY)
	local minus = Button(opt, "-", 24, 22, function() set(max(lo, get() - step)); UI:Refresh() end)
	minus:SetPoint("TOPLEFT", 260, optY + 4)
	local val = Label(opt, "", "GameFontHighlight", "CENTER")
	val:SetPoint("LEFT", minus, "RIGHT", 0, 0)
	val:SetWidth(60)
	local plus = Button(opt, "+", 24, 22, function() set(min(hi, get() + step)); UI:Refresh() end)
	plus:SetPoint("LEFT", val, "RIGHT", 0, 0)
	optRefresh[#optRefresh + 1] = function() val:SetText(string.format(fmt, get())) end
	optY = optY - 30
end

local function Check(text, get, set)
	local cb = CreateFrame("CheckButton", nil, opt, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", -4, optY + 6)
	local lbl = Label(opt, text, "GameFontHighlight")
	lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false); UI:Refresh() end)
	optRefresh[#optRefresh + 1] = function() cb:SetChecked(get()) end
	optY = optY - 30
end

Stepper("Lag threshold (frame time, ms)", function() return OMP.db.lagThreshold end, function(v) OMP.db.lagThreshold = v end, 25, 25, 2000, "%d")
Stepper("Graph sample interval (s)", function() return OMP.db.sampleInterval end, function(v) OMP.db.sampleInterval = v end, 0.25, 0.25, 2, "%.2f")
Check("Print a chat message on every lag spike", function() return OMP.db.lagAlert end, function(v) OMP.db.lagAlert = v end)
Check("Show minimap button", function() return OMP.db.showMinimap end, function(v) OMP.db.showMinimap = v; OMP:UpdateMinimapButton() end)
Check("List OmegaProfiler itself among the addons", function() return OMP.db.includeSelf end, function(v) OMP.db.includeSelf = v end)

Check("Save graph data", function() return OMP.db.saveLive end, function(v) OMP.db.saveLive = v end)
Stepper("Max saved graph data (KB)", function() return OMP.db.saveMaxKB end, function(v) OMP.db.saveMaxKB = v end, 64, 64, 2048, "%d")

local profState = Label(opt, "", "GameFontHighlight")
profState:SetPoint("TOPLEFT", 0, optY)
local profBtn = Button(opt, "", 220, 22, function()
	SetCVar("scriptProfile", "0")
	ReloadUI()
end)
profBtn:SetPoint("TOPLEFT", 260, optY + 4)
optY = optY - 40
local actions = {
	{ "Reset graph data", function() OMP:ResetData(); UI:Refresh() end },
	{ "Clear lag log", function() OMP.LagDetector:Clear() end },
	{ "Export report", function() OMP:ShowReport() end },
	{ "Hot frames", function() OMP:ShowHotFrames() end },
}
for i, a in ipairs(actions) do
	local b = Button(opt, a[1], 140, 24, a[2])
	b:SetPoint("TOPLEFT", (i - 1) * 146, optY)
end
optY = optY - 40

local function RefreshOptions()
	for _, f in ipairs(optRefresh) do f() end
	-- when off, the bar under the tabs offers to enable it
	profState:SetText("Script profiling: |cff40ff40ON|r")
	profBtn:SetText("Disable profiling + reload")
	if OMP.profiling then profState:Show(); profBtn:Show() else profState:Hide(); profBtn:Hide() end
end

----------------------------------------------------------------------
-- Dispatch
----------------------------------------------------------------------
function UI:Refresh(sampleOnly)
	if not main:IsShown() or not OMP.db then return end
	if currentTab == "Live" then RefreshLive(sampleOnly)
	elseif currentTab == "Load" then RefreshLoad()
	elseif currentTab == "Lags" then RefreshLags()
	elseif currentTab == "Memory" then RefreshMemory()
	elseif currentTab == "Options" then RefreshOptions() end
end

function OMP:ShowUI(tab)
	UpdateProfilingBar()
	main:Show()
	SelectTab(tab or currentTab or "Live")
end

function OMP:ToggleUI()
	if main:IsShown() then main:Hide() else OMP:ShowUI() end
end

OMP:On("DB_READY", function()
	local legacy = { ["5m"] = 5, ["30m"] = 30, ["1hr"] = 60, ["6hrs"] = 360, ["All time"] = 0 }
	if type(OMP.db.zoom) ~= "number" then OMP.db.zoom = legacy[OMP.db.zoom] or 5 end
	view.zoom = OMP.db.zoom
	if OMP.db.showTotal ~= nil then   -- old "Total" button -> "Other" row
		if OMP.db.showTotal then OMP.db.selected.__total = true end
		OMP.db.showTotal = nil
	end
	currentTab = "Live"
end)

-- Reload UI button sets a flag so the Load tab reopens with the fresh measurement.
OMP:On("PLAYER_LOGIN", function()
	if OMP.db.reopenLoad then
		OMP.db.reopenLoad = nil
		OMP:ShowUI("Load")
	end
end)

OMP:On("SAMPLE", function(rates)
	local db = OMP.db
	-- First run: preselect the five heaviest addons so the graph is not empty.
	if not db.firstRunDone and OMP.profiling and OMP.store.tiers[1].cur
		and GetTime() - OMP.store.startTime > 8 then
		local list = {}
		for k, v in pairs(rates) do
			if k:sub(1, 2) ~= "__" and k ~= ADDON then list[#list + 1] = { k, v } end
		end
		table.sort(list, function(a, b) return a[2] > b[2] end)
		for i = 1, min(5, #list) do db.selected[list[i][1]] = true end
		db.firstRunDone = true
	end
	if main:IsShown() and currentTab == "Live" then UI:Refresh(true) end
end)

OMP:On("RESET", function() UI:Refresh() end)

main:SetScript("OnShow", function() UI:Refresh() end)
main:SetScript("OnUpdate", function(self, elapsed)
	-- Memory tab refreshes itself every couple of seconds while visible.
	if currentTab == "Memory" then
		self.t = (self.t or 0) + elapsed
		if self.t > 2 then self.t = 0; RefreshMemory() end
	end
end)
