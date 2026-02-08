ActionBarSaver = select(2, ...)

local ABS = ActionBarSaver
local L = ABS.locals

local restoreErrors, spellCache, macroCache, macroNameCache = {}, {}, {}, {}
local iconCache, playerClass

local CONST = {
	MAX_MACROS = 54,
	MAX_CHAR_MACROS = 18,
	MAX_GLOBAL_MACROS = 36,
	MAX_ACTION_BUTTONS = 360,
	POSSESSION_START = 121,
	POSSESSION_END = 132,
	TEMP_MOUNT_MACRO_NAME = "ABS_Mount",
}

local GetSpellName = GetSpellName
local GetMacroInfo = GetMacroInfo
local GetActionInfo = GetActionInfo
local ClearCursor = ClearCursor
local PickupAction = PickupAction
local PlaceAction = PlaceAction
local string_split = string.split
local table_wipe = table.wipe

local function GetMountSpellID(companionIndex, actionInfoExtraID)
	if actionInfoExtraID and actionInfoExtraID > 0 then
		return actionInfoExtraID
	end
	local _, _, spellID = GetCompanionInfo("MOUNT", companionIndex)
	return spellID
end

function ABS:OnInitialize()
	local defaults = {
		macro = false,
		checkCount = false,
		restoreRank = true,
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
end

function ABS:CompressText(text)
	text = string.gsub(text, "\n", "/n")
	text = string.gsub(text, "/n$", "")
	text = string.gsub(text, "||", "/124")

	return string.trim(text)
end

function ABS:UncompressText(text)
	text = string.gsub(text, "/n", "\n")
	text = string.gsub(text, "/124", "|")

	return string.trim(text)
end

function ABS:SaveProfile(name)
	self.db.sets[playerClass][name] = self.db.sets[playerClass][name] or {}
	local set = self.db.sets[playerClass][name]

	for actionID = 1, CONST.MAX_ACTION_BUTTONS do
		set[actionID] = nil

		local type, id, subType, extraID = GetActionInfo(actionID)
		if type and id and (actionID < CONST.POSSESSION_START or actionID > CONST.POSSESSION_END) then
			if type == "companion" then
				if subType == "MOUNT" then
					local spellID = GetMountSpellID(id, extraID)
					local name = spellID and GetSpellInfo(spellID)
					if name and spellID then
						set[actionID] = string.format("%s|%d|%s|%s|%s|%d", type, spellID, "", name, subType, spellID)
						if self.db.debug then
							self:Debug(
								string.format(
									"Saving mount slot %d: name=%s spellID=%d (companionIdx=%d)",
									actionID,
									tostring(name),
									spellID,
									id
								)
							)
						end
					elseif self.db.debug then
						self:Debug(
							string.format(
								"FAILED saving mount slot %d: companionIdx=%d extraID=%s (spellID nil)",
								actionID,
								id,
								tostring(extraID)
							)
						)
					end
				else
					local cName, cSpellID = GetCompanionInfo(subType, id)
					local spellID = (extraID and extraID > 0) and extraID or cSpellID
					local name = cName or (spellID and GetSpellInfo(spellID))
					if name and spellID then
						set[actionID] = string.format("%s|%d|%s|%s|%s|%d", type, spellID, "", name, subType, spellID)
						if self.db.debug then
							self:Debug(
								string.format(
									"Saving companion slot %d: name=%s spellID=%d type=%s",
									actionID,
									tostring(name),
									spellID,
									tostring(subType)
								)
							)
						end
					end
				end
			elseif type == "equipmentset" then
				set[actionID] = string.format("%s|%s|%s", type, id, "")
			elseif type == "item" then
				set[actionID] = string.format("%s|%d|%s|%s", type, id, "", (GetItemInfo(id)) or "")
			elseif type == "spell" and id > 0 then
				local spell, rank = GetSpellName(id, BOOKTYPE_SPELL)
				if spell then
					set[actionID] = string.format("%s|%d|%s|%s|%s|%s", type, id, "", spell, rank or "", extraID or "")
				end
			elseif type == "macro" then
				local name, icon, macro = GetMacroInfo(id)
				if name and icon and macro then
					set[actionID] = string.format(
						"%s|%d|%s|%s|%s|%s",
						type,
						actionID,
						"",
						self:CompressText(name),
						icon,
						self:CompressText(macro)
					)
				end
			end
		end
	end

	self:Print(string.format(L["Saved profile %s!"], name))
end

function ABS:FindMacro(id, name, data)
	if macroCache[id] == data then
		return id
	end

	for id, currentMacro in pairs(macroCache) do
		if currentMacro == data then
			return id
		end
	end

	if macroNameCache[name] then
		return macroNameCache[name]
	end

	return nil
end

function ABS:RestoreMacros(set)
	local perCharacter = true
	for id, data in pairs(set) do
		local type, id, binding, macroName, macroIcon, macroData = string.split("|", data)
		if type == "macro" then
			-- Do we already have a macro?
			local macroID = self:FindMacro(id, macroName, macroData)
			if not macroID then
				local globalNum, charNum = GetNumMacros()
				-- Make sure we aren't at the limit
				if globalNum == CONST.MAX_GLOBAL_MACROS and charNum == CONST.MAX_CHAR_MACROS then
					table.insert(
						restoreErrors,
						L["Unable to restore macros, you already have 18 global and 18 per character ones created."]
					)
					break

				elseif charNum == CONST.MAX_CHAR_MACROS then
					perCharacter = false
				end

				if not iconCache then
					iconCache = {}
					for i = 1, GetNumMacroIcons() do
						iconCache[(GetMacroIconInfo(i))] = i
					end
				end

				macroName = self:UncompressText(macroName)

				CreateMacro(
					macroName == "" and " " or macroName,
					iconCache[macroIcon] or 1,
					self:UncompressText(macroData),
					nil,
					perCharacter
				)
			end
		end
	end

	local blacklist = {}
	for i = 1, CONST.MAX_MACROS do
		local name, icon, macro = GetMacroInfo(i)

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

-- Restore a saved profile
function ABS:RestoreProfile(name)
	local set = self.db.sets[playerClass][name]
	if not set then
		self:Print(string.format(L['No profile with the name "%s" exists.'], name))
		return
	elseif InCombatLockdown() then
		self:Print(string.format(L['Unable to restore profile "%s", you are in combat.'], name))
		return
	end

	table.wipe(macroCache)
	table.wipe(spellCache)
	table.wipe(macroNameCache)

	-- Cache spells
	for book = 1, MAX_SKILLLINE_TABS do
		local _, _, offset, numSpells = GetSpellTabInfo(book)

		for i = 1, numSpells do
			local index = offset + i
			local spell, rank = GetSpellName(index, BOOKTYPE_SPELL)

			-- This way we restore the max rank of spells
			spellCache[spell] = index
			spellCache[string.lower(spell)] = index

			if rank and rank ~= "" then
				spellCache[spell .. rank] = index
			end
		end
	end

	-- Cache macros
	local blacklist = {}
	for i = 1, CONST.MAX_MACROS do
		local name, icon, macro = GetMacroInfo(i)

		if name then
			-- If there are macros with the same name, then blacklist and don't look by name
			if macroNameCache[name] then
				blacklist[name] = true
				macroNameCache[name] = i
			elseif not blacklist[name] then
				macroNameCache[name] = i
			end
		end

		macroCache[i] = macro and self:CompressText(macro) or nil
	end

	-- Check if we need to restore any missing macros
	if self.db.macro then
		self:RestoreMacros(set)
	end

	-- Start fresh with nothing on the cursor
	ClearCursor()

	-- Save current sound setting
	local soundToggle = GetCVar("Sound_EnableAllSound")
	-- Turn sound off
	SetCVar("Sound_EnableAllSound", 0)

	for i = 1, CONST.MAX_ACTION_BUTTONS do
		if i < CONST.POSSESSION_START or i > CONST.POSSESSION_END then
			local type, id = GetActionInfo(i)

			if id or type then
				PickupAction(i)
				ClearCursor()
			end

			if set[i] then
				self:RestoreAction(i, string.split("|", set[i]))
			end
		end
	end

	SetCVar("Sound_EnableAllSound", soundToggle)

	if #restoreErrors == 0 then
		self:Print(string.format(L["Restored profile %s!"], name))
	else
		self:Print(
			string.format(
				L["Restored profile %s, failed to restore %d buttons type /abs errors for more information."],
				name,
				#restoreErrors
			)
		)
	end
end

function ABS:RestoreAction(i, type, actionID, binding, ...)
	-- Restore a spell
	if type == "spell" then
		local spellName, spellRank = ...
		if (self.db.restoreRank or spellRank == "") and spellCache[spellName] then
			PickupSpell(spellCache[spellName], BOOKTYPE_SPELL)
		elseif spellRank ~= "" and spellCache[spellName .. spellRank] then
			PickupSpell(spellCache[spellName .. spellRank], BOOKTYPE_SPELL)
		end

		if GetCursorInfo() ~= type then
			local lowerSpell = string.lower(spellName)
			for spell, linked in pairs(self.db.spellSubs) do
				if lowerSpell == spell and spellCache[linked] then
					self:RestoreAction(i, type, actionID, binding, linked, nil)
					return
				elseif lowerSpell == linked and spellCache[spell] then
					self:RestoreAction(i, type, actionID, binding, spell, nil)
					return
				end
			end

			table.insert(
				restoreErrors,
				string.format(
					L['Unable to restore spell "%s" to slot #%d, it does not appear to have been learned yet.'],
					spellName,
					i
				)
			)
			ClearCursor()
			return
		end

		PlaceAction(i)
	-- Restore an equipment set button
	elseif type == "equipmentset" then
		local slotID = -1
		for i = 1, GetNumEquipmentSets() do
			if GetEquipmentSetInfo(i) == actionID then
				slotID = i
				break
			end
		end

		PickupEquipmentSet(slotID)
		if GetCursorInfo() ~= "equipmentset" then
			table.insert(
				restoreErrors,
				string.format(
					L['Unable to restore equipment set "%s" to slot #%d, it does not appear to exist anymore.'],
					actionID,
					i
				)
			)
			ClearCursor()
			return
		end

		PlaceAction(i)
	elseif type == "companion" then
		local critterName, critterType, critterSpellID = ...
		local spellID = tonumber(actionID) or tonumber(critterSpellID)

		if self.db.debug then
			self:Debug(
				string.format(
					"Restoring companion slot #%d: name=%s spellID=%s type=%s",
					i,
					tostring(critterName),
					tostring(spellID),
					tostring(critterType)
				)
			)
		end

		local foundIndex
		local numCompanions = GetNumCompanions(critterType)
		for j = 1, numCompanions do
			local _, cName, thisSpellID = GetCompanionInfo(critterType, j)
			if thisSpellID == spellID or (spellID == nil and cName == critterName) then
				foundIndex = j
				break
			end
		end

		if not foundIndex then
			table.insert(
				restoreErrors,
				string.format(
					critterType == "MOUNT" and L['Unable to restore mount "%s" to slot #%d']
						or L['Unable to restore companion "%s" to slot #%d, it does not appear to exist yet.'],
					tostring(critterName),
					i
				)
			)
			ClearCursor()
			return
		end

		if self.db.debug then
			self:Debug(
				string.format(
					"Found %s at companion index %d (spellID=%s)",
					tostring(critterType),
					foundIndex,
					tostring(spellID)
				)
			)
		end

		PickupCompanion(critterType, foundIndex)
		if GetCursorInfo() ~= "companion" then
			if self.db.debug then
				self:Debug(string.format("PickupCompanion failed for %s idx=%d", tostring(critterType), foundIndex))
			end
			table.insert(
				restoreErrors,
				string.format(
					critterType == "MOUNT" and L['Unable to restore mount "%s" to slot #%d']
						or L['Unable to restore companion "%s" to slot #%d, it does not appear to exist yet.'],
					tostring(critterName),
					i
				)
			)
			ClearCursor()
			return
		end
		PlaceAction(i)
	-- Restore an item
	elseif type == "item" then
		PickupItem(actionID)

		if GetCursorInfo() ~= type then
			local itemName = select(i, ...)
			table.insert(
				restoreErrors,
				string.format(
					L['Unable to restore item "%s" to slot #%d, cannot be found in inventory.'],
					itemName and itemName ~= "" and itemName or actionID,
					i
				)
			)
			ClearCursor()
			return
		end

		PlaceAction(i)
	-- Restore a macro
	elseif type == "macro" then
		local name, _, content = ...
		PickupMacro(self:FindMacro(actionID, name, content or -1))
		if GetCursorInfo() ~= type then
			table.insert(
				restoreErrors,
				string.format(
					L["Unable to restore macro id #%d to slot #%d, it appears to have been deleted."],
					actionID,
					i
				)
			)
			ClearCursor()
			return
		end

		PlaceAction(i)
	end
end

function ABS:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ABS|r: " .. msg)
end

SLASH_ACTIONBARSAVER1 = nil
SlashCmdList["ACTIONBARSAVER"] = nil

SLASH_ABS1 = "/abs"
SLASH_ABS2 = "/actionbarsaver"
SlashCmdList["ABS"] = function(msg)
	msg = msg or ""

	local cmd, arg = string.split(" ", msg, 2)
	cmd = string.lower(cmd or "")
	arg = string.lower(arg or "")

	local self = ABS

	-- Profile saving
	if cmd == "save" and arg ~= "" then
		self:SaveProfile(arg)

	-- Spell sub
	elseif cmd == "link" and arg ~= "" then
		local first, second = string.match(arg, '"(.+)" "(.+)"')
		first = string.trim(first or "")
		second = string.trim(second or "")

		if first == "" or second == "" then
			self:Print(L["Invalid spells passed, remember you must put quotes around both of them."])
			return
		end

		self.db.spellSubs[first] = second

		self:Print(string.format(L['Spells "%s" and "%s" are now linked.'], first, second))

	elseif cmd == "restore" and arg ~= "" then
		table_wipe(restoreErrors)

		if not self.db.sets[playerClass][arg] then
			self:Print(
				string.format(L['Cannot restore profile "%s", you can only restore profiles saved to your class.'], arg)
			)
			return
		end

		self:RestoreProfile(arg)

	elseif cmd == "rename" and arg ~= "" then
		local old, new = string.split(" ", arg, 2)
		new = string.trim(new or "")
		old = string.trim(old or "")

		if new == old then
			self:Print(string.format(L['You cannot rename "%s" to "%s" they are the same profile names.'], old, new))
			return
		elseif new == "" then
			self:Print(string.format(L['No name specified to rename "%s" to.'], old))
			return
		elseif self.db.sets[playerClass][new] then
			self:Print(
				string.format(
					L['Cannot rename "%s" to "%s" a profile already exists for %s.'],
					old,
					new,
					(UnitClass("player"))
				)
			)
			return
		elseif not self.db.sets[playerClass][old] then
			self:Print(string.format(L['No profile with the name "%s" exists.'], old))
			return
		end

		self.db.sets[playerClass][new] = CopyTable(self.db.sets[playerClass][old])
		self.db.sets[playerClass][old] = nil

		self:Print(string.format(L['Renamed "%s" to "%s"'], old, new))

	-- Restore errors
	elseif cmd == "errors" then
		if #restoreErrors == 0 then
			self:Print(L["No errors found!"])
			return
		end

		self:Print(string.format(L["Errors found: %d"], #restoreErrors))
		for _, text in pairs(restoreErrors) do
			DEFAULT_CHAT_FRAME:AddMessage(text)
		end

	-- Delete profile
	elseif cmd == "delete" then
		self:DeleteProfile(arg)

	-- List profiles
	elseif cmd == "list" then
		local classes = {}
		local setList = {}

		for class, sets in pairs(self.db.sets) do
			table.insert(classes, class)
		end

		table.sort(classes, function(a, b)
			return a < b
		end)

		for _, class in pairs(classes) do
			for i = #setList, 1, -1 do
				table.remove(setList, i)
			end
			for setName in pairs(self.db.sets[class]) do
				table.insert(setList, setName)
			end

			if #setList > 0 then
				DEFAULT_CHAT_FRAME:AddMessage(
					string.format("|cff33ff99%s|r: %s", L[class] or "???", table.concat(setList, ", "))
				)
			end
		end

	-- Macro restoring
	elseif cmd == "macro" then
		self.db.macro = not self.db.macro

		if self.db.macro then
			self:Print(L["Auto macro restoration is now enabled!"])
		else
			self:Print(L["Auto macro restoration is now disabled!"])
		end

	-- Item counts
	elseif cmd == "count" then
		self.db.checkCount = not self.db.checkCount

		if self.db.checkCount then
			self:Print(L["Checking item count is now enabled!"])
		else
			self:Print(L["Checking item count is now disabled!"])
		end

	-- Rank restore
	elseif cmd == "rank" then
		self.db.restoreRank = not self.db.restoreRank

		if self.db.restoreRank then
			self:Print(L["Auto restoring highest spell rank is now enabled!"])
		else
			self:Print(L["Auto restoring highest spell rank is now disabled!"])
		end

	-- Halp
	elseif cmd == "debug" then
		self.db.debug = not self.db.debug
		self:Print(self.db.debug and "Debug mode enabled" or "Debug mode disabled")
	else
		self:Print(L["Slash commands"])
		DEFAULT_CHAT_FRAME:AddMessage(
			L["/abs save <profile> - Saves your current action bar setup under the given profile."]
		)
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs restore <profile> - Changes your action bars to the passed profile."])
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs delete <profile> - Deletes the saved profile."])
		DEFAULT_CHAT_FRAME:AddMessage(
			L["/abs rename <oldProfile> <newProfile> - Renames a saved profile from oldProfile to newProfile."]
		)
		DEFAULT_CHAT_FRAME:AddMessage(
			L['/abs link "<spell 1>" "<spell 2>" - Links a spell with another, INCLUDE QUOTES for example you can use "Shadowmeld" "War Stomp" so if War Stomp can\'t be found, it\'ll use Shadowmeld and vica versa.']
		)
		DEFAULT_CHAT_FRAME:AddMessage(
			L["/abs count - Toggles checking if you have the item in your inventory before restoring it, use if you have disconnect issues when restoring."]
		)
		DEFAULT_CHAT_FRAME:AddMessage(
			L["/abs macro - Attempts to restore macros that have been deleted for a profile."]
		)
		DEFAULT_CHAT_FRAME:AddMessage(
			L["/abs rank - Toggles if ABS should restore the highest rank of the spell, or the one saved originally."]
		)
		DEFAULT_CHAT_FRAME:AddMessage(L["/abs list - Lists all saved profiles."])
	end
end

-- Check if we need to load
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(self, event, addon)
	if event == "ADDON_LOADED" and addon == "ActionBarSaver" then
		ABS:OnInitialize()
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_LOGOUT" then
		if ABS.db and ABS.db.autoSave then
			ABS:SaveProfile("AutoSave")
		end
	end
end)

function ABS:DeleteProfile(name)
	StaticPopupDialogs["ABS_CONFIRM_DELETE"] = {
		text = string.format(
			L["Are you sure you want to delete profile %s?"] .. "\n\n" .. L["This action cannot be undone."],
			name
		),
		button1 = YES,
		button2 = NO,
		OnAccept = function()
			self.db.sets[playerClass][name] = nil
			self:Print(string.format(L["Deleted saved profile %s."], name))
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

function ABS:Debug(msg)
	if self.db.debug then
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ABS Debug|r: " .. msg)
	end
end
