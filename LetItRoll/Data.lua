-- Data: what is being rolled on right now, and the saved history.
--
-- Three sources, merged per item:
--   * your own roll IDs (START_LOOT_ROLL / CANCEL_LOOT_ROLL): what you can
--     still click Need/Greed/Pass on;
--   * C_LootHistory: Blizzard's per-drop record of every player's pick, roll
--     number and the winner. Main source, never hidden by secret values;
--   * chat lines (Chat.lua): only for drops C_LootHistory doesn't list.
-- Every entry carries a `drop` table shaped like EncounterLootDropInfo, so
-- Blizzard's LootHistoryElementMixin can display it unchanged.
local _, LIR = ...

local State = Enum.EncounterLootDropRollState
local Plain = LIR.Plain

LIR.Data = {}
local Data = LIR.Data

local rolls = {}      -- rollID -> { rollID, duration, link, itemID }
local myPicks = {}    -- rollID -> state, set the moment you click
local chatDrops = {}  -- itemID -> drop built from chat lines
local seenInHistory = {} -- itemID -> GetTime() when C_LootHistory last listed it

local CHAT_DROP_TIMEOUT = 300  -- seconds before an unresolved chat drop is dropped
local HISTORY_OVERLAP = 120    -- seconds a C_LootHistory item shadows chat lines

local ROLL_TYPE_STATE = {
	[0] = State.Pass,
	[1] = State.NeedMainSpec,
	[2] = State.Greed,
	[4] = State.Transmog,
}

-- Only real item links: a bare number would be read as an item ID.
local function ItemID(link)
	return link and link:find("|Hitem:") and C_Item.GetItemInfoInstant(link)
end

local function IsResolved(drop)
	return drop.winner ~= nil or drop.allPassed
end

-- ---------------------------------------------------------------- change notification
local refreshQueued = false
function Data:Changed()
	if refreshQueued then
		return
	end
	refreshQueued = true
	C_Timer.After(0, function()
		refreshQueued = false
		Data:Sync()
		if LIR.OnDataChanged then
			LIR:OnDataChanged()
		end
	end)
end

-- ---------------------------------------------------------------- history (saved)
local function CopyDrop(drop)
	local copy = CopyTable(drop)
	copy.time = time()
	return copy
end

local function Archive(key, drop, encounterName)
	if LIR.db.archived[key] then
		return
	end
	LIR.db.archived[key] = true
	local record = CopyDrop(drop)
	record.key = key
	record.encounterName = encounterName
	table.insert(LIR.db.history, 1, record)
end

function Data:GetHistory()
	if LIR.Preview:IsActive() then
		return LIR.Preview:GetHistory()
	end
	return LIR.db.history
end

function Data:ClearHistory()
	if LIR.Preview:IsActive() then
		wipe(LIR.Preview:GetHistory())
		self:Changed()
		return
	end
	wipe(LIR.db.history)
	wipe(LIR.db.archived)
	self:Changed()
end

-- ---------------------------------------------------------------- C_LootHistory
local function HistoryKey(encounterID, drop)
	return ("h:%d:%d:%s"):format(encounterID, drop.lootListKey, tostring(drop.startTime))
end

-- A drop past its roll time but without a result is finished all the same.
local function HasExpired(drop)
	if not (drop.startTime and drop.duration and drop.duration > 0) then
		return false
	end
	return C_LootHistory.GetLootHistoryTime() > drop.startTime + drop.duration + 5
end

-- C_LootHistory also lists drops below the loot threshold (common items),
-- which nobody rolls on: they never get a winner. A drop counts once its
-- quality reaches the threshold, or anyone picks on it. Quality is unknown
-- until the item is cached; such drops are kept.
local function IsRolledOn(drop)
	local quality = C_Item.GetItemQualityByID(drop.itemHyperlink)
	if not quality or quality >= GetLootThreshold() then
		return true
	end
	for _, info in ipairs(drop.rollInfos) do
		if info.state ~= State.NoRoll then
			return true
		end
	end
	return false
end

-- Pending drops (for the Rolling tab); resolved ones are archived on the way.
local function ScanLootHistory()
	local pending = {}
	if not C_LootHistory then
		return pending
	end
	local now = GetTime()
	for _, encounter in ipairs(C_LootHistory.GetAllEncounterInfos() or {}) do
		local drops = C_LootHistory.GetSortedDropsForEncounter(encounter.encounterID) or {}
		for _, drop in ipairs(drops) do
			local itemID = ItemID(drop.itemHyperlink)
			if itemID then
				seenInHistory[itemID] = now
			end
			local key = HistoryKey(encounter.encounterID, drop)
			if IsResolved(drop) or HasExpired(drop) then
				Archive(key, drop, encounter.encounterName)
			elseif IsRolledOn(drop) then
				table.insert(pending, {
					key = key,
					drop = drop,
					itemID = itemID,
					encounterID = encounter.encounterID,
					lootListKey = drop.lootListKey,
				})
			end
		end
	end
	return pending
end

-- Saves finished drops whether or not the window is open.
function Data:Sync()
	ScanLootHistory()
end

-- ---------------------------------------------------------------- chat fallback
local function GroupRoster()
	local roster = {}
	local function Add(unit)
		local name = Plain(UnitName(unit))
		if name then
			local _, class = UnitClass(unit)
			roster[name] = { playerName = name, playerClass = Plain(class) or "PRIEST", isSelf = UnitIsUnit(unit, "player") }
		end
	end
	Add("player")
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			Add("raid" .. i)
		end
	else
		for i = 1, GetNumSubgroupMembers() do
			Add("party" .. i)
		end
	end
	return roster
end

local function ShortName(name)
	return name and (name:match("^([^%-]+)") or name)
end

-- Chat drops keep players by name; roster members without a line are
-- added as NoRoll, the state Blizzard uses for "waiting on".
local function ChatDropAsDrop(chat)
	local infos = {}
	local roster = GroupRoster()
	for name, info in pairs(chat.players) do
		local member = roster[ShortName(name)] or roster[name]
		table.insert(infos, {
			playerName = name,
			playerClass = member and member.playerClass or info.playerClass or "PRIEST",
			isSelf = member and member.isSelf or false,
			state = info.state,
			roll = info.roll,
			isWinner = chat.winnerName == name,
		})
		if member then
			roster[member.playerName] = nil
		end
	end
	for _, member in pairs(roster) do
		table.insert(infos, { playerName = member.playerName, playerClass = member.playerClass, isSelf = member.isSelf, state = State.NoRoll })
	end
	table.sort(infos, function(a, b)
		if a.state ~= b.state then
			return a.state < b.state
		end
		if (a.roll or 0) ~= (b.roll or 0) then
			return (a.roll or 0) > (b.roll or 0)
		end
		return a.playerName < b.playerName
	end)

	local drop = {
		itemHyperlink = chat.link,
		playerRollState = State.NoRoll,
		allPassed = chat.allPassed or false,
		isTied = false,
		rollInfos = infos,
	}
	for _, info in ipairs(infos) do
		if info.isSelf then
			drop.playerRollState = info.state
		end
		if info.isWinner then
			drop.winner = info
		end
		if info.roll and (not drop.currentLeader or info.roll > drop.currentLeader.roll) and info.state == infos[1].state then
			drop.currentLeader = info
		end
	end
	return drop
end

local function ShadowedByHistory(itemID)
	local seen = seenInHistory[itemID]
	return seen and GetTime() - seen < HISTORY_OVERLAP
end

LIR.Chat:Listen(function(kind, player, link, state, roll)
	local itemID = ItemID(link)
	if not itemID or ShadowedByHistory(itemID) then
		return
	end
	local chat = chatDrops[itemID]
	if not chat then
		chat = { link = link, itemID = itemID, players = {}, started = GetTime(), key = ("c:%d:%d"):format(itemID, time()) }
		chatDrops[itemID] = chat
	end
	if kind == "pick" or kind == "roll" then
		local info = chat.players[player] or {}
		info.state = state
		info.roll = roll or info.roll
		chat.players[player] = info
	elseif kind == "won" or kind == "allPassed" then
		chat.winnerName = player
		chat.allPassed = kind == "allPassed"
		chatDrops[itemID] = nil
		Archive(chat.key, ChatDropAsDrop(chat))
	end
	Data:Changed()
end)

-- ---------------------------------------------------------------- your rolls
LIR:On("START_LOOT_ROLL", function(rollID, rollTime)
	local link = GetLootRollItemLink(rollID)
	rolls[rollID] = { rollID = rollID, duration = rollTime, link = link, itemID = ItemID(link) }
	Data:Changed()
	if LIR.db.autoOpen then
		LIR:ShowWindow(1)
	end
end)

LIR:On("CANCEL_LOOT_ROLL", function(rollID)
	rolls[rollID] = nil
	Data:Changed()
end)

LIR:On("CANCEL_ALL_LOOT_ROLLS", function()
	wipe(rolls)
	Data:Changed()
end)

hooksecurefunc("RollOnLoot", function(rollID, rollType)
	myPicks[rollID] = ROLL_TYPE_STATE[rollType]
	Data:Changed()
end)

for _, event in ipairs({ "LOOT_HISTORY_UPDATE_DROP", "LOOT_HISTORY_UPDATE_ENCOUNTER", "LOOT_HISTORY_CLEAR_HISTORY", "GROUP_ROSTER_UPDATE" }) do
	LIR:On(event, function()
		Data:Changed()
	end)
end

-- Picks up rolls already open when the UI loads (after a /reload mid-roll).
function LIR:OnLoaded()
	for _, rollID in ipairs(GetActiveLootRollIDs and GetActiveLootRollIDs() or {}) do
		local link = GetLootRollItemLink(rollID)
		rolls[rollID] = { rollID = rollID, duration = C_Loot.GetLootRollDuration(rollID), link = link, itemID = ItemID(link) }
	end
end

-- ---------------------------------------------------------------- the Rolling list
-- Entries: { key, drop, rollID?, encounterID?, lootListKey? }, oldest first.
function Data:GetActive()
	if LIR.Preview:IsActive() then
		return LIR.Preview:GetActive()
	end
	local entries = ScanLootHistory()

	local now = GetTime()
	for itemID, chat in pairs(chatDrops) do
		if now - chat.started > CHAT_DROP_TIMEOUT or ShadowedByHistory(itemID) then
			chatDrops[itemID] = nil
		else
			table.insert(entries, { key = chat.key, drop = ChatDropAsDrop(chat), itemID = itemID })
		end
	end

	-- Each of your roll IDs joins the first entry for the same item that has none.
	local rollIDs = {}
	for rollID in pairs(rolls) do
		table.insert(rollIDs, rollID)
	end
	table.sort(rollIDs)
	for _, rollID in ipairs(rollIDs) do
		local roll = rolls[rollID]
		local joined = false
		for _, entry in ipairs(entries) do
			if not entry.rollID and entry.itemID and entry.itemID == roll.itemID then
				entry.rollID = rollID
				joined = true
				break
			end
		end
		if not joined and roll.link then
			table.insert(entries, {
				key = "r:" .. rollID,
				rollID = rollID,
				itemID = roll.itemID,
				drop = { itemHyperlink = roll.link, playerRollState = State.NoRoll, rollInfos = {}, allPassed = false, isTied = false },
			})
		end
	end

	-- Your click shows at once, before the server confirms it.
	for _, entry in ipairs(entries) do
		local pick = entry.rollID and myPicks[entry.rollID]
		if pick and entry.drop.playerRollState == State.NoRoll then
			entry.drop.playerRollState = pick
		end
		if entry.rollID then
			local roll = rolls[entry.rollID]
			entry.duration = roll.duration
		end
	end
	return entries
end

-- 0..1 of the roll time left, or nil when unknown.
function Data:GetTimeLeft(entry)
	if entry.timeLeft then
		return entry.timeLeft
	end
	if entry.rollID and rolls[entry.rollID] and entry.duration and entry.duration > 0 then
		return Clamp(GetLootRollTimeLeft(entry.rollID) / entry.duration, 0, 1)
	end
	local drop = entry.drop
	if drop.startTime and drop.duration and drop.duration > 0 then
		local elapsed = C_LootHistory.GetLootHistoryTime() - drop.startTime
		return Clamp(1 - elapsed / drop.duration, 0, 1)
	end
	return nil
end

-- Need/Greed/Pass from the window: the preview keeps clicks to itself.
function LIR:Roll(entry, rollType)
	if entry.preview then
		LIR.Preview:Pick(entry, rollType)
	elseif entry.rollID then
		RollOnLoot(entry.rollID, rollType)
	end
end

-- ---------------------------------------------------------------- /lir debug
function LIR:DebugDump()
	self:Print("C_LootHistory:", C_LootHistory and "yes" or "MISSING")
	local encounters = C_LootHistory and C_LootHistory.GetAllEncounterInfos() or {}
	self:Print(("%d encounter(s) in loot history"):format(#encounters))
	for _, encounter in ipairs(encounters) do
		local drops = C_LootHistory.GetSortedDropsForEncounter(encounter.encounterID) or {}
		print(("  %s (id %d): %d drop(s)"):format(tostring(encounter.encounterName), encounter.encounterID, #drops))
		for _, drop in ipairs(drops) do
			print(("    %s  winner=%s  allPassed=%s  players=%d"):format(drop.itemHyperlink,
				drop.winner and drop.winner.playerName or "-", tostring(drop.allPassed), #drop.rollInfos))
		end
	end
	local open = 0
	for _ in pairs(rolls) do open = open + 1 end
	local chats = 0
	for _ in pairs(chatDrops) do chats = chats + 1 end
	self:Print(("open roll IDs: %d, chat-tracked drops: %d, hidden chat lines: %d, saved history: %d")
		:format(open, chats, LIR.Chat.secretLines, #LIR.db.history))
	self:Print("default popups replaced:", tostring(LIR.db.replacePopups), " loot threshold:", GetLootThreshold())
end
