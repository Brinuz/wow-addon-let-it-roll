-- Settings: the page under Options > AddOns, built with Blizzard's Settings API.
local _, LIR = ...

local L = LIR.L

local function Register()
	local category = Settings.RegisterVerticalLayoutCategory(LIR.TITLE)

	local replace = Settings.RegisterAddOnSetting(category, "LETITROLL_REPLACE_POPUPS", "replacePopups",
		LIR.db, Settings.VarType.Boolean, L.REPLACE_POPUPS, true)
	replace:SetValueChangedCallback(function()
		LIR:ApplyReplacePopups()
	end)
	Settings.CreateCheckbox(category, replace, L.REPLACE_POPUPS_TOOLTIP)

	local autoOpen = Settings.RegisterAddOnSetting(category, "LETITROLL_AUTO_OPEN", "autoOpen",
		LIR.db, Settings.VarType.Boolean, L.AUTO_OPEN, true)
	Settings.CreateCheckbox(category, autoOpen, L.AUTO_OPEN_TOOLTIP)

	Settings.RegisterAddOnCategory(category)
	LIR.settingsCategory = category
end

function LIR:OpenSettings()
	if self.settingsCategory then
		Settings.OpenToCategory(self.settingsCategory:GetID())
	end
end

-- LIR.db exists only after ADDON_LOADED, which Core handles first.
LIR:On("ADDON_LOADED", function(name)
	if name == "LetItRoll" and not LIR.settingsCategory then
		Register()
	end
end)
