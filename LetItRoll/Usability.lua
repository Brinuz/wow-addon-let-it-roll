-- Usability: can a player of a given class use an item at all? Used to flag
-- a Need roll on something that player can't equip.
--
-- Two checks, both with no guessing about specs or stats:
--   * the item's own "Classes: ..." line, read from its tooltip;
--   * armor and weapon proficiencies, by class (Classic rules). Level-gated
--     ones (Mail at 40 for Hunters and Shamans, Plate at 40 for Warriors and
--     Paladins) count as usable, so a low-level Need is never flagged wrongly.
-- A class missing from these tables is never flagged.
local _, LIR = ...

local Armor = Enum.ItemArmorSubclass
local Weapon = Enum.ItemWeaponSubclass

LIR.Usability = {}
local Usability = LIR.Usability

local ARMOR_RANK = {
	[Armor.Cloth] = 1,
	[Armor.Leather] = 2,
	[Armor.Mail] = 3,
	[Armor.Plate] = 4,
}

local CLASSES = {
	WARRIOR = {
		armor = Armor.Plate, shield = true,
		weapons = { "Axe1H", "Axe2H", "Bows", "Crossbow", "Dagger", "Guns", "Mace1H", "Mace2H", "Polearm", "Staff", "Sword1H", "Sword2H", "Thrown", "Unarmed" },
	},
	PALADIN = {
		armor = Armor.Plate, shield = true, relic = Armor.Libram,
		weapons = { "Axe1H", "Axe2H", "Mace1H", "Mace2H", "Polearm", "Sword1H", "Sword2H" },
	},
	HUNTER = {
		armor = Armor.Mail,
		weapons = { "Axe1H", "Axe2H", "Bows", "Crossbow", "Dagger", "Guns", "Polearm", "Staff", "Sword1H", "Sword2H", "Thrown", "Unarmed" },
	},
	ROGUE = {
		armor = Armor.Leather,
		weapons = { "Bows", "Crossbow", "Dagger", "Guns", "Mace1H", "Sword1H", "Thrown", "Unarmed" },
	},
	PRIEST = {
		armor = Armor.Cloth,
		weapons = { "Dagger", "Mace1H", "Staff", "Wand" },
	},
	SHAMAN = {
		armor = Armor.Mail, shield = true, relic = Armor.Totem,
		weapons = { "Axe1H", "Axe2H", "Dagger", "Mace1H", "Mace2H", "Staff", "Unarmed" },
	},
	MAGE = {
		armor = Armor.Cloth,
		weapons = { "Dagger", "Staff", "Sword1H", "Wand" },
	},
	WARLOCK = {
		armor = Armor.Cloth,
		weapons = { "Dagger", "Staff", "Sword1H", "Wand" },
	},
	DRUID = {
		armor = Armor.Leather, relic = Armor.Idol,
		weapons = { "Dagger", "Mace1H", "Mace2H", "Staff", "Unarmed" },
	},
}

-- Weapon names become a set of subclass IDs the client knows.
for _, class in pairs(CLASSES) do
	local set = {}
	for _, name in ipairs(class.weapons) do
		if Weapon[name] then
			set[Weapon[name]] = true
		end
	end
	class.weapons = set
end

local RELICS = { [Armor.Libram] = true, [Armor.Totem] = true, [Armor.Idol] = true }

-- Localized class name -> class file ("Guerrier" -> "WARRIOR"), both genders.
local classByName
local function ClassByName()
	if not classByName then
		classByName = {}
		for _, female in ipairs({ false, true }) do
			for file, name in pairs(LocalizedClassList(female) or {}) do
				classByName[name] = file
			end
		end
	end
	return classByName
end

local classesPattern
local function AllowedClasses(link)
	if not (C_TooltipInfo and ITEM_CLASSES_ALLOWED) then
		return nil
	end
	classesPattern = classesPattern or ("^" .. ITEM_CLASSES_ALLOWED:gsub("%%s", "(.+)") .. "$")
	local data = C_TooltipInfo.GetHyperlink(link)
	for _, line in ipairs(data and data.lines or {}) do
		local text = LIR.Plain(line.leftText)
		local list = text and text:match(classesPattern)
		if list then
			local allowed = {}
			for name in list:gmatch("[^,]+") do
				local file = ClassByName()[strtrim(name)]
				if file then
					allowed[file] = true
				end
			end
			return allowed
		end
	end
	return nil
end

local cache = {}

-- Returns false plus a reason when `classFile` can't use the item; true otherwise.
function Usability:CanUse(link, classFile)
	if not (link and classFile) then
		return true
	end
	local key = link .. "\0" .. classFile
	if cache[key] ~= nil then
		return cache[key], cache[key .. "reason"]
	end

	local usable, reason = true, nil
	local allowed = AllowedClasses(link)
	if allowed and not allowed[classFile] then
		usable, reason = false, ITEM_CLASSES_ALLOWED:format(LocalizedClassList()[classFile] or classFile)
	end

	local class = CLASSES[classFile]
	local _, _, subTypeName, _, _, itemClassID, subclassID = C_Item.GetItemInfoInstant(link)
	if usable and class and itemClassID == Enum.ItemClass.Armor then
		local rank = ARMOR_RANK[subclassID]
		if rank and rank > ARMOR_RANK[class.armor] then
			usable = false
		elseif subclassID == Armor.Shield and not class.shield then
			usable = false
		elseif RELICS[subclassID] and class.relic ~= subclassID then
			usable = false
		end
	elseif usable and class and itemClassID == Enum.ItemClass.Weapon then
		local known = false
		for _, classInfo in pairs(CLASSES) do
			known = known or classInfo.weapons[subclassID]
		end
		-- Only weapon types some class trains are judged (not fishing poles etc.).
		if known and not class.weapons[subclassID] then
			usable = false
		end
	end
	if not usable and not reason then
		reason = LIR.L.CANT_USE_TYPE:format(LocalizedClassList()[classFile] or classFile, subTypeName or "")
	end

	-- Until the item is cached its tooltip may be incomplete; ask again later.
	if C_Item.GetItemInfo(link) then
		cache[key] = usable
		cache[key .. "reason"] = reason
	end
	return usable, reason
end

-- Only Need is flagged: Greed on an unusable item is normal (to sell it).
function Usability:IsBadNeed(link, info)
	local State = Enum.EncounterLootDropRollState
	if info.state ~= State.NeedMainSpec and info.state ~= State.NeedOffSpec then
		return false
	end
	local usable, reason = self:CanUse(link, info.playerClass)
	return not usable, reason
end
