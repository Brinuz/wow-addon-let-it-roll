-- Chat: reads the loot roll lines in chat ("X has selected Need for: [item]",
-- "Need Roll - 87 for [item] by X", "X won: [item]"). Data.lua uses them only
-- for drops that C_LootHistory doesn't track. Patterns are built from
-- Blizzard's own format strings, so every client language works.
local _, LIR = ...

local State = Enum.EncounterLootDropRollState

LIR.Chat = {}
local listeners = {}

function LIR.Chat:Listen(fn)
	table.insert(listeners, fn)
end

local function Fire(kind, player, link, state, roll)
	for _, fn in ipairs(listeners) do
		fn(kind, player, link, state, roll)
	end
end

-- Forever's lines start with a link to the loot history entry, which takes
-- the first format argument: "|HlootHistory:%d|h[Loot]|h: %s won: %s".
-- It is cut from formats and lines alike, so the arguments keep their
-- classic order.
local PREFIX_FORMAT = "^|HlootHistory:%%d|h.-|h: ?"
local PREFIX_TEXT = "^|HlootHistory:%d+|h.-|h: ?"

-- Turns "%s has selected Need for: %s" (or "%2$s ... %1$s") into an anchored
-- Lua pattern, and records which capture holds which format argument.
local function MakePattern(format)
	if type(format) ~= "string" then
		return nil
	end
	local shift = 0
	if format:find(PREFIX_FORMAT) then
		format = format:gsub(PREFIX_FORMAT, "")
		shift = 1
	end
	local order, nextArg = {}, 1 + shift
	local parts, last = {}, 1
	for start, position, kind, finish in format:gmatch("()%%(%d?)%$?([sd])()") do
		table.insert(parts, (format:sub(last, start - 1):gsub("[%%%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")))
		table.insert(parts, kind == "d" and "(%d+)" or "(.+)")
		table.insert(order, (tonumber(position) or nextArg) - shift)
		nextArg = nextArg + 1
		last = finish
	end
	table.insert(parts, (format:sub(last):gsub("[%%%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")))
	return { pattern = "^" .. table.concat(parts) .. "$", order = order }
end

local function Match(p, text)
	if not p then
		return nil
	end
	local caps = { text:match(p.pattern) }
	if #caps == 0 then
		return nil
	end
	local args = {}
	for i, arg in ipairs(p.order) do
		args[arg] = caps[i]
	end
	return args
end

-- Checked in this order: the longer lines first, since "(.+) passed on: (.+)"
-- would also swallow "X automatically passed on: ...".
local rules
local function Rules()
	if rules then
		return rules
	end
	local me = UnitName("player")
	rules = {}
	local function Add(global, handler)
		local p = MakePattern(_G[global])
		if p then
			table.insert(rules, { p = p, handler = handler })
		end
	end
	local function Rolled(state)
		return function(a) Fire("roll", a[3], a[2], state, tonumber(a[1])) end
	end
	Add("LOOT_ROLL_ROLLED_NEED_ROLE_BONUS", Rolled(State.NeedMainSpec))
	Add("LOOT_ROLL_ROLLED_NEED", Rolled(State.NeedMainSpec))
	Add("LOOT_ROLL_ROLLED_GREED", Rolled(State.Greed))
	Add("LOOT_ROLL_PASSED_AUTO", function(a) Fire("pick", a[1], a[2], State.Pass) end)
	Add("LOOT_ROLL_PASSED_AUTO_FEMALE", function(a) Fire("pick", a[1], a[2], State.Pass) end)
	Add("LOOT_ROLL_PASSED_SELF_AUTO", function(a) Fire("pick", me, a[1], State.Pass) end)
	Add("LOOT_ROLL_NEED_SELF", function(a) Fire("pick", me, a[1], State.NeedMainSpec) end)
	Add("LOOT_ROLL_GREED_SELF", function(a) Fire("pick", me, a[1], State.Greed) end)
	Add("LOOT_ROLL_PASSED_SELF", function(a) Fire("pick", me, a[1], State.Pass) end)
	Add("LOOT_ROLL_NEED", function(a) Fire("pick", a[1], a[2], State.NeedMainSpec) end)
	Add("LOOT_ROLL_GREED", function(a) Fire("pick", a[1], a[2], State.Greed) end)
	Add("LOOT_ROLL_PASSED", function(a) Fire("pick", a[1], a[2], State.Pass) end)
	Add("LOOT_ROLL_YOU_WON", function(a) Fire("won", me, a[1]) end)
	Add("LOOT_ROLL_WON", function(a) Fire("won", a[1], a[2]) end)
	Add("LOOT_ROLL_ALL_PASSED", function(a) Fire("allPassed", nil, a[1]) end)
	return rules
end

LIR.Chat.secretLines = 0

LIR:On("CHAT_MSG_LOOT", function(text)
	text = LIR.Plain(text)
	if type(text) ~= "string" then
		-- Hidden during an encounter: counted so /lir debug can report it.
		LIR.Chat.secretLines = LIR.Chat.secretLines + 1
		return
	end
	text = text:gsub(PREFIX_TEXT, "")
	for _, rule in ipairs(Rules()) do
		local args = Match(rule.p, text)
		if args then
			rule.handler(args)
			return
		end
	end
end)
