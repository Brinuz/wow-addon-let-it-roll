-- Preview: /lir preview fills the window with sample drops and a made-up
-- group that picks, rolls and wins over about a minute. Your clicks only
-- change the preview: nothing is sent to the server or saved.
local _, LIR = ...

local State = Enum.EncounterLootDropRollState

LIR.Preview = {}
local Preview = LIR.Preview

-- Vanilla items Forever is known to have; any the client doesn't know are skipped.
local ITEM_IDS = { 6448, 7719, 13340, 2244 }
local DURATION = 40     -- seconds each sample roll lasts
local STAGGER = 4       -- seconds between sample drops
local LINGER = 4        -- seconds a finished drop stays on the Rolling tab

local GROUP = {
	{ playerName = "Aldric", playerClass = "WARRIOR" },
	{ playerName = "Mirelle", playerClass = "PRIEST" },
	{ playerName = "Tovan", playerClass = "ROGUE" },
	{ playerName = "Sylwen", playerClass = "MAGE" },
}

-- Per drop, each made-up player's pick and when (seconds after the drop).
local SCRIPTS = {
	{ { State.Greed, 3 }, { State.Greed, 6 }, { State.Pass, 2 }, { State.Greed, 9 } },
	{ { State.NeedMainSpec, 2 }, { State.Pass, 5 }, { State.Greed, 8 }, { State.NeedMainSpec, 12 } },
	{ { State.Greed, 4 }, { State.NeedMainSpec, 7 }, { State.Greed, 3 }, { State.Pass, 10 } },
	{ { State.Pass, 2 }, { State.Pass, 4 }, { State.Pass, 6 }, { State.Pass, 5 } },
}

local active = false
local startedAt
local drops = {}
local history = {}
local ticker

function Preview:IsActive()
	return active
end

local function ItemLink(itemID)
	local _, link = C_Item.GetItemInfo(itemID)
	return link
end

function Preview:Start()
	wipe(drops)
	wipe(history)
	startedAt = GetTime()
	local slot = 0
	for i, itemID in ipairs(ITEM_IDS) do
		if C_Item.DoesItemExistByID(itemID) then
			-- Caches the item, then refreshes so its name and icon show.
			Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
				LIR.Data:Changed()
			end)
			local rolls = {}
			for p = 1, #GROUP + 1 do
				rolls[p] = math.random(1, 100)
			end
			table.insert(drops, {
				key = "p:" .. i,
				itemID = itemID,
				script = SCRIPTS[i],
				startOffset = slot * STAGGER,
				rolls = rolls,
			})
			slot = slot + 1
		end
	end
	active = true
	ticker = C_Timer.NewTicker(0.5, function()
		LIR.Data:Changed()
	end)
	LIR:Print(LIR.L.PREVIEW_STARTED)
	LIR:ShowWindow(1)
	LIR.Data:Changed()
end

function Preview:Stop()
	active = false
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
	LIR.Data:Changed()
end

function Preview:Toggle()
	if active then
		self:Stop()
		LIR:Print(LIR.L.PREVIEW_STOPPED)
	else
		self:Start()
	end
end

-- Builds a drop table shaped like EncounterLootDropInfo for one sample.
local function BuildDrop(sample, elapsed)
	local me = UnitName("player")
	local _, myClass = UnitClass("player")
	local infos = {}
	local allPicked = true
	for p, member in ipairs(GROUP) do
		local pick, at = sample.script[p][1], sample.script[p][2]
		local state = elapsed >= at and pick or State.NoRoll
		allPicked = allPicked and state ~= State.NoRoll
		table.insert(infos, { playerName = member.playerName, playerClass = member.playerClass, isSelf = false, state = state, index = p })
	end
	local myState = sample.myPick or (elapsed >= DURATION and State.Pass) or State.NoRoll
	allPicked = allPicked and myState ~= State.NoRoll
	table.insert(infos, { playerName = me, playerClass = myClass, isSelf = true, state = myState, index = #GROUP + 1 })

	local drop = {
		itemHyperlink = ItemLink(sample.itemID),
		playerRollState = myState,
		allPassed = false,
		isTied = false,
		rollInfos = infos,
	}

	local finished = allPicked or elapsed >= DURATION
	if finished then
		-- Only the best tier rolls: Need beats Greed beats Pass.
		local tier = State.Pass
		for _, info in ipairs(infos) do
			if info.state < tier then
				tier = info.state
			end
		end
		if tier == State.Pass then
			drop.allPassed = true
		else
			for _, info in ipairs(infos) do
				if info.state == tier then
					info.roll = sample.rolls[info.index]
					if not drop.winner or info.roll > drop.winner.roll then
						drop.winner = info
					end
				end
			end
			drop.winner.isWinner = true
			drop.currentLeader = drop.winner
		end
		sample.finishedAt = sample.finishedAt or elapsed
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
	return drop, finished
end

function Preview:GetActive()
	local entries = {}
	local now = GetTime()
	for _, sample in ipairs(drops) do
		local elapsed = now - startedAt - sample.startOffset
		if elapsed >= 0 and not sample.archived then
			local drop, finished = BuildDrop(sample, elapsed)
			if drop.itemHyperlink then
				if finished and elapsed - sample.finishedAt > LINGER then
					sample.archived = true
					drop.time = time()
					drop.encounterName = LIR.L.PREVIEW
					table.insert(history, 1, drop)
				else
					table.insert(entries, {
						key = sample.key,
						preview = sample,
						itemID = sample.itemID,
						drop = drop,
						canNeed = true,
						canGreed = true,
						timeLeft = finished and 0 or Clamp(1 - elapsed / DURATION, 0, 1),
					})
				end
			end
		end
	end
	return entries
end

function Preview:GetHistory()
	return history
end

function Preview:Pick(entry, rollType)
	local states = { [0] = State.Pass, [1] = State.NeedMainSpec, [2] = State.Greed, [4] = State.Transmog }
	entry.preview.myPick = states[rollType]
	LIR.Data:Changed()
end
