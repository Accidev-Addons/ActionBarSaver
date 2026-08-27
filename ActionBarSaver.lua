ActionBarSaver = select(2, ...)

local ABS = ActionBarSaver
local L = ABS.locals

local restoreErrors, spellCache, macroCache, macroNameCache = {}, {}, {}, {}
local spellBookCache = {}
local iconCache, playerClass

local CONST = {
	MAX_MACROS = 54,
	MAX_CHAR_MACROS = 18,
	MAX_GLOBAL_MACROS = 36,
	MAX_ACTION_ID = 120,
	MAX_PET_SPELLS = 1024,
}

local GetSpellName = GetSpellName
local GetSpellInfo = GetSpellInfo
local GetItemInfo = GetItemInfo
local GetMacroInfo = GetMacroInfo
local GetActionInfo = GetActionInfo
local GetCursorInfo = GetCursorInfo
local GetNumMacros = GetNumMacros
local GetNumMacroIcons = GetNumMacroIcons
local GetMacroIconInfo = GetMacroIconInfo
local GetSpellTabInfo = GetSpellTabInfo
local GetCompanionInfo = GetCompanionInfo
local GetNumCompanions = GetNumCompanions
local GetNumEquipmentSets = GetNumEquipmentSets
local GetEquipmentSetInfo = GetEquipmentSetInfo
local ClearCursor = ClearCursor
local PickupAction = PickupAction
local PlaceAction = PlaceAction
local PickupSpell = PickupSpell
local PickupItem = PickupItem
local PickupMacro = PickupMacro
local PickupCompanion = PickupCompanion
local PickupEquipmentSet = PickupEquipmentSet
local CreateMacro = CreateMacro
local InCombatLockdown = InCombatLockdown
local GetCVar, SetCVar = GetCVar, SetCVar

local format = string.format
local lower = string.lower
local gsub = string.gsub
local trim = string.trim
local string_split = string.split
local table_wipe = table.wipe
local tinsert = table.insert
local tonumber, pairs, select, pcall = tonumber, pairs, select, pcall

local function IsValidSlot(actionID)
	actionID = tonumber(actionID)

	return actionID and actionID >= 1 and actionID <= CONST.MAX_ACTION_ID
end

local function GetMountSpellID(companionIndex, actionInfoExtraID)
	if actionInfoExtraID and actionInfoExtraID > 0 then
		return actionInfoExtraID
	end

	local _, _, spellID = GetCompanionInfo("MOUNT", companionIndex)

	return spellID
end

function ABS:PruneLegacySlots()
	local removed = 0

	for _, classSets in pairs(self.db.sets) do
		for _, set in pairs(classSets) do
			for actionID in pairs(set) do
				if not IsValidSlot(actionID) then
					set[actionID] = nil
					removed = removed + 1
				end
			end
		end
	end

	if removed > 0 then
		self:Debug(format("Pruned %d saved entries pointing at action slots that do not exist.", removed))
	end
end

function ABS:OnInitialize()
	local defaults = {
		macro = false,
		checkCount = false,
		restoreRank = true,
		autoSave = false,
		debug = false,
		spellSubs = {},
		sets = {},
	}

	ActionBarSaverDB = ActionBarSaverDB or {}

	for key, value in pairs(defaults) do
		if ActionBarSaverDB[key] == nil then
			ActionBarSaverDB[key] = value
		end
	end

	for classToken in pairs(RAID_CLASS_COLORS) do
		ActionBarSaverDB.sets[classToken] = ActionBarSaverDB.sets[classToken] or {}
	end

	self.db = ActionBarSaverDB

	playerClass = select(2, UnitClass("player"))

	self:PruneLegacySlots()
end

function ABS:CompressText(text)
	text = gsub(text, "\n", "/n")
	text = gsub(text, "/n$", "")
	text = gsub(text, "||", "/124")

	return trim(text)
end

function ABS:UncompressText(text)
	text = gsub(text, "/n", "\n")
	text = gsub(text, "/124", "|")

	return trim(text)
end

function ABS:SerializeAction(actionID)
	local kind, id, subType, extraID = GetActionInfo(actionID)
	if not kind or not id then
		return nil
	end

	if kind == "companion" then
		local spellID, name

		if subType == "MOUNT" then
			spellID = GetMountSpellID(id, extraID)
			name = spellID and GetSpellInfo(spellID)
		else
			local _, cName, cSpellID = GetCompanionInfo(subType, id)
			spellID = (extraID and extraID > 0) and extraID or cSpellID
			name = cName or (spellID and GetSpellInfo(spellID))
		end

		if not name or not spellID then
			self:Debug(format("FAILED saving companion slot %d: idx=%d type=%s", actionID, id, tostring(subType)))
			return nil
		end

		self:Debug(format("Saving companion slot %d: name=%s spellID=%d type=%s", actionID, name, spellID, tostring(subType)))

		return format("%s|%d|%s|%s|%s|%d", kind, spellID, "", name, subType, spellID)
	elseif kind == "equipmentset" then
		return format("%s|%s|%s", kind, id, "")
	elseif kind == "item" then
		return format("%s|%d|%s|%s", kind, id, "", (GetItemInfo(id)) or "")
	elseif kind == "spell" and id > 0 then
		local spell, rank = GetSpellName(id, subType or BOOKTYPE_SPELL)
		if not spell then
			return nil
		end

		return format("%s|%d|%s|%s|%s|%s", kind, id, "", spell, rank or "", extraID or "")
	elseif kind == "macro" then
		local name, icon, macro = GetMacroInfo(id)
		if not name or not icon or not macro then
			return nil
		end

		return format("%s|%d|%s|%s|%s|%s", kind, id, "", self:CompressText(name), icon, self:CompressText(macro))
	end
end

function ABS:SaveProfile(name)
	local classSets = self.db.sets[playerClass]
	local set = classSets[name]

	if set then
		table_wipe(set)
	else
		set = {}
		classSets[name] = set
	end

	for actionID = 1, CONST.MAX_ACTION_ID do
		set[actionID] = self:SerializeAction(actionID)
	end

	self:Print(format(L["Saved profile %s!"], name))
end

function ABS:FindMacro(id, name, data)
	id = tonumber(id)

	if id and macroCache[id] == data then
		return id
	end

	for index, currentMacro in pairs(macroCache) do
		if currentMacro == data then
			return index
		end
	end

	if name and macroNameCache[name] then
		return macroNameCache[name]
	end
end

function ABS:CacheMacros()
	local blacklist = {}

	table_wipe(macroCache)
	table_wipe(macroNameCache)

	for i = 1, CONST.MAX_MACROS do
		local name, _, macro = GetMacroInfo(i)

		if name then
			if macroNameCache[name] then
				blacklist[name] = true
				macroNameCache[name] = i
			elseif not blacklist[name] then
				macroNameCache[name] = i
			end
		end

		macroCache[i] = macro and self:CompressText(macro) or nil
	end
end

function ABS:CacheSpells()
	table_wipe(spellCache)
	table_wipe(spellBookCache)

	for book = 1, MAX_SKILLLINE_TABS do
		local _, _, offset, numSpells = GetSpellTabInfo(book)

		if offset and numSpells then
			for i = 1, numSpells do
				local index = offset + i
				local spell, rank = GetSpellName(index, BOOKTYPE_SPELL)

				if spell then
					spellCache[spell] = index
					spellCache[lower(spell)] = index
					spellBookCache[spell] = BOOKTYPE_SPELL
					spellBookCache[lower(spell)] = BOOKTYPE_SPELL

					if rank and rank ~= "" then
						spellCache[spell .. rank] = index
						spellBookCache[spell .. rank] = BOOKTYPE_SPELL
					end
				end
			end
		end
	end

	for index = 1, CONST.MAX_PET_SPELLS do
		local spell, rank = GetSpellName(index, BOOKTYPE_PET)

		if not spell then
			break
		end

		if not spellCache[spell] then
			spellCache[spell] = index
			spellBookCache[spell] = BOOKTYPE_PET
		end

		if not spellCache[lower(spell)] then
			spellCache[lower(spell)] = index
			spellBookCache[lower(spell)] = BOOKTYPE_PET
		end

		if rank and rank ~= "" and not spellCache[spell .. rank] then
			spellCache[spell .. rank] = index
			spellBookCache[spell .. rank] = BOOKTYPE_PET
		end
	end
end

function ABS:RestoreMacros(set)
	local perCharacter = false

	for _, data in pairs(set) do
		local kind, macroID, _, macroName, macroIcon, macroData = string_split("|", data)

		if kind == "macro" and not self:FindMacro(macroID, macroName, macroData) then
			local globalNum, charNum = GetNumMacros()

			if globalNum >= CONST.MAX_GLOBAL_MACROS and charNum >= CONST.MAX_CHAR_MACROS then
				tinsert(restoreErrors, format(L["Unable to restore macros, you already have %d global and %d per character ones created."], CONST.MAX_GLOBAL_MACROS, CONST.MAX_CHAR_MACROS))
				break
			elseif globalNum >= CONST.MAX_GLOBAL_MACROS then
				perCharacter = true
			end

			if not iconCache then
				iconCache = {}

				for i = 1, GetNumMacroIcons() do
					local iconPath = GetMacroIconInfo(i)

					if iconPath then
						iconCache[lower(iconPath)] = i
					end
				end
			end

			macroName = self:UncompressText(macroName)

			CreateMacro(macroName == "" and " " or macroName, iconCache[lower(macroIcon or "")] or 1, self:UncompressText(macroData), perCharacter)
		end
	end

	self:CacheMacros()
end

function ABS:RestoreProfile(name)
	local set = self.db.sets[playerClass][name]

	if not set then
		self:Print(format(L['No profile with the name "%s" exists.'], name))
		return
	elseif InCombatLockdown() then
		self:Print(format(L['Unable to restore profile "%s", you are in combat.'], name))
		return
	end

	table_wipe(restoreErrors)

	self:CacheSpells()
	self:CacheMacros()

	if self.db.macro then
		self:RestoreMacros(set)
	end

	ClearCursor()

	local soundToggle = GetCVar("Sound_EnableAllSound")
	if soundToggle then
		SetCVar("Sound_EnableAllSound", 0)
	end

	local ok, err = pcall(function()
		for actionID = 1, CONST.MAX_ACTION_ID do
			local kind, id = GetActionInfo(actionID)

			if kind or id then
				PickupAction(actionID)
				ClearCursor()
			end

			if set[actionID] then
				self:RestoreAction(actionID, string_split("|", set[actionID]))
			end
		end
	end)

	ClearCursor()

	if soundToggle then
		SetCVar("Sound_EnableAllSound", soundToggle)
	end

	if not ok then
		self:Print(tostring(err))
		return
	end

	if #restoreErrors == 0 then
		self:Print(format(L["Restored profile %s!"], name))
	else
		self:Print(format(L["Restored profile %s, failed to restore %d buttons type /abs errors for more information."], name, #restoreErrors))
	end
end

function ABS:RestoreAction(actionID, kind, id, binding, ...)
	if not IsValidSlot(actionID) then
		self:Debug(format("Skipping out of range slot %s", tostring(actionID)))
		return
	end

	if kind == "spell" then
		local spellName, spellRank = ...

		if (self.db.restoreRank or spellRank == "") and spellCache[spellName] then
			PickupSpell(spellCache[spellName], spellBookCache[spellName] or BOOKTYPE_SPELL)
		elseif spellRank ~= "" and spellCache[spellName .. spellRank] then
			PickupSpell(spellCache[spellName .. spellRank], spellBookCache[spellName .. spellRank] or BOOKTYPE_SPELL)
		end

		if GetCursorInfo() ~= kind then
			local lowerSpell = lower(spellName)

			for spell, linked in pairs(self.db.spellSubs) do
				if lowerSpell == spell and spellCache[linked] then
					return self:RestoreAction(actionID, kind, id, binding, linked, nil)
				elseif lowerSpell == linked and spellCache[spell] then
					return self:RestoreAction(actionID, kind, id, binding, spell, nil)
				end
			end

			tinsert(restoreErrors, format(L['Unable to restore spell "%s" to slot #%d, it does not appear to have been learned yet.'], spellName, actionID))
			ClearCursor()
			return
		end

		PlaceAction(actionID)
	elseif kind == "equipmentset" then
		local slotID

		for index = 1, GetNumEquipmentSets() do
			if GetEquipmentSetInfo(index) == id then
				slotID = index
				break
			end
		end

		if not slotID then
			tinsert(restoreErrors, format(L['Unable to restore equipment set "%s" to slot #%d, it does not appear to exist anymore.'], tostring(id), actionID))
			ClearCursor()
			return
		end

		PickupEquipmentSet(slotID)

		if GetCursorInfo() ~= "equipmentset" then
			tinsert(restoreErrors, format(L['Unable to restore equipment set "%s" to slot #%d, it does not appear to exist anymore.'], tostring(id), actionID))
			ClearCursor()
			return
		end

		PlaceAction(actionID)
	elseif kind == "companion" then
		local critterName, critterType, critterSpellID = ...
		local spellID = tonumber(critterSpellID) or tonumber(id)
		local failMessage = critterType == "MOUNT" and L['Unable to restore mount "%s" to slot #%d']
			or L['Unable to restore companion "%s" to slot #%d, it does not appear to exist yet.']

		self:Debug(format("Restoring companion slot #%d: name=%s spellID=%s type=%s", actionID, tostring(critterName), tostring(spellID), tostring(critterType)))

		local foundIndex

		for j = 1, GetNumCompanions(critterType) do
			local _, cName, thisSpellID = GetCompanionInfo(critterType, j)

			if thisSpellID == spellID or (critterName ~= "" and cName == critterName) then
				foundIndex = j
				break
			end
		end

		if not foundIndex then
			tinsert(restoreErrors, format(failMessage, tostring(critterName), actionID))
			ClearCursor()
			return
		end

		PickupCompanion(critterType, foundIndex)

		if GetCursorInfo() ~= "companion" then
			self:Debug(format("PickupCompanion failed for %s idx=%d", tostring(critterType), foundIndex))
			tinsert(restoreErrors, format(failMessage, tostring(critterName), actionID))
			ClearCursor()
			return
		end

		PlaceAction(actionID)
	elseif kind == "item" then
		local itemName = ...

		PickupItem(id)

		if GetCursorInfo() ~= kind then
			tinsert(restoreErrors, format(L['Unable to restore item "%s" to slot #%d, cannot be found in inventory.'], (itemName and itemName ~= "" and itemName) or tostring(id), actionID))
			ClearCursor()
			return
		end

		PlaceAction(actionID)
	elseif kind == "macro" then
		local name, _, content = ...
		local macroID = self:FindMacro(id, name, content)

		if not macroID then
			tinsert(restoreErrors, format(L["Unable to restore macro id #%d to slot #%d, it appears to have been deleted."], tonumber(id) or 0, actionID))
			ClearCursor()
			return
		end

		PickupMacro(macroID)

		if GetCursorInfo() ~= kind then
			tinsert(restoreErrors, format(L["Unable to restore macro id #%d to slot #%d, it appears to have been deleted."], tonumber(id) or 0, actionID))
			ClearCursor()
			return
		end

		PlaceAction(actionID)
	end
end

function ABS:DeleteProfile(name)
	StaticPopupDialogs["ABS_CONFIRM_DELETE"] = {
		text = format(L["Are you sure you want to delete profile %s?"] .. "\n\n" .. L["This action cannot be undone."], name),
		button1 = YES,
		button2 = NO,
		OnAccept = function()
			self.db.sets[playerClass][name] = nil
			self:Print(format(L["Deleted saved profile %s."], name))
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
		showAlert = true,
		title = L["Delete Profile"],
	}

	StaticPopup_Show("ABS_CONFIRM_DELETE")
end

function ABS:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ABS|r: " .. msg)
end

function ABS:Debug(msg)
	if self.db and self.db.debug then
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ABS Debug|r: " .. msg)
	end
end

SLASH_ACTIONBARSAVER1 = nil
SlashCmdList["ACTIONBARSAVER"] = nil

SLASH_ABS1 = "/abs"
SLASH_ABS2 = "/actionbarsaver"
SlashCmdList["ABS"] = function(msg)
	local cmd, arg = string_split(" ", msg or "", 2)
	cmd = lower(cmd or "")
	arg = lower(arg or "")

	local self = ABS

	if cmd == "save" and arg ~= "" then
		self:SaveProfile(arg)
	elseif cmd == "link" and arg ~= "" then
		local first, second = string.match(arg, '"(.+)" "(.+)"')
		first = trim(first or "")
		second = trim(second or "")

		if first == "" or second == "" then
			self:Print(L["Invalid spells passed, remember you must put quotes around both of them."])
			return
		end

		self.db.spellSubs[first] = second

		self:Print(format(L['Spells "%s" and "%s" are now linked.'], first, second))
	elseif cmd == "restore" and arg ~= "" then
		if not self.db.sets[playerClass][arg] then
			self:Print(format(L['Cannot restore profile "%s", you can only restore profiles saved to your class.'], arg))
			return
		end

		self:RestoreProfile(arg)
	elseif cmd == "rename" and arg ~= "" then
		local old, new = string_split(" ", arg, 2)
		new = trim(new or "")
		old = trim(old or "")

		if new == old then
			self:Print(format(L['You cannot rename "%s" to "%s" they are the same profile names.'], old, new))
			return
		elseif new == "" then
			self:Print(format(L['No name specified to rename "%s" to.'], old))
			return
		elseif self.db.sets[playerClass][new] then
			self:Print(format(L['Cannot rename "%s" to "%s" a profile already exists for %s.'], old, new, (UnitClass("player"))))
			return
		elseif not self.db.sets[playerClass][old] then
			self:Print(format(L['No profile with the name "%s" exists.'], old))
			return
		end

		self.db.sets[playerClass][new] = CopyTable(self.db.sets[playerClass][old])
		self.db.sets[playerClass][old] = nil

		self:Print(format(L['Renamed "%s" to "%s"'], old, new))
	elseif cmd == "errors" then
		if #restoreErrors == 0 then
			self:Print(L["No errors found!"])
			return
		end

		self:Print(format(L["Errors found: %d"], #restoreErrors))

		for _, text in pairs(restoreErrors) do
			DEFAULT_CHAT_FRAME:AddMessage(text)
		end
	elseif cmd == "delete" then
		self:DeleteProfile(arg)
	elseif cmd == "list" then
		local classes, setList = {}, {}

		for class in pairs(self.db.sets) do
			tinsert(classes, class)
		end

		table.sort(classes)

		for _, class in pairs(classes) do
			table_wipe(setList)

			for setName in pairs(self.db.sets[class]) do
				tinsert(setList, setName)
			end

			if #setList > 0 then
				DEFAULT_CHAT_FRAME:AddMessage(format("|cff33ff99%s|r: %s", L[class] or "???", table.concat(setList, ", ")))
			end
		end
	elseif cmd == "macro" then
		self.db.macro = not self.db.macro

		self:Print(self.db.macro and L["Auto macro restoration is now enabled!"] or L["Auto macro restoration is now disabled!"])
	elseif cmd == "count" then
		self.db.checkCount = not self.db.checkCount

		self:Print(self.db.checkCount and L["Checking item count is now enabled!"] or L["Checking item count is now disabled!"])
	elseif cmd == "rank" then
		self.db.restoreRank = not self.db.restoreRank

		self:Print(self.db.restoreRank and L["Auto restoring highest spell rank is now enabled!"] or L["Auto restoring highest spell rank is now disabled!"])
	elseif cmd == "autosave" then
		self.db.autoSave = not self.db.autoSave

		self:Print(self.db.autoSave and "AutoSave on logout: enabled" or "AutoSave on logout: disabled")
	elseif cmd == "debug" then
		self.db.debug = not self.db.debug

		self:Print(self.db.debug and "Debug mode enabled" or "Debug mode disabled")
	else
		self:Print(L["Slash commands"])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs save <profile> - Saves your current action bar setup under the given profile."])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs restore <profile> - Changes your action bars to the passed profile."])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs delete <profile> - Deletes the saved profile."])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs rename <oldProfile> <newProfile> - Renames a saved profile from oldProfile to newProfile."])
		DEFAULT_CHAT_FRAME:AddMessage(L['/abs link "<spell 1>" "<spell 2>" - Links a spell with another, INCLUDE QUOTES for example you can use "Shadowmeld" "War Stomp" so if War Stomp can\'t be found, it\'ll use Shadowmeld and vica versa.'])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs count - Toggles checking if you have the item in your inventory before restoring it, use if you have disconnect issues when restoring."])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs macro - Attempts to restore macros that have been deleted for a profile."])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs rank - Toggles if ABS should restore the highest rank of the spell, or the one saved originally."])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs list - Lists all saved profiles."])
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(self, event, addon)
	if event == "ADDON_LOADED" then
		if addon == "ActionBarSaver" then
			ABS:OnInitialize()
			self:UnregisterEvent("ADDON_LOADED")
		end
	elseif event == "PLAYER_LOGOUT" then
		if ABS.db and ABS.db.autoSave and playerClass then
			ABS:SaveProfile("AutoSave")
		end
	end
end)
