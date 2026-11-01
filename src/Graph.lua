-- Line graph built from pooled textures (3.3.5 has no Line widget).
local ADDON, OMP = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local COL_W = 3          -- pixels per data column
local PAD_L, PAD_B, PAD_T, PAD_R = 64, 18, 6, 6   -- left pad holds the scale buttons (UI.lua) and the y labels
local floor, max, min = math.floor, math.max, math.min
local sqrt = math.sqrt
local LINE_TEX = "Interface\\AddOns\\" .. ADDON .. "\\media\\line"   -- antialiased 128x128 diagonal
local LINE_W = 48        -- line texture-space width: the drawn line is about LINE_W / 32 UI units thick (see line.tga)
local DOT = 2.2          -- size of an isolated sample
local LINEFACTOR_2 = (128 / 126) / 2
local SIMPLIFY_TOL = 0.5 -- px a dropped sample may sit off the drawn line
local Series = OMP.Series

local function niceCeil(v)
	if v <= 0 then return 1 end
	local p = 10 ^ floor(math.log10(v))
	for _, m in ipairs({ 1, 2, 2.5, 5, 10 }) do
		if v <= m * p then return m * p end
	end
	return 10 * p
end

-- Next nice value above (dir > 0) or below (dir < 0) v, on the 1 / 2 / 2.5 / 5 x 10^n ladder.
function OMP.NiceStep(v, dir)
	local c = niceCeil(v)
	if dir > 0 then return c > v and c or niceCeil(c * 1.01) end
	local p = 10 ^ floor(math.log10(c))
	local below = c
	for _, m in ipairs({ 0.5, 1, 2, 2.5, 5 }) do
		if m * p < c then below = m * p end
	end
	return below
end

-- exact: keep the seconds (for axis labels less than a minute apart)
function OMP.FormatAgo(sec, exact)
	sec = max(0, floor(sec + 0.5))
	if sec < 90 then return sec .. "s" end
	if exact then
		local h, m, s = floor(sec / 3600), floor((sec % 3600) / 60), sec % 60
		return (h > 0 and (h .. "h") or "") .. m .. "m" .. s .. "s"
	end
	if sec < 5400 then return floor(sec / 60 + 0.5) .. "m" end
	local h = floor(sec / 3600)
	local m = floor((sec % 3600) / 60)
	return m == 0 and (h .. "h") or (h .. "h" .. m .. "m")
end

local function fmtAxis(v)
	if v >= 1e6 then return string.format("%gM", v / 1e6) end
	if v >= 1e3 then return string.format("%gk", v / 1e3) end
	return string.format("%g", v)
end

local Graph = {}
Graph.__index = Graph

function OMP.CreateGraph(parent)
	local self = setmetatable({}, Graph)
	local f = CreateFrame("Frame", nil, parent)
	f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
	f:SetBackdropColor(0.04, 0.04, 0.06, 0.9)
	f:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
	self.frame = f

	local plot = CreateFrame("Frame", nil, f)
	plot:SetPoint("TOPLEFT", PAD_L, -PAD_T)
	plot:SetPoint("BOTTOMRIGHT", -PAD_R, PAD_B)
	plot:EnableMouse(true)
	plot:EnableMouseWheel(true)
	self.plot = plot

	self.bars, self.used = {}, 0
	self.lines, self.lineUsed = {}, 0
	self.markers, self.markerUsed = {}, 0
	self.grid, self.yLabels, self.xLabels = {}, {}, {}
	for i = 0, 4 do
		local t = plot:CreateTexture(nil, "BACKGROUND")
		t:SetTexture(1, 1, 1, i == 0 and 0.35 or 0.1)
		t:SetHeight(1)
		self.grid[i] = t
		local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetJustifyH("RIGHT")
		fs:SetPoint("RIGHT", t, "LEFT", -4, 0)
		self.yLabels[i] = fs
	end
	for i = 0, 4 do
		local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOP", plot, "BOTTOMLEFT", 0, -3)
		self.xLabels[i] = fs
	end
	self.empty = plot:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	self.empty:SetPoint("CENTER")
	self.empty:SetText("")

	-- shown over an empty window when data exists before (-1) / after (1) it: self.onJump(dir, edge) on click,
	-- edge being the time where that data ends / starts
	self.jump, self.jumpEdge = {}, {}
	for _, dir in ipairs({ -1, 1 }) do
		local b = CreateFrame("Button", nil, plot, "UIPanelButtonTemplate")
		b:SetSize(24, 22)
		b:SetText(dir < 0 and "<" or ">")
		b:SetPoint(dir < 0 and "LEFT" or "RIGHT", dir * -4, 0)
		b:SetScript("OnClick", function()
			if self.onJump and self.jumpEdge[dir] then self.onJump(dir, self.jumpEdge[dir]) end
		end)
		b:SetScript("OnEnter", function()
			GameTooltip:SetOwner(b, "ANCHOR_TOP")
			GameTooltip:SetText(dir < 0 and "Go to older data" or "Go to newer data")
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:Hide()
		self.jump[dir] = b
	end

	self.cross = plot:CreateTexture(nil, "OVERLAY")
	self.cross:SetTexture(1, 1, 1, 0.35)
	self.cross:SetWidth(1)
	self.cross:Hide()

	plot:SetScript("OnLeave", function()
		self.cross:Hide()
		GameTooltip:Hide()
		self.hover = false
	end)
	plot:SetScript("OnEnter", function() self.hover = true end)
	plot:SetScript("OnUpdate", function()
		if self.dragFrom then self:UpdateDrag()
		elseif self.panX then self:UpdatePan()
		elseif self.hover then self:UpdateHover() end
	end)

	-- drag to select a period; self.onSelect(tA, tB) is called on release
	self.selection = plot:CreateTexture(nil, "OVERLAY")
	self.selection:SetTexture(0.3, 0.6, 1, 0.25)
	self.selection:Hide()
	-- right-drag pans: self.onPanStart() on press, then self.onPan(frac) with the drag distance as a fraction of
	-- the plot width (positive = dragged right)
	plot:SetScript("OnMouseDown", function(_, button)
		if button == "RightButton" and self.t0 and not self.dragFrom and self.onPan then
			self.panX, self.panLast = self:RawCursorX(), 0
			if self.onPanStart then self.onPanStart() end
			GameTooltip:Hide()
			self.cross:Hide()
			return
		end
		if button ~= "LeftButton" or not self.t0 or self.panX then return end
		self.dragFrom = self:CursorTime()
		self.dragPx = self:CursorX()
		GameTooltip:Hide()
		self.cross:Hide()
	end)
	plot:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" then self.panX = nil return end
		if button ~= "LeftButton" or not self.dragFrom then return end
		local a, b = self.dragFrom, self:CursorTime()
		local moved = math.abs(self:CursorX() - self.dragPx)
		self.dragFrom = nil
		self.selection:Hide()
		if moved >= 6 and self.onSelect then
			if a > b then a, b = b, a end
			self.onSelect(a, b)
		end
	end)
	-- self.onWheel(d, tCursor, frac): frac = cursor position across the plot (0 left .. 1 right)
	plot:SetScript("OnMouseWheel", function(_, d)
		if not self.onWheel then return end
		if self.t0 then
			self.onWheel(d, self:CursorTime(), self:CursorX() / plot:GetWidth())
		else
			self.onWheel(d)
		end
	end)
	return self
end

local function getBar(self)
	self.used = self.used + 1
	local t = self.bars[self.used]
	if not t then
		t = self.plot:CreateTexture(nil, "ARTWORK")
		t:SetSize(DOT, DOT)
		self.bars[self.used] = t
	end
	return t
end

-- Draws a slanted antialiased segment (rotation done via texcoords, as 3.3.5 has no Line/SetRotation).
local function drawSegment(self, sx, sy, ex, ey, r, g, b)
	self.lineUsed = self.lineUsed + 1
	local T = self.lines[self.lineUsed]
	if not T then
		T = self.plot:CreateTexture(nil, "ARTWORK")
		T:SetTexture(LINE_TEX)
		self.lines[self.lineUsed] = T
	end
	T:Show()
	-- widget calls are the expensive part: skip them when this pooled texture already shows the same segment
	if T.sx == sx and T.sy == sy and T.ex == ex and T.ey == ey then
		if T.r ~= r or T.g ~= g or T.b ~= b then T:SetVertexColor(r, g, b, 1); T.r, T.g, T.b = r, g, b end
		return
	end
	T.sx, T.sy, T.ex, T.ey = sx, sy, ex, ey
	if T.r ~= r or T.g ~= g or T.b ~= b then T:SetVertexColor(r, g, b, 1); T.r, T.g, T.b = r, g, b end
	local w = LINE_W
	-- lengthen both ends by half the thickness so joints between segments overlap instead of leaving notches
	local ddx, ddy = ex - sx, ey - sy
	local len = sqrt(ddx * ddx + ddy * ddy)
	local ext = LINE_W / 32 / 2 / len
	sx, sy, ex, ey = sx - ddx * ext, sy - ddy * ext, ex + ddx * ext, ey + ddy * ext
	local dx, dy = ex - sx, ey - sy
	local cx, cy = (sx + ex) / 2, (sy + ey) / 2
	if dx < 0 then dx, dy = -dx, -dy end
	local l = sqrt(dx * dx + dy * dy)
	local s, c = -dy / l, dx / l
	local sc = s * c
	local Bwid, Bhgt, BLx, BLy, TLx, TLy, TRx, TRy, BRx, BRy
	if dy >= 0 then
		Bwid = ((l * c) - (w * s)) * LINEFACTOR_2
		Bhgt = ((w * c) - (l * s)) * LINEFACTOR_2
		BLx, BLy, BRy = (w / l) * sc, s * s, (l / w) * sc
		BRx, TLx, TLy, TRx = 1 - BLy, BLy, 1 - BRy, 1 - BLx
		TRy = BRx
	else
		Bwid = ((l * c) + (w * s)) * LINEFACTOR_2
		Bhgt = ((w * c) + (l * s)) * LINEFACTOR_2
		BLx, BLy, BRx = s * s, -(l / w) * sc, 1 + (w / l) * sc
		BRy, TLx, TLy, TRy = BLx, 1 - BRx, 1 - BLx, 1 - BLy
		TRx = TLy
	end
	-- always the same two anchors, so SetPoint replaces them without a ClearAllPoints
	T:SetTexCoord(TLx, TLy, BLx, BLy, TRx, TRy, BRx, BRy)
	T:SetPoint("BOTTOMLEFT", self.plot, "BOTTOMLEFT", cx - Bwid, cy - Bhgt)
	T:SetPoint("TOPRIGHT", self.plot, "BOTTOMLEFT", cx + Bwid, cy + Bhgt)
end

local function getMarker(self)
	self.markerUsed = self.markerUsed + 1
	local t = self.markers[self.markerUsed]
	if not t then
		t = self.plot:CreateTexture(nil, "BORDER")
		t:SetTexture(1, 0.2, 0.2, 0.45)
		t:SetWidth(2)
		self.markers[self.markerUsed] = t
	end
	return t
end

-- series: array of { key=, label=, r=, g=, b= }; lags: array of lag entries (may be nil)
-- fixedMax: top of the vertical scale chosen by the user; nil or 0 fits the visible data
function Graph:Draw(store, t0, t1, series, lags, fixedMax)
	local w, h = self.plot:GetWidth(), self.plot:GetHeight()
	if w < 10 or h < 10 then return end
	local n
	-- axis labels use the requested window: the snapped one shifts by a column as time passes,
	-- which made labels near a rounding edge flip back and forth (-8m / -9m)
	local reqT0, reqT1 = t0, t1
	t0, t1, n = store:Grid(t0, t1, floor(w / COL_W))
	self.t0, self.t1, self.n, self.series = t0, t1, n, series
	self.lags = lags
	self.drawGen = (self.drawGen or 0) + 1   -- the hover tooltip is rebuilt only after a redraw or a column change

	local ymax, slotW = 0
	for _, s in ipairs(series) do
		s.vals, slotW = store:Query(s.key, t0, t1, n, true)
		for c = 1, n do
			local v = s.vals[c]
			if v and v > ymax then ymax = v end
		end
	end
	ymax = (fixedMax and fixedMax > 0) and fixedMax or niceCeil(ymax * 1.05)
	self.ymax = ymax

	for i = 0, 4 do
		local g = self.grid[i]
		g:ClearAllPoints()
		g:SetPoint("BOTTOMLEFT", self.plot, "BOTTOMLEFT", 0, (h - 1) * i / 4)
		g:SetPoint("BOTTOMRIGHT", self.plot, "BOTTOMRIGHT", 0, (h - 1) * i / 4)
		self.yLabels[i]:SetText(fmtAxis(ymax * i / 4))
	end
	local now = GetTime()
	for i = 0, 4 do
		local x = w * i / 4
		local fs = self.xLabels[i]
		fs:ClearAllPoints()
		fs:SetPoint("TOP", self.plot, "BOTTOMLEFT", x, -3)
		local ago = now - (reqT0 + (reqT1 - reqT0) * i / 4)
		fs:SetText(ago < 1 and "now" or ("-" .. OMP.FormatAgo(ago, (reqT1 - reqT0) < 240)))
	end

	self.used, self.lineUsed = 0, 0
	local colW = w / n
	local any, leftData, rightData = false, false, false
	-- samples are one slot wide, so neighbouring samples can be several columns apart when zoomed in:
	-- join them unless a whole slot is missing between them
	local maxGap = max(1, math.ceil((slotW or 0) / ((t1 - t0) / n) * 1.5))
	local function dot(x, y, s)
		local bar = getBar(self)
		bar:SetTexture(s.r, s.g, s.b, 1)
		bar:SetPoint("CENTER", self.plot, "BOTTOMLEFT", x, y)
		bar:Show()
	end
	local xs, ys, keep = {}, {}, {}
	local function flush(np, s)
		if np == 1 then dot(xs[1], ys[1], s); return end
		for k = #keep, 1, -1 do keep[k] = nil end
		Series.Simplify(xs, ys, 1, np, SIMPLIFY_TOL, keep)
		for k = 2, #keep do
			local a, b = keep[k - 1], keep[k]
			drawSegment(self, xs[a], ys[a], xs[b], ys[b], s.r, s.g, s.b)
		end
	end
	for _, s in ipairs(series) do
		local vals = s.vals
		-- split into runs of joinable samples, simplify each run, then draw it
		local np, prevC = 0, nil
		for c = 1, n do
			local v = vals[c]
			if v then
				any = true
				if c <= n / 2 then leftData = true else rightData = true end
				if prevC and c - prevC > maxGap then flush(np, s); np = 0 end
				np = np + 1
				xs[np], ys[np] = (c - 0.5) * colW, min(v / ymax, 1) * (h - 2) + 1
				prevC = c
			end
		end
		if np > 0 then flush(np, s) end
	end
	-- hide only what the previous draw showed: the pools keep every texture ever made
	for i = self.used + 1, self.barsShown or #self.bars do self.bars[i]:Hide() end
	for i = self.lineUsed + 1, self.linesShown or #self.lines do self.lines[i]:Hide() end
	self.barsShown, self.linesShown = self.used, self.lineUsed
	local elsewhere = false
	for dir, b in pairs(self.jump) do
		-- shown when that half of the window (left for "<", right for ">") holds no data
		local halfEmpty = dir < 0 and not leftData or dir > 0 and not rightData
		local edge = #series > 0 and halfEmpty and self.onJump and store:DataEdge(dir < 0 and reqT0 or reqT1, dir)
		self.jumpEdge[dir] = edge or nil
		if edge then b:Show(); elsewhere = true else b:Hide() end
	end
	self.empty:SetText(#series == 0 and "Select addons in the list"
		or (any and "" or (elsewhere and "No data in this period" or "No data yet")))

	-- lag markers
	self.markerUsed = 0
	self.markerInfo = {}
	if lags then
		-- newest first: the 40 shown are the latest ones in the window
		for k = #lags, 1, -1 do
			local e = lags[k]
			if self.markerUsed >= 40 or e.session ~= OMP.sessionId then break end
			if e.t >= t0 and e.t <= t1 then
				local m = getMarker(self)
				local x = (e.t - t0) / (t1 - t0) * w
				m:ClearAllPoints()
				m:SetPoint("BOTTOMLEFT", self.plot, "BOTTOMLEFT", x, 0)
				m:SetHeight(h)
				m:Show()
				self.markerInfo[self.markerUsed] = { x = x, e = e }
			end
		end
	end
	for i = self.markerUsed + 1, #self.markers do self.markers[i]:Hide() end
end

-- Cursor position relative to the plot's left edge in pixels.
function Graph:RawCursorX()
	local plot = self.plot
	return GetCursorPosition() / plot:GetEffectiveScale() - plot:GetLeft()
end

-- Cursor position inside the plot in pixels, clamped to its width.
function Graph:CursorX()
	return max(0, min(self.plot:GetWidth(), self:RawCursorX()))
end

function Graph:UpdatePan()
	-- the release can be missed (window hidden mid-drag)
	if not IsMouseButtonDown("RightButton") then self.panX = nil return end
	local dx = self:RawCursorX() - self.panX
	if math.abs(dx - self.panLast) < 1 then return end
	self.panLast = dx
	self.onPan(dx / self.plot:GetWidth())
end

function Graph:CursorTime()
	return self.t0 + (self.t1 - self.t0) * self:CursorX() / self.plot:GetWidth()
end

function Graph:UpdateDrag()
	local w = self.plot:GetWidth()
	local span = self.t1 - self.t0
	local xa = max(0, min(w, (self.dragFrom - self.t0) / span * w))
	local xb = self:CursorX()
	if xa > xb then xa, xb = xb, xa end
	local sel = self.selection
	sel:ClearAllPoints()
	sel:SetPoint("TOPLEFT", self.plot, "TOPLEFT", xa, 0)
	sel:SetPoint("BOTTOMRIGHT", self.plot, "BOTTOMLEFT", xb, 0)
	sel:Show()
end

function Graph:UpdateHover()
	local plot = self.plot
	if not self.series or not self.n then return end
	local cx = GetCursorPosition() / plot:GetEffectiveScale()
	local x = cx - plot:GetLeft()
	local w = plot:GetWidth()
	if x < 0 or x > w then return end
	local c = max(1, min(self.n, floor(x / w * self.n) + 1))
	self.cross:ClearAllPoints()
	self.cross:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, 0)
	self.cross:SetHeight(plot:GetHeight())
	self.cross:Show()

	-- this runs every frame while hovering: rebuild the tooltip only when its content can change
	local near = 0
	for k, m in ipairs(self.markerInfo or {}) do
		if math.abs(m.x - x) <= 4 then near = k; break end
	end
	if c == self.hoverC and near == self.hoverNear and self.drawGen == self.hoverGen
		and GameTooltip:IsShown() and GameTooltip:IsOwned(plot) then
		return
	end
	self.hoverC, self.hoverNear, self.hoverGen = c, near, self.drawGen

	local ts = self.t0 + (self.t1 - self.t0) * (c - 0.5) / self.n
	GameTooltip:SetOwner(plot, "ANCHOR_CURSOR")
	GameTooltip:AddLine(string.format("%s ago", OMP.FormatAgo(GetTime() - ts, self.t1 - self.t0 < 240)), 1, 1, 1)
	local rows, others = {}, {}
	for _, s in ipairs(self.series) do
		local v = s.vals[c]
		if v then
			local t = s.other and others or rows
			t[#t + 1] = { s, v }
		end
	end
	table.sort(rows, function(a, b) return a[2] > b[2] end)
	table.sort(others, function(a, b) return a[2] > b[2] end)
	for i = 1, min(#rows, 15) do
		local s, v = rows[i][1], rows[i][2]
		GameTooltip:AddDoubleLine(s.label, string.format("%.2f", v), s.r, s.g, s.b, 1, 1, 1)
	end
	local sepLine
	if #others > 0 then
		if #rows > 0 then
			GameTooltip:AddLine(" ")
			sepLine = GameTooltip:NumLines()
		end
		for _, r in ipairs(others) do
			local s, v = r[1], r[2]
			GameTooltip:AddDoubleLine(s.label, string.format("%.2f", v), s.r, s.g, s.b, 1, 1, 1)
		end
	end
	for _, m in ipairs(self.markerInfo or {}) do
		if math.abs(m.x - x) <= 4 then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(string.format("Lag %.0f ms: %s", m.e.dur, m.e.text or ""), 1, 0.4, 0.4, true)
		end
	end
	-- mouse controls, same grey "Action: result" style as the minimap button tooltip
	if self.hints then
		GameTooltip:AddLine(" ")
		for _, h in ipairs(self.hints) do GameTooltip:AddLine(h, 0.7, 0.7, 0.7) end
	end
	GameTooltip:Show()
	-- horizontal line between addon rows and non-addon rows
	GameTooltip.ompSep = GameTooltip.ompSep or GameTooltip:CreateTexture(nil, "OVERLAY")
	if not GameTooltip.ompHooked then GameTooltip.ompHooked = true; GameTooltip:HookScript("OnHide", function() GameTooltip.ompSep:Hide() end) end
	local sep = GameTooltip.ompSep
	sep:Hide()
	if sepLine then
		sep:ClearAllPoints()
		sep:SetTexture(0.7, 0.7, 0.7, 0.6)
		sep:SetHeight(1)
		sep:SetPoint("LEFT", GameTooltip, "LEFT", 10, 0)
		sep:SetPoint("RIGHT", GameTooltip, "RIGHT", -10, 0)
		sep:SetPoint("TOP", _G["GameTooltipTextLeft" .. sepLine], "TOP", 0, -4)
		sep:Show()
	end
end
