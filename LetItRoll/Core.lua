-- Core: the shared table, saved settings, event routing, the default roll
-- popups switch, the slash command and the AddOns menu entry.
local addonName, LIR = ...

LIR.TITLE = "Let It Roll"
LIR.SLASH = "/lir"

-- Words Blizzard already translates come from its globals; the rest is ours.
LIR.L = {
	ROLLING = "Rolling",
	HISTORY = HISTORY or "History",
	CLEAR = CLEAR_ALL or "Clear All",
	NO_ROLLS = "Nothing is being rolled on.\nItems show up here when a group roll starts.",
	NO_HISTORY = "No rolls yet.",
	CLEAR_CONFIRM = "Clear the whole roll history?",
	PREVIEW = "Preview",
	CANT_USE = "Can't use this item",
	CANT_USE_TYPE = "%s can't use %s",
	PREVIEW_STARTED = "Preview started: sample rolls with a made-up group. Nothing is sent or saved. Type /lir preview again to stop.",
	PREVIEW_STOPPED = "Preview stopped.",
	REPLACE_POPUPS = "Replace the default roll popups",
	REPLACE_POPUPS_TOOLTIP = "Roll in the Let It Roll window instead of Blizzard's Need/Greed popups.",
	AUTO_OPEN = "Open when a roll starts",
	AUTO_OPEN_TOOLTIP = "Show the window on the Rolling tab whenever an item is put up for a roll.",
}

local DEFAULTS = {
	replacePopups = true,
	autoOpen = true,
	history = {},      -- newest first, entries shaped like EncounterLootDropInfo
	archived = {},     -- key -> true, so a drop is never stored twice
}

-- ---------------------------------------------------------------- events
-- Files subscribe with LIR:On(event, fn); one frame dispatches them all.
local handlers = {}
local eventFrame = CreateFrame("Frame")

function LIR:On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event]) do
		fn(...)
	end
end)

-- Values the game hides from addons (secret values) are treated as missing.
function LIR.Plain(v)
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

function LIR:Print(...)
	print(NORMAL_FONT_COLOR:WrapTextInColorCode(self.TITLE .. ":"), ...)
end

-- ---------------------------------------------------------------- default popups
-- Blizzard routes START_LOOT_ROLL through GameEvent to GroupLootContainer_AddRoll
-- (Blizzard_Game/Mainline/EventRouting.lua). Unregistering that one route stops
-- the popups without replacing any Blizzard function.
local function StartLootRollRoute(...)
	GameEvent.HandleStartLootRoll(...)
end

function LIR:ApplyReplacePopups()
	if not (GameEvent and GameEvent.UnregisterInternalEvent) then
		return
	end
	if self.db.replacePopups then
		GameEvent.UnregisterInternalEvent("START_LOOT_ROLL")
		if GroupLootContainer and GroupLootContainer_RemoveAllRolls then
			GroupLootContainer_RemoveAllRolls(GroupLootContainer)
		end
	else
		GameEvent.RegisterInternalEvent("START_LOOT_ROLL", StartLootRollRoute)
	end
end

-- ---------------------------------------------------------------- load
LIR:On("ADDON_LOADED", function(name)
	if name ~= addonName then
		return
	end
	LetItRollDB = LetItRollDB or {}
	for key, value in pairs(DEFAULTS) do
		if LetItRollDB[key] == nil then
			LetItRollDB[key] = type(value) == "table" and {} or value
		end
	end
	LIR.db = LetItRollDB
	LIR:ApplyReplacePopups()
	if LIR.OnLoaded then
		LIR:OnLoaded()
	end
end)

-- ---------------------------------------------------------------- entry points
function LetItRoll_OnAddonCompartmentClick()
	LIR:ToggleWindow()
end

SLASH_LETITROLL1 = LIR.SLASH
SlashCmdList.LETITROLL = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "debug" then
		LIR:DebugDump()
	elseif msg == "options" or msg == "config" then
		LIR:OpenSettings()
	elseif msg == "history" then
		LIR:ShowWindow(2)
	elseif msg == "preview" then
		LIR.Preview:Toggle()
	else
		LIR:ToggleWindow()
	end
end
