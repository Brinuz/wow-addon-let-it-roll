-- UI: the window (UI.xml) and its two lists. Mixins are globals because
-- UI.xml names them; this file loads before it.
local _, LIR = ...

local L = LIR.L
local State = Enum.EncounterLootDropRollState

local TAB_ROLLING, TAB_HISTORY = 1, 2
local CARD_HEIGHT = 58
local TIMER_GAP, TIMER_HEIGHT = 2, 13
local PLAYERS_GAP = 6
local LINE_HEIGHT = 16
local ROW_PADDING = 8
local TIMER_FILL_WIDTH = 292

-- The metal frame art is drawn at this size: thinner edges, corners and
-- title bar than Blizzard's own windows, the window itself unchanged.
local BORDER_SCALE = 0.85
-- DefaultPanelFlatTemplate's background insets and title offset, at full size.
local BG_LEFT, BG_TOP, BG_RIGHT, BG_BOTTOM, TITLE_TEXT_Y = 6, -20, -2, 2, -5

local BUTTON_TOOLTIPS = {
	[0] = PASS,
	[1] = NEED,
	[2] = GREED,
	[4] = TRANSMOGRIFICATION,
}

local ROLL_ICONS = {
	[State.NeedMainSpec] = "lootroll-icon-need",
	[State.NeedOffSpec] = "lootroll-icon-need",
	[State.Transmog] = "lootroll-icon-transmog",
	[State.Greed] = "lootroll-icon-greed",
	[State.Pass] = "lootroll-icon-pass",
}

local function ClassColoredName(info)
	local color = RAID_CLASS_COLORS[info.playerClass]
	return color and color:WrapTextInColorCode(info.playerName) or info.playerName
end

local function IsResolved(drop)
	return drop.winner ~= nil or drop.allPassed
end

-- "Waiting on: A, B, C" in Blizzard's words, or nil when nobody is left.
local function WaitingOnText(drop)
	if IsResolved(drop) then
		return nil
	end
	local names = {}
	for _, info in ipairs(drop.rollInfos) do
		if info.state == State.NoRoll then
			table.insert(names, ClassColoredName(info))
		end
	end
	if #names == 0 then
		return nil
	end
	return LOOT_HISTORY_WAITING_ON .. table.concat(names, LOOT_HISTORY_PLAYER_DELIMITER)
end

local function PickedInfos(drop)
	local picked = {}
	for _, info in ipairs(drop.rollInfos) do
		if info.state < State.NoRoll or info.state == State.Pass then
			table.insert(picked, info)
		end
	end
	return picked
end

-- Measures wrapped text so a row's height is known before it is built.
-- Kept shown but invisible: a hidden font string may not be laid out, and
-- then reports one line however long the text.
local measure = UIParent:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
measure:SetAlpha(0)
measure:SetPoint("TOPLEFT", UIParent, "BOTTOMRIGHT")
measure:SetWidth(284)
measure:SetWordWrap(true)

local function ActiveRowHeight(entry)
	local height = CARD_HEIGHT + TIMER_GAP + TIMER_HEIGHT + PLAYERS_GAP
	height = height + #PickedInfos(entry.drop) * LINE_HEIGHT
	local waiting = WaitingOnText(entry.drop)
	if waiting then
		measure:SetText(waiting)
		height = height + 4 + measure:GetStringHeight()
	end
	return height + ROW_PADDING
end

-- ---------------------------------------------------------------- Rolling row
LetItRollActiveRowMixin = {}

function LetItRollActiveRowMixin:OnLoad()
	self.linePool = CreateFramePool("FRAME", self.Players, "LootHistoryRollTooltipLineTemplate")
	for _, button in ipairs(self.LootButtonContainer.LootButtons) do
		button.tooltipText = BUTTON_TOOLTIPS[button:GetID()]
		button:SetScript("OnClick", function()
			if self.entry then
				LIR:Roll(self.entry, button:GetID())
			end
		end)
	end
end

function LetItRollActiveRowMixin:Init(entry)
	self.entry = entry
	local drop = entry.drop

	-- Blizzard's card refreshes itself on LOOT_HISTORY_UPDATE_DROP when it
	-- knows which drop it shows.
	self.Card.encounterID = entry.encounterID
	self.Card.lootListKey = entry.lootListKey
	self.Card:Init(drop)
	self.Card.Item:SetScript("OnEnter", function(item)
		GameTooltip:SetOwner(item, "ANCHOR_RIGHT")
		if entry.rollID and not entry.preview then
			GameTooltip:SetLootRollItem(entry.rollID)
		else
			GameTooltip:SetHyperlink(drop.itemHyperlink)
		end
	end)

	self:SetupButtons()
	self:UpdateTimer()

	self.linePool:ReleaseAll()
	local picked = PickedInfos(drop)
	local anyRollNumbers = false
	for _, info in ipairs(picked) do
		anyRollNumbers = anyRollNumbers or info.roll ~= nil
	end
	local previous
	for _, info in ipairs(picked) do
		local line = self.linePool:Acquire()
		line:Init(info, anyRollNumbers)
		self:SetLineWarning(line, LIR.Usability:IsBadNeed(drop.itemHyperlink, info))
		line:ClearAllPoints()
		if previous then
			line:SetPoint("TOPLEFT", previous, "TOPLEFT", 0, -LINE_HEIGHT)
		else
			line:SetPoint("TOPLEFT")
		end
		line:Show()
		previous = line
	end

	local waiting = WaitingOnText(drop)
	self.WaitingText:ClearAllPoints()
	self.WaitingText:SetPoint("TOPLEFT", self.Players, "TOPLEFT", 0, -(#picked * LINE_HEIGHT) - 4)
	self.WaitingText:SetText(waiting)
	self.WaitingText:SetShown(waiting ~= nil)
end

-- Blizzard's line plus a warning icon when this Need is on an item the
-- player can't use; hovering it says why.
function LetItRollActiveRowMixin:SetLineWarning(line, bad, reason)
	local warning = line.LetItRollWarning
	if not warning then
		warning = line:CreateTexture(nil, "OVERLAY")
		warning:SetAtlas("transmog-icon-warning-small", true)
		line.LetItRollWarning = warning
	end
	warning:ClearAllPoints()
	local after = line.Check:IsShown() and line.Check or line.PlayerName
	warning:SetPoint("LEFT", after, "RIGHT", 3, 0)
	warning:SetShown(bad)
	line:EnableMouse(bad)
	line:SetScript("OnEnter", bad and function()
		GameTooltip:SetOwner(warning, "ANCHOR_RIGHT")
		GameTooltip_SetTitle(GameTooltip, L.CANT_USE)
		if reason then
			GameTooltip_AddErrorLine(GameTooltip, reason)
		end
		GameTooltip:Show()
	end or nil)
	line:SetScript("OnLeave", bad and GameTooltip_Hide or nil)
end

-- Need/Greed/Pass show only while you still have a choice to make.
function LetItRollActiveRowMixin:SetupButtons()
	local entry = self.entry
	local container = self.LootButtonContainer
	local undecided = entry.drop.playerRollState == State.NoRoll and not IsResolved(entry.drop)
	local canRoll = undecided and (entry.preview or entry.rollID)
	container:SetShown(canRoll and true or false)
	if not canRoll then
		return
	end

	local canNeed, canGreed, reasonNeed, reasonGreed, canTransmog
	if entry.preview then
		canNeed, canGreed, canTransmog = entry.canNeed, entry.canGreed, false
	else
		local _
		_, _, _, _, _, canNeed, canGreed, _, reasonNeed, reasonGreed, _, _, canTransmog = GetLootRollItemInfo(entry.rollID)
	end

	local function Apply(button, enabled, reason)
		if enabled then
			GroupLootFrame_EnableLootButton(button)
			button.reason = nil
		else
			GroupLootFrame_DisableLootButton(button)
			button.reason = reason and _G["LOOT_ROLL_INELIGIBLE_REASON" .. reason]
		end
	end
	Apply(container.NeedButton, canNeed, reasonNeed)
	Apply(container.PassButton, true)
	container.TransmogButton:SetShown(canTransmog and true or false)
	container.GreedButton:SetShown(not canTransmog)
	if not canTransmog then
		Apply(container.GreedButton, canGreed, reasonGreed)
	end
end

function LetItRollActiveRowMixin:UpdateTimer()
	local left = self.entry and LIR.Data:GetTimeLeft(self.entry)
	if not left or IsResolved(self.entry.drop) then
		self.Timer.Fill:Hide()
		return
	end
	self.Timer.Fill:Show()
	self.Timer.Fill:SetWidth(math.max(1, TIMER_FILL_WIDTH * left))
end

function LetItRollActiveRowMixin:OnUpdate()
	self:UpdateTimer()
end

-- ---------------------------------------------------------------- History row
LetItRollHistoryRowMixin = {}

-- Blizzard's card shows the winner's name; the roll type and number go after it.
function LetItRollHistoryRowMixin:InitRecord(record)
	self.encounterID = nil
	self.lootListKey = nil
	self:Init(record)

	local winner = record.winner
	if winner then
		local text = ClassColoredName(winner)
		local icon = ROLL_ICONS[winner.state]
		if icon then
			text = text .. "  " .. CreateAtlasMarkup(icon, 14, 14)
		end
		if winner.roll then
			text = text .. " " .. HIGHLIGHT_FONT_COLOR:WrapTextInColorCode(winner.roll)
		end
		if LIR.Usability:IsBadNeed(record.itemHyperlink, winner) then
			text = text .. " " .. CreateAtlasMarkup("transmog-icon-warning-small")
		end
		self.WinningRollInfo.WinningRoll:SetText(text)
	end

	if record.time then
		local today = date("*t")
		local when = date("*t", record.time)
		if today.year == when.year and today.yday == when.yday then
			self.When:SetText(date("%H:%M", record.time))
		else
			self.When:SetText(FormatShortDate(when.day, when.month))
		end
	else
		self.When:SetText(nil)
	end
end

-- ---------------------------------------------------------------- the window
LetItRollFrameMixin = {}

StaticPopupDialogs.LETITROLL_CLEAR_HISTORY = {
	text = L.CLEAR_CONFIRM,
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		LIR.Data:ClearHistory()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- The nine-slice fills the window whatever its scale; its pieces shrink.
-- The background, title and close button follow the thinner art.
function LetItRollFrameMixin:ThinBorders()
	self.NineSlice:SetScale(BORDER_SCALE)
	self.Bg:ClearAllPoints()
	self.Bg:SetPoint("TOPLEFT", BG_LEFT * BORDER_SCALE, BG_TOP * BORDER_SCALE)
	self.Bg:SetPoint("BOTTOMRIGHT", BG_RIGHT * BORDER_SCALE, BG_BOTTOM * BORDER_SCALE)
	self.TitleContainer.TitleText:SetPoint("TOP", 0, TITLE_TEXT_Y * BORDER_SCALE)
	-- Its anchor offsets scale with it, so it stays on the corner.
	self.ClosePanelButton:SetScale(BORDER_SCALE)
end

function LetItRollFrameMixin:OnLoad()
	self.TitleContainer.TitleText:SetText(LIR.TITLE)
	self:ThinBorders()
	table.insert(UISpecialFrames, self:GetName())

	self.Tab1:SetText(L.ROLLING)
	self.Tab2:SetText(L.HISTORY)
	for _, tab in ipairs(self.Tabs) do
		tab:SetScript("OnClick", function()
			PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
			self:SetTab(tab:GetID())
		end)
	end
	PanelTemplates_SetNumTabs(self, #self.Tabs)

	self.ClearButton:SetText(L.CLEAR)
	self.ClearButton:SetScript("OnClick", function()
		StaticPopup_Show("LETITROLL_CLEAR_HISTORY")
	end)

	self.ResizeButton:SetScript("OnMouseDown", function()
		self:StartSizing("BOTTOM", true)
	end)
	self.ResizeButton:SetScript("OnMouseUp", function()
		self:StopMovingOrSizing()
	end)

	local view = CreateScrollBoxListLinearView(0, 0, 0, 0, 6)
	view:SetElementFactory(function(factory, elementData)
		if elementData.entry then
			factory("LetItRollActiveRowTemplate", function(row, data)
				row:Init(data.entry)
			end)
		else
			factory("LetItRollHistoryRowTemplate", function(row, data)
				row:InitRecord(data.record)
			end)
		end
	end)
	view:SetElementExtentCalculator(function(_, elementData)
		if elementData.entry then
			return ActiveRowHeight(elementData.entry)
		end
		return CARD_HEIGHT
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(self.ScrollBox, self.ScrollBar, view)

	-- Like Blizzard's lists, the scroll bar shows only when the list overflows.
	local anchorsWithBar = {
		CreateAnchor("TOPLEFT", self, "TOPLEFT", 8, -30),
		CreateAnchor("BOTTOMRIGHT", self, "BOTTOMRIGHT", -22, 18),
	}
	local anchorsWithoutBar = {
		anchorsWithBar[1],
		CreateAnchor("BOTTOMRIGHT", self, "BOTTOMRIGHT", -8, 18),
	}
	ScrollUtil.AddManagedScrollBarVisibilityBehavior(self.ScrollBox, self.ScrollBar, anchorsWithBar, anchorsWithoutBar)

	self:SetTab(TAB_ROLLING)
end

function LetItRollFrameMixin:OnShow()
	PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
	self:Refresh()
end

function LetItRollFrameMixin:OnHide()
	PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
	if LIR.Preview:IsActive() then
		LIR.Preview:Stop()
	end
end

function LetItRollFrameMixin:OnDragStart()
	self:StartMoving()
end

function LetItRollFrameMixin:OnDragStop()
	self:StopMovingOrSizing()
end

function LetItRollFrameMixin:SetTab(id)
	self.selectedTabID = id
	PanelTemplates_SetTab(self, id)
	self.ClearButton:SetShown(id == TAB_HISTORY)
	self:Refresh()
end

function LetItRollFrameMixin:Refresh()
	if not self:IsShown() then
		return
	end
	local title = LIR.TITLE
	if LIR.Preview:IsActive() then
		title = title .. " - " .. L.PREVIEW
	end
	self.TitleContainer.TitleText:SetText(title)

	local dataProvider = CreateDataProvider()
	if self.selectedTabID == TAB_ROLLING then
		for _, entry in ipairs(LIR.Data:GetActive()) do
			dataProvider:Insert({ entry = entry })
		end
		self.EmptyText:SetText(L.NO_ROLLS)
	else
		for _, record in ipairs(LIR.Data:GetHistory()) do
			dataProvider:Insert({ record = record })
		end
		self.EmptyText:SetText(L.NO_HISTORY)
	end
	self.EmptyText:SetShown(dataProvider:GetSize() == 0)
	self.ScrollBox:SetDataProvider(dataProvider, ScrollBoxConstants.RetainScrollPosition)
end

-- ---------------------------------------------------------------- entry points
function LIR:OnDataChanged()
	LetItRollFrame:Refresh()
end

function LIR:ShowWindow(tab)
	if tab then
		LetItRollFrame:SetTab(tab)
	end
	LetItRollFrame:Show()
end

function LIR:ToggleWindow()
	LetItRollFrame:SetShown(not LetItRollFrame:IsShown())
end
