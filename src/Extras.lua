-- Minimap button, text report/export window and the hot-frames scan.
local ADDON, OMP = ...
local floor, min, max = math.floor, math.min, math.max

----------------------------------------------------------------------
-- Copyable text window
----------------------------------------------------------------------
local textWin
local function ShowText(titleText, body)
	if not textWin then
		local f = CreateFrame("Frame", "OmegaProfilerTextFrame", UIParent)
		f:SetSize(560, 420)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
		tinsert(UISpecialFrames, "OmegaProfilerTextFrame")
		f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		f.title:SetPoint("TOPLEFT", 20, -16)
		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -6, -6)
		local sf = CreateFrame("ScrollFrame", "OmegaProfilerTextScroll", f, "UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 20, -40)
		sf:SetPoint("BOTTOMRIGHT", -38, 18)
		local eb = CreateFrame("EditBox", nil, sf)
		eb:SetMultiLine(true)
		eb:SetFontObject(ChatFontNormal)
		eb:SetWidth(500)
		eb:SetAutoFocus(false)
		eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		sf:SetScrollChild(eb)
		f.edit = eb
		textWin = f
	end
	textWin.title:SetText(titleText)
	textWin.edit:SetText(body)
	textWin:Show()
end

----------------------------------------------------------------------
-- Report
----------------------------------------------------------------------
function OMP:TopConsumers(seconds, count)
	local store = self.store
	local now = GetTime()
	local t0 = max(store.startTime, now - seconds)
	local list = {}
	for _, key in ipairs(store:Keys()) do
		if key:sub(1, 2) ~= "__" then
			local avg = store:Average(key, t0, now)
			if avg > 0 then list[#list + 1] = { name = key, avg = avg } end
		end
	end
	table.sort(list, function(a, b) return a.avg > b.avg end)
	while #list > count do list[#list] = nil end
	return list
end

function OMP:ShowReport()
	local out = { string.format("OmegaProfiler report  %s", date("%Y-%m-%d %H:%M:%S")) }
	out[#out + 1] = string.format("Session length %s, scriptProfile %s", OMP.FormatAgo(GetTime() - self.store.startTime), self.profiling and "on" or "off")
	if self.profiling then
		out[#out + 1] = "\nTop addons by average CPU over the last 5 minutes (ms/s):"
		for i, c in ipairs(self:TopConsumers(300, 20)) do
			out[#out + 1] = string.format("%2d. %-32s %8.2f", i, c.name, c.avg)
		end
	end
	local e = self.db.loads and self.db.loads[#self.db.loads]
	if e then
		out[#out + 1] = string.format("\nLatest load (%s, %s): wall %.0f ms, Lua CPU %.0f ms", e.kind, e.stamp, e.wall, e.luaMs)
		local rows = self.LoadProfile:Rows(e, "cpu")
		for i = 1, min(15, #rows) do
			out[#out + 1] = string.format("%2d. %-32s cpu %8.1f ms  wall %8.1f ms", i, rows[i].name, rows[i].cpu, rows[i].wall)
		end
	end
	local lags = self.db.lags or {}
	if #lags > 0 then
		out[#out + 1] = string.format("\nLast lag spikes (%d total):", #lags)
		for i = #lags, max(1, #lags - 14), -1 do
			out[#out + 1] = string.format("%s  %5.0f ms  %s", lags[i].stamp, lags[i].dur, lags[i].text or "")
		end
	end
	ShowText("OmegaProfiler report (Ctrl+A, Ctrl+C to copy)", table.concat(out, "\n"))
end

----------------------------------------------------------------------
-- Hot frames: top script handlers by cumulative time, any addon
----------------------------------------------------------------------
function OMP:ShowHotFrames()
	if not self.profiling then
		ShowText("Hot frames", "Script profiling is off. Use /omp enable (reloads the UI).")
		return
	end
	UpdateAddOnCPUUsage()
	local list = {}
	local f = EnumerateFrames()
	while f do
		local ok, time, count = pcall(GetFrameCPUUsage, f, false)
		if ok and time and time > 0 then
			local name = f:GetName()
			if not name then
				local p = f:GetParent()
				local pn = p and p:GetName()
				name = pn and (pn .. ".<anonymous " .. (f:GetObjectType()) .. ">") or ("<anonymous " .. f:GetObjectType() .. ">")
			end
			list[#list + 1] = { name = name, time = time, count = count or 0 }
		end
		f = EnumerateFrames(f)
	end
	table.sort(list, function(a, b) return a.time > b.time end)
	local out = { "Top frames by cumulative script time (event + update handlers):", "" }
	for i = 1, min(40, #list) do
		local e = list[i]
		out[#out + 1] = string.format("%9.1f ms  %9d calls  %s", e.time, e.count, e.name)
	end
	ShowText("Hot frames", table.concat(out, "\n"))
end

----------------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------------
local btn = CreateFrame("Button", "OmegaProfilerMinimapButton", Minimap)
btn:SetSize(31, 31)
btn:SetFrameStrata("MEDIUM")
btn:SetFrameLevel(8)
btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
btn:RegisterForDrag("LeftButton")
local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\media\\icon")
icon:SetSize(20, 20)
icon:SetPoint("CENTER", 0, 1)
icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
-- the standard round tracking border hides the icon's square corners, like other addons' buttons
local border = btn:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetSize(52, 52)
border:SetPoint("TOPLEFT")
btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local function Place()
	local a = math.rad(OMP.db.minimapAngle or 215)
	btn:ClearAllPoints()
	btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
end

function OMP:UpdateMinimapButton()
	if self.db.showMinimap then btn:Show(); Place() else btn:Hide() end
end

btn:SetScript("OnDragStart", function(self)
	self:SetScript("OnUpdate", function()
		local mx, my = Minimap:GetCenter()
		local scale = Minimap:GetEffectiveScale()
		local cx, cy = GetCursorPosition()
		OMP.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
		Place()
	end)
end)
btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
btn:SetScript("OnClick", function(_, button)
	if button == "RightButton" then OMP:ShowUI("Lags") else OMP:ToggleUI() end
end)
btn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("OmegaProfiler")
	if OMP.profiling then
		for _, c in ipairs(OMP:TopConsumers(30, 10)) do
			GameTooltip:AddDoubleLine(c.name, string.format("%.2f ms/s", c.avg), 1, 1, 1, 1, 0.82, 0)
		end
	else
		GameTooltip:AddLine("Script profiling off (/omp enable)", 1, 0.4, 0.4)
	end
	local lags = OMP.db.lags
	if lags and #lags > 0 then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(string.format("Last lag: %.0f ms - %s", lags[#lags].dur, lags[#lags].text or ""), 1, 0.4, 0.4, true)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Left click: open   Right click: lags   Drag: move", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
btn:Hide()

OMP:On("DB_READY", function() OMP:UpdateMinimapButton() end)
