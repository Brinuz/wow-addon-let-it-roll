-- Minimap: a button on the minimap's rim that opens the History tab. Built by
-- hand from Blizzard's minimap art, laid out like every LibDBIcon button on
-- this client (31x31, ring 50, backing 24, icon 18), without the library.
local addonName, LIR = ...

local L = LIR.L

local TAB_HISTORY = 2
local ICON_ATLAS = "lootroll-toast-icon-need-up"
local BORDER_FILE = "Interface\\Minimap\\MiniMap-TrackingBorder"
local BACKGROUND_FILE = "Interface\\Minimap\\UI-Minimap-Background"
local HIGHLIGHT_FILE = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local RADIUS_PADDING = 5   -- the rim sits this far outside the minimap
local CORNER_INSET = 10    -- on a square minimap, corners pull in this much

local button

local function SavedAngle()
	local angle = LIR.db.minimapAngle
	if type(angle) ~= "number" or angle ~= angle or angle == math.huge or angle == -math.huge then
		return 225
	end
	return angle
end

-- Round by default; minimap skin addons report a square map through the
-- global GetMinimapShape, as LibDBIcon expects.
local function Place(angle)
	local radians = math.rad(angle)
	local x, y = math.cos(radians), math.sin(radians)
	local halfWidth = Minimap:GetWidth() / 2 + RADIUS_PADDING
	local halfHeight = Minimap:GetHeight() / 2 + RADIUS_PADDING
	if type(GetMinimapShape) == "function" and GetMinimapShape() == "SQUARE" then
		local reachX = math.sqrt(2 * halfWidth * halfWidth) - CORNER_INSET
		local reachY = math.sqrt(2 * halfHeight * halfHeight) - CORNER_INSET
		x = math.max(-halfWidth, math.min(x * reachX, halfWidth))
		y = math.max(-halfHeight, math.min(y * reachY, halfHeight))
	else
		x, y = x * halfWidth, y * halfHeight
	end
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- The cursor is in unscaled pixels; the minimap's centre is in its own scale.
local function FollowCursor(self)
	local centerX, centerY = Minimap:GetCenter()
	local scale = LIR.Plain(Minimap:GetEffectiveScale())
	local cursorX, cursorY = GetCursorPosition()
	centerX, centerY = LIR.Plain(centerX), LIR.Plain(centerY)
	if not (centerX and centerY and scale) then
		return
	end
	cursorX, cursorY = cursorX / scale, cursorY / scale
	self.dragAngle = math.deg(math.atan2(cursorY - centerY, cursorX - centerX)) % 360
	Place(self.dragAngle)
end

-- The icon nudges one pixel while pressed, like MiniMapButtonTemplate's.
local function Press(self)
	if not self.isDown then
		self.isDown = true
		self.Icon:AdjustPointsOffset(1, -1)
	end
end

local function Release(self)
	if self.isDown then
		self.isDown = false
		self.Icon:AdjustPointsOffset(-1, 1)
	end
end

local function OnClick(_, mouseButton)
	if mouseButton == "RightButton" then
		LIR:OpenSettings()
	elseif LetItRollFrame:IsShown() and LetItRollFrame.selectedTabID == TAB_HISTORY then
		LetItRollFrame:Hide()
	else
		LIR:ShowWindow(TAB_HISTORY)
	end
end

local function OnEnter(self)
	if self.dragging then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip_SetTitle(GameTooltip, LIR.TITLE)
	GameTooltip_AddNormalLine(GameTooltip, L.MINIMAP_LEFT_CLICK)
	GameTooltip_AddNormalLine(GameTooltip, L.MINIMAP_RIGHT_CLICK)
	GameTooltip_AddNormalLine(GameTooltip, L.MINIMAP_DRAG)
	GameTooltip:Show()
end

local function Build()
	button = CreateFrame("Button", "LetItRollMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFixedFrameStrata(true)
	button:SetFrameLevel(8)
	button:SetFixedFrameLevel(true)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture(HIGHLIGHT_FILE)

	button.Background = button:CreateTexture(nil, "BACKGROUND")
	button.Background:SetTexture(BACKGROUND_FILE)
	button.Background:SetSize(24, 24)
	button.Background:SetPoint("CENTER")

	button.Icon = button:CreateTexture(nil, "ARTWORK")
	button.Icon:SetAtlas(ICON_ATLAS)
	button.Icon:SetSize(18, 18)
	button.Icon:SetPoint("CENTER")

	button.Border = button:CreateTexture(nil, "OVERLAY")
	button.Border:SetTexture(BORDER_FILE)
	button.Border:SetSize(50, 50)
	button.Border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", OnClick)
	button:SetScript("OnMouseDown", Press)
	button:SetScript("OnMouseUp", Release)
	button:SetScript("OnHide", Release)
	button:SetScript("OnEnter", OnEnter)
	button:SetScript("OnLeave", GameTooltip_Hide)

	-- The angle is saved once, when the drag ends.
	button:SetScript("OnDragStart", function(self)
		self.dragging = true
		self.dragAngle = SavedAngle()
		self:LockHighlight()
		GameTooltip_Hide()
		self:SetScript("OnUpdate", FollowCursor)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		self:UnlockHighlight()
		self.dragging = false
		LIR.db.minimapAngle = self.dragAngle
		Place(self.dragAngle)
	end)

	Place(SavedAngle())
	-- Again at login, for a skin addon that defines GetMinimapShape after us.
	EventUtil.ContinueOnPlayerLogin(function()
		Place(SavedAngle())
	end)
end

function LIR:ApplyMinimapButton()
	button:SetShown(self.db.showMinimapButton)
end

-- LIR.db exists only after ADDON_LOADED, which Core handles first.
LIR:On("ADDON_LOADED", function(name)
	if name == addonName and not button then
		Build()
		LIR:ApplyMinimapButton()
	end
end)
