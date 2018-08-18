-- ----------------------------------------------------------------------------
-- Localized Lua globals.
-- ----------------------------------------------------------------------------
local math = _G.math
local table = _G.table

local pairs = _G.pairs

-- ----------------------------------------------------------------------------
-- Addon namespace.
-- ----------------------------------------------------------------------------
local AddOnFolderName, private = ...
local LibStub = _G.LibStub
local MailMinder = LibStub("AceAddon-3.0"):NewAddon(AddOnFolderName, "AceEvent-3.0")

local LibQTip = LibStub("LibQTip-1.0")
local LDBIcon = LibStub("LibDBIcon-1.0")
local L = LibStub("AceLocale-3.0"):GetLocale(AddOnFolderName)

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------
local DataObject = LibStub("LibDataBroker-1.1"):NewDataObject(AddOnFolderName, {
	icon = [[Interface\MINIMAP\TRACKING\Mailbox]],
	label = AddOnFolderName,
	text = _G.NONE,
	type = "data source",
})

local TitleFont = _G.CreateFont("MailMinderTitleFont")
TitleFont:SetTextColor(1, 0.82, 0)
TitleFont:SetFontObject("QuestTitleFont")

local PLAYER_NAME = _G.UnitName("player")
local REALM_NAME = _G.GetRealmName()
local MAX_MAIL_DAYS = 30
local SECONDS_PER_DAY = 24 * 60 * 60
local SECONDS_PER_HOUR = 60 * 60

local COLOR_TABLE = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS

local DB_DEFAULTS = {
	global = {
		datafeed = {
			minimap_icon = {
				hide = false,
			},
		},
		characters = {}, -- Populated as the AddOn operates.
		tooltip = {
			hide_hint = false,
			scale = 1,
			timer = 0.25,
		},
	}
}

local DEFAULT_STATIONARY = [[Interface\Icons\INV_Scroll_03]]

local ICON_MINUS = [[|TInterface\MINIMAP\UI-Minimap-ZoomOutButton-Up:16:16|t]]
local ICON_MINUS_DOWN = [[|TInterface\MINIMAP\UI-Minimap-ZoomOutButton-Down:16:16|t]]

local ICON_PLUS = [[|TInterface\MINIMAP\UI-Minimap-ZoomInButton-Up:16:16|t]]
local ICON_PLUS_DOWN = [[|TInterface\MINIMAP\UI-Minimap-ZoomInButton-Down:16:16|t]]

-- ----------------------------------------------------------------------------
-- Variables.
-- ----------------------------------------------------------------------------
local db
local currentMail = {}
local sortedCharacterNames = {}

-- ----------------------------------------------------------------------------
-- Helper functions.
-- ----------------------------------------------------------------------------
local function PercentColorGradient(min, max)
	local red_low, green_low, blue_low = 1, 0.10, 0.10
	local red_mid, green_mid, blue_mid = 1, 1, 0
	local red_high, green_high, blue_high = 0.25, 0.75, 0.25
	local percentage = min / max

	if percentage >= 1 then
		return red_high, green_high, blue_high
	elseif percentage <= 0 then
		return red_low, green_low, blue_low
	end

	local integral, fractional = math.modf(percentage * 2)

	if integral == 1 then
		red_low, green_low, blue_low, red_mid, green_mid, blue_mid = red_mid, green_mid, blue_mid, red_high, green_high, blue_high
	end

	return red_low + (red_mid - red_low) * fractional, green_low + (green_mid - green_low) * fractional, blue_low + (blue_mid - blue_low) * fractional
end

local function FormattedSeconds(seconds)
	local negative = ""

	if not seconds then
		seconds = 0
	end

	if seconds < 0 then
		negative = "-"
		seconds = -seconds
	end

	local L_DAY_ONELETTER_ABBR = _G.DAY_ONELETTER_ABBR:gsub("%s*%%d%s*", "")

	if not seconds or seconds >= SECONDS_PER_DAY * 36500 then -- 100 years
		return ("%s**%s **:**"):format(negative, L_DAY_ONELETTER_ABBR)
	elseif seconds >= SECONDS_PER_DAY then
		return ("%s%d%s %d:%02d"):format(negative, seconds / SECONDS_PER_DAY, L_DAY_ONELETTER_ABBR, math.fmod(seconds / SECONDS_PER_HOUR, 24), math.fmod(seconds / 60, 60))
	else
		return ("%s%d:%02d"):format(negative, seconds / SECONDS_PER_HOUR, math.fmod(seconds / 60, 60))
	end
end

local function DayColorCode(daysLeft)
	local r, g, b = PercentColorGradient(daysLeft, MAX_MAIL_DAYS)
	return ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

-- ----------------------------------------------------------------------------
-- Tooltip functions.
-- ----------------------------------------------------------------------------
local DrawTooltip
do
	local NUM_TOOLTIP_COLUMNS = 7
	local Tooltip
	local LDB_anchor

	local function Tooltip_OnRelease(self)
		Tooltip = nil
		LDB_anchor = nil
	end

	local function ExpandButton_OnMouseUp(tooltipCell, realmAndCharacterNames)
		local realmName, characterName = (":"):split(realmAndCharacterNames, 2)

		db.characters[realmName][characterName].expanded = not db.characters[realmName][characterName].expanded
		DrawTooltip(LDB_anchor)
	end

	local function ExpandButton_OnMouseDown(tooltipCell, isExpanded)
		local line, column = tooltipCell:GetPosition()
		Tooltip:SetCell(line, column, isExpanded and ICON_MINUS_DOWN or ICON_PLUS_DOWN)
	end

	function DrawTooltip(anchorFrame)
		if not anchorFrame then
			return
		end

		LDB_anchor = anchorFrame

		if not Tooltip then
			Tooltip = LibQTip:Acquire(AddOnFolderName .. "Tooltip", NUM_TOOLTIP_COLUMNS, "LEFT", "CENTER", "CENTER", "CENTER", "CENTER", "CENTER", "CENTER")
			Tooltip:SetAutoHideDelay(db.tooltip.timer, anchorFrame)
			Tooltip:SmartAnchorTo(anchorFrame)
			Tooltip:SetBackdropColor(0.05, 0.05, 0.05, 1)
			Tooltip:SetScale(db.tooltip.scale)

			Tooltip.OnRelease = Tooltip_OnRelease
		end

		Tooltip:Clear()
		Tooltip:SetCellMarginH(0)
		Tooltip:SetCellMarginV(1)

		Tooltip:SetCell(Tooltip:AddLine(), 1, AddOnFolderName, TitleFont, "CENTER", NUM_TOOLTIP_COLUMNS)
		Tooltip:AddSeparator(1, 0.5, 0.5, 0.5)
		Tooltip:AddSeparator(1, 0.5, 0.5, 0.5)

		local line = Tooltip:AddLine(" ", _G.NAME, _G.CLOSES_IN, _G.MAIL_LABEL, _G.AUCTIONS)
		Tooltip:SetLineColor(line, 0, 0, 0)

		Tooltip:AddSeparator(1, 0.5, 0.5, 0.5)

		local now = _G.time()

		for realm, characterList in pairs(db.characters) do
			for characterName, characterData in pairs(characterList) do
				if #characterData.mailEntries > 0 then
					line = Tooltip:AddLine()
					Tooltip:SetCell(line, 1, characterData.expanded and ICON_MINUS or ICON_PLUS)

					local colorTable = COLOR_TABLE[characterData.class]
					local r, g, b = colorTable.r, colorTable.g, colorTable.b
					Tooltip:SetCell(line, 2, characterName)
					Tooltip:SetCellTextColor(line, 2, r, g, b)

					local lowestExpirationSeconds = characterData.nextExpirationSeconds - (now - characterData.lastUpdateSeconds)
					local lowestDaysLeft = lowestExpirationSeconds / SECONDS_PER_DAY
					Tooltip:SetCell(line, 3, FormattedSeconds(lowestExpirationSeconds))
					Tooltip:SetCellTextColor(line, 3, PercentColorGradient(lowestDaysLeft, MAX_MAIL_DAYS))

					Tooltip:SetCell(line, 4, characterData.mailCount)
					Tooltip:SetCell(line, 5, characterData.auction_count)
					Tooltip:SetCellScript(line, 1, "OnMouseUp", ExpandButton_OnMouseUp, ("%s:%s"):format(realm, characterName))
					Tooltip:SetCellScript(line, 1, "OnMouseDown", ExpandButton_OnMouseDown, characterData.expanded)

					if characterData.expanded then
						Tooltip:AddSeparator(1, 0.5, 0.5, 0.5)

						line = Tooltip:AddLine(" ")
						Tooltip:SetLineColor(line, 0, 0, 0)
						Tooltip:SetCell(line, 2, _G.MAIL_SUBJECT_LABEL, "CENTER", 4)
						Tooltip:SetCell(line, 6, _G.FROM)
						Tooltip:SetCell(line, 7, _G.CLOSES_IN)

						Tooltip:AddSeparator(1, 0.5, 0.5, 0.5)

						for index = 1, #characterData.mailEntries do
							local mailEntry = characterData.mailEntries[index]
							local expirationSeconds = mailEntry.expirationSeconds - (now - characterData.lastUpdateSeconds)
							local daysLeft = expirationSeconds / SECONDS_PER_DAY

							line = Tooltip:AddLine(" ")
							Tooltip:SetCell(line, 2, ("|T%s:16:16|t %s%s|r"):format(mailEntry.packageIcon or mailEntry.stationaryIcon, _G.NORMAL_FONT_COLOR_CODE, mailEntry.subject), "LEFT", 4)

							local senderName = mailEntry.senderName
							local senderData = characterList[senderName]

							Tooltip:SetCell(line, 6, senderName)

							if senderData then
								colorTable = COLOR_TABLE[senderData.class]
								r, g, b = colorTable.r, colorTable.g, colorTable.b
								Tooltip:SetCellTextColor(line, 6, r, g, b)
							end

							Tooltip:SetCell(line, 7, ("%s%s|r"):format(DayColorCode(daysLeft), FormattedSeconds(expirationSeconds)))
						end

						Tooltip:AddSeparator(1, 0.5, 0.5, 0.5)
					end
				end
			end
		end

		if _G.HasNewMail() then
			local senderNames = { _G.GetLatestThreeSenders() }

			Tooltip:AddLine(" ")
			Tooltip:AddSeparator(1, 0.5, 0.5, 0.5)

			line = Tooltip:AddLine()
			Tooltip:SetCell(line, 1, _G.HAVE_MAIL_FROM, "LEFT", NUM_TOOLTIP_COLUMNS)

			for index = 1, #senderNames do
				line = Tooltip:AddLine()
				Tooltip:SetCell(line, 2, senderNames[index], "LEFT")
				Tooltip:SetCellTextColor(line, 2, 0.510, 0.773, 1)
			end

			Tooltip:AddSeparator(1, 0.5, 0.5, 0.5)
		end

		Tooltip:Show()
	end
end -- do-block

local function UpdateInboxData()
	if not _G.MailFrame:IsVisible() then
		return
	end

	local auctionCount = 0
	local inboxCount = _G.GetInboxNumItems()
	local playerData = db.characters[REALM_NAME][PLAYER_NAME]
	local remainingDays = 42
	local salesCount = 0

	table.wipe(playerData.mailEntries)

	for index = 1, inboxCount do
		local invoiceType = _G.GetInboxInvoiceInfo(index)
		local packageIcon, stationaryIcon, senderName, subject, _, _, daysLeft = _G.GetInboxHeaderInfo(index)

		if _G.type(daysLeft) ~= "number" then
			-- if its not a valid value, set to 42.
			daysLeft = 42
		end

		if invoiceType == "seller_temp_invoice" then
			if (daysLeft + 31) < remainingDays then
				remainingDays = daysLeft + 31
			end

			salesCount = salesCount + 1
			auctionCount = auctionCount + 1
		else
			if daysLeft < remainingDays then
				remainingDays = daysLeft
			end

			if invoiceType == "buyer" or invoiceType == "seller" or subject:match(L["Auction expired"]) then
				auctionCount = auctionCount + 1
			end
		end

		table.insert(playerData.mailEntries, {
			expirationSeconds = math.floor(daysLeft * SECONDS_PER_DAY),
			packageIcon = packageIcon,
			senderName = senderName,
			stationaryIcon = stationaryIcon,
			subject = subject,
		})
	end

	playerData.lastUpdateSeconds = _G.time()
	playerData.mailCount = inboxCount
	playerData.sales_count = salesCount
	playerData.auction_count = auctionCount
	playerData.nextExpirationSeconds = math.floor(remainingDays * SECONDS_PER_DAY)
end

-- ----------------------------------------------------------------------------
-- Events.
-- ----------------------------------------------------------------------------
function MailMinder:MAIL_SEND_SUCCESS()
	if not currentMail.recipient then
		return
	end

	local mailExpirationSeconds = math.floor((currentMail.is_cod and 4 or 31) * SECONDS_PER_DAY)
	local now = _G.time()
	local characterData = db.characters[REALM_NAME][currentMail.recipient]

	local newMailEntry = {
		expirationSeconds = mailExpirationSeconds,
		senderName = PLAYER_NAME,
		stationaryIcon = DEFAULT_STATIONARY,
		subject = currentMail.subject,
	}

	if not characterData then
		db.characters[REALM_NAME][currentMail.recipient] = {
			nextExpirationSeconds = mailExpirationSeconds,
			lastUpdateSeconds = now,
			mailCount = 1,
			mailEntries = {
				newMailEntry
			}
		}
		return
	end

	if mailExpirationSeconds < math.floor(characterData.nextExpirationSeconds) - (now - characterData.lastUpdateSeconds) then
		characterData.nextExpirationSeconds = mailExpirationSeconds
		characterData.lastUpdateSeconds = now
	end

	table.insert(characterData.mailEntries, newMailEntry)
	characterData.mailCount = characterData.mailCount + 1
end

-- ----------------------------------------------------------------------------
-- DataObject methods.
-- ----------------------------------------------------------------------------
function DataObject:OnEnter()
	DrawTooltip(self)
end

function DataObject:OnLeave()
end

function DataObject:OnClick()
end

function DataObject:Update(eventName)
	local hasNewMail = _G.HasNewMail()
	local now = _G.time()
	local closestSeconds

	for _, characterList in pairs(db.characters) do
		for _, characterData in pairs(characterList) do
			if #characterData.mailEntries > 0 then
				local expirationSeconds = characterData.nextExpirationSeconds - (now - characterData.lastUpdateSeconds)

				if not closestSeconds or expirationSeconds < closestSeconds then
					closestSeconds = expirationSeconds
				end
			end
		end
	end

	if closestSeconds then
		self.text = ("%s%s|r"):format(DayColorCode(closestSeconds / SECONDS_PER_DAY), hasNewMail and _G.HAVE_MAIL or FormattedSeconds(closestSeconds))
	else
		self.text = hasNewMail and _G.HAVE_MAIL or _G.NONE
	end
end

-- ----------------------------------------------------------------------------
-- Framework.
-- ----------------------------------------------------------------------------
local CHARACTER_DATA_FIELD_MIGRATIONS = {
	auction_count = "auctionCount",
	last_update = "lastUpdateSeconds",
	mail_count = "mailCount",
	mail_entries = "mailEntries",
	next_expiration = "nextExpirationSeconds",
	sales_count = "salesCount",
}

local MAIL_DATA_FIELD_MIGRATIONS = {
	expiration_seconds = "expirationSeconds",
	package_icon = "packageIcon",
	sender_name = "senderName",
	stationary_icon = "stationaryIcon"
}

local function MigrateFieldNames(object, migrationTable)
	for oldField, newField in pairs(migrationTable) do
		if object[oldField] then
			object[newField] = object[oldField]
			object[object] = nil
		end
	end
end

function MailMinder:OnInitialize()
	local temp_db = LibStub("AceDB-3.0"):New(AddOnFolderName .. "DB", DB_DEFAULTS)
	db = temp_db.global

	if not db.characters[REALM_NAME] then
		db.characters[REALM_NAME] = {}
	end

	if not db.characters[REALM_NAME][PLAYER_NAME] then
		db.characters[REALM_NAME][PLAYER_NAME] = {
			mailEntries = {}
		}
	end

	local playerData = db.characters[REALM_NAME][PLAYER_NAME]
	local _, english_class = _G.UnitClass("player")

	playerData.class = english_class

	for _, characterList in pairs(db.characters) do
		for characterName, characterData in pairs(characterList) do
			sortedCharacterNames[#sortedCharacterNames + 1] = characterName

			-- Migrations
			MigrateFieldNames(characterData, CHARACTER_DATA_FIELD_MIGRATIONS)

			for index = 1, #characterData.mailEntries do
				MigrateFieldNames(characterData.mailEntries[index], MAIL_DATA_FIELD_MIGRATIONS)
			end
		end
	end
end

local function UpdateAll(eventName)
	UpdateInboxData()
	DataObject:Update(eventName .. "(UpdateAll)")
end

function MailMinder:OnEnable()
	_G.hooksecurefunc("SendMail", function(recipient, subject)
		if not recipient or not db.characters[REALM_NAME][recipient] then
			return
		end

		currentMail.recipient = recipient
		currentMail.subject = subject
		currentMail.is_cod = (_G.GetSendMailCOD() > 0) or nil
	end)

	if LDBIcon then
		LDBIcon:Register(AddOnFolderName, DataObject, db.datafeed.minimap_icon)
	end

	LibStub("AceEvent-3.0"):Embed(DataObject)
	DataObject:RegisterEvent("PLAYER_ENTERING_WORLD", "Update")
	DataObject:RegisterEvent("UPDATE_PENDING_MAIL", "Update")

	LibStub("AceTimer-3.0"):Embed(DataObject)
	DataObject:ScheduleRepeatingTimer("Update", 60, "RepeatingUpdate")

	self:RegisterEvent("MAIL_INBOX_UPDATE", UpdateAll)

	self:RegisterEvent("MAIL_SEND_SUCCESS")
end
