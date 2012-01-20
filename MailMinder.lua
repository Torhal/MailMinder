-------------------------------------------------------------------------------
-- Localized Lua globals.
-------------------------------------------------------------------------------
local _G = getfenv(0)

local math = _G.math
local string = _G.string
local table = _G.table

local pairs = _G.pairs

-------------------------------------------------------------------------------
-- Addon namespace.
-------------------------------------------------------------------------------
local ADDON_NAME, private = ...
local LibStub = _G.LibStub
local MailMinder = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceEvent-3.0")

local QTip = LibStub("LibQTip-1.0")
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")
local L = LibStub("AceLocale-3.0"):GetLocale(ADDON_NAME)

local ldb_object = LDB:NewDataObject(ADDON_NAME, {
	type = "data source",
	label = ADDON_NAME,
	text = " ",
	icon = [[Interface\MINIMAP\TRACKING\Mailbox]],
})

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local PLAYER_NAME = _G.UnitName("player")
local REALM_NAME = _G.GetRealmName()
local SECONDS_PER_DAY = 24 * 60 * 60
local SECONDS_PER_HOUR = 60 * 60

local COLOR_TABLE = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS
local CLASS_COLORS = {}

for k, v in pairs(COLOR_TABLE) do
	CLASS_COLORS[k] = ("%2x%2x%2x"):format(v.r * 255, v.g * 255, v.b * 255)
end

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
local ICON_PLUS = [[|TInterface\MINIMAP\UI-Minimap-ZoomInButton-Up:16:16|t]]

-------------------------------------------------------------------------------
-- Variables.
-------------------------------------------------------------------------------
local characters = {}
local sorted_characters = {}
local current_mail = {}
local db

-------------------------------------------------------------------------------
-- Helper functions.
-------------------------------------------------------------------------------
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

-------------------------------------------------------------------------------
-- LDB methods.
-------------------------------------------------------------------------------
local DrawTooltip
do
	local NUM_TOOLTIP_COLUMNS = 7
	local tooltip
	local LDB_anchor

	local function Tooltip_OnRelease(self)
		tooltip = nil
		LDB_anchor = nil
	end

	local function ToggleExpandedState(tooltip_cell, realm_and_character)
		local realm, character_name = (":"):split(realm_and_character, 2)

		db.characters[realm][character_name].expanded = not db.characters[realm][character_name].expanded
		DrawTooltip(LDB_anchor)
	end

	function DrawTooltip(anchor_frame)
		if not anchor_frame then
			return
		end
		LDB_anchor = anchor_frame

		if not tooltip then
			tooltip = QTip:Acquire(ADDON_NAME .. "Tooltip", NUM_TOOLTIP_COLUMNS, "LEFT", "CENTER", "CENTER", "CENTER", "CENTER", "CENTER", "CENTER")
			tooltip.OnRelease = Tooltip_OnRelease
			tooltip:EnableMouse(true)
			tooltip:SmartAnchorTo(anchor_frame)
			tooltip:SetAutoHideDelay(db.tooltip.timer, anchor_frame)
			tooltip:SetScale(db.tooltip.scale)
		end
		local now = _G.time()

		tooltip:Clear()
		tooltip:SetCellMarginH(0)
		tooltip:SetCellMarginV(1)

		local line, column = tooltip:AddHeader()
		tooltip:SetCell(line, 1, ADDON_NAME, "CENTER", NUM_TOOLTIP_COLUMNS)
		tooltip:AddSeparator()

		line = tooltip:AddLine(" ", _G.NAME, _G.CLOSES_IN, _G.MAIL_LABEL, _G.AUCTIONS)
		tooltip:SetLineColor(line, 1, 1, 1, 0.25)
		tooltip:AddSeparator()

		for realm, character_info in pairs(db.characters) do
			for character_name, data in pairs(character_info) do
				if #data.mail_entries > 0 then
					local class_color = data.class and CLASS_COLORS[data.class] or "cccccc"
					local expiration_seconds = data.next_expiration - (now - data.last_update)

					line = tooltip:AddLine()
					tooltip:SetCell(line, 1, data.expanded and ICON_MINUS or ICON_PLUS)
					tooltip:SetCell(line, 2, ("|cff%s%s|r"):format(class_color, character_name))

					if expiration_seconds / SECONDS_PER_DAY >= 1 then
						tooltip:SetCell(line, 3, ("%s%s|r"):format(_G.GREEN_FONT_COLOR_CODE, FormattedSeconds(expiration_seconds)))
					else
						tooltip:SetCell(line, 3, ("%s%s|r"):format(_G.RED_FONT_COLOR_CODE, FormattedSeconds(expiration_seconds)))
					end
					tooltip:SetCell(line, 4, data.mail_count)
					tooltip:SetCell(line, 5, data.auction_count)
					tooltip:SetCellScript(line, 1, "OnMouseUp", ToggleExpandedState, ("%s:%s"):format(realm, character_name))

					if data.expanded then
						tooltip:AddSeparator()
						line = tooltip:AddLine(" ")
						tooltip:SetLineColor(line, 1, 1, 1, 0.25)
						tooltip:SetCell(line, 2, _G.MAIL_SUBJECT_LABEL, "CENTER", 4)
						tooltip:SetCell(line, 6, _G.FROM)
						tooltip:SetCell(line, 7, _G.CLOSES_IN)
						tooltip:AddSeparator()

						for index = 1, #data.mail_entries do
							local mail = data.mail_entries[index]
							local expiration_seconds = mail.expiration_seconds - (now - data.last_update)
							line = tooltip:AddLine(" ")
							tooltip:SetCell(line, 2, ("|T%s:16:16|t %s%s|r"):format(mail.package_icon or mail.stationary_icon, _G.NORMAL_FONT_COLOR_CODE, mail.subject), "LEFT", 4)
							tooltip:SetCell(line, 6, mail.sender_name)

							if expiration_seconds / SECONDS_PER_DAY >= 1 then
								tooltip:SetCell(line, 7, ("%s%s|r"):format(_G.GREEN_FONT_COLOR_CODE, FormattedSeconds(expiration_seconds)))
							else
								tooltip:SetCell(line, 7, ("%s%s|r"):format(_G.RED_FONT_COLOR_CODE, FormattedSeconds(expiration_seconds)))
							end
						end
						tooltip:AddSeparator()
					end
				end
			end
		end
		tooltip:Show()
	end

	function ldb_object:OnEnter()
		DrawTooltip(self)
	end

	function ldb_object:OnLeave()
	end

	function ldb_object:OnClick()
	end
end -- do-block

-------------------------------------------------------------------------------
-- Events.
-------------------------------------------------------------------------------
function MailMinder:MAIL_INBOX_UPDATE()
	if not _G.MailFrame:IsVisible() then
		return
	end
	local auction_count = 0
	local mail_count = _G.GetInboxNumItems()
	local player_data = db.characters[REALM_NAME][PLAYER_NAME]
	local remaining_days = 42
	local sales_count = 0

	table.wipe(player_data.mail_entries)

	for index = 1, mail_count do
		local invoice_type = _G.GetInboxInvoiceInfo(index)
		local package_icon, stationary_icon, sender_name, subject, _, _, days_left = _G.GetInboxHeaderInfo(index)

		if _G.type(days_left) ~= "number" then
			-- if its not a valid value, set to 42.
			days_left = 42
		end

		if invoice_type == "seller_temp_invoice" then
			if (days_left + 31) < remaining_days then
				remaining_days = days_left + 31
			end
			sales_count = sales_count + 1
			auction_count = auction_count + 1
		else
			if days_left < remaining_days then
				remaining_days = days_left
			end

			if invoice_type == "buyer" or invoice_type == "seller" or subject:match(L["Auction expired"]) then
				auction_count = auction_count + 1
			end
		end

		table.insert(player_data.mail_entries, {
			expiration_seconds = math.floor(days_left * SECONDS_PER_DAY),
			package_icon = package_icon,
			sender_name = sender_name,
			stationary_icon = stationary_icon,
			subject = subject,
		})
	end
	player_data.last_update = _G.time()
	player_data.mail_count = mail_count
	player_data.sales_count = sales_count
	player_data.auction_count = auction_count
	player_data.next_expiration = math.floor(remaining_days * SECONDS_PER_DAY)
end

function MailMinder:MAIL_SEND_SUCCESS()
	local mail_expiration_seconds = math.floor((current_mail.is_cod and 4 or 31) * SECONDS_PER_DAY)
	local now = _G.time()
	local character_data = db.characters[REALM_NAME][current_mail.recipient]

	local new_mail = {
		expiration_seconds = mail_expiration_seconds,
		sender_name = PLAYER_NAME,
		stationary_icon = DEFAULT_STATIONARY,
		subject = current_mail.subject,
	}

	if not character_data then
		db.characters[REALM_NAME][current_mail.recipient] = {
			next_expiration = mail_expiration_seconds,
			last_update = now,
			mail_count = 1,
			mail_entries = {
				new_mail
			}
		}
		return
	end

	if mail_expiration_seconds < math.floor(character_data.next_expiration) - (now - character_data.last_update) then
		character_data.next_expiration = mail_expiration_seconds
		character_data.last_update = now
	end
	table.insert(character_data.mail_entries, new_mail)
	character_data.mail_count = character_data.mail_count + 1
end

-------------------------------------------------------------------------------
-- Framework.
-------------------------------------------------------------------------------
function MailMinder:OnInitialize()
	local temp_db = LibStub("AceDB-3.0"):New(ADDON_NAME .. "DB", DB_DEFAULTS)
	db = temp_db.global

	if not db.characters[REALM_NAME] then
		db.characters[REALM_NAME] = {}
	end

	if not db.characters[REALM_NAME][PLAYER_NAME] then
		db.characters[REALM_NAME][PLAYER_NAME] = {
			mail_entries = {}
		}
	end
	local player_data = db.characters[REALM_NAME][PLAYER_NAME]
	local _, english_class = _G.UnitClass("player")
	player_data.class = english_class

	for realm_name, character_info in pairs(db.characters) do
		for character_name, data in pairs(character_info) do
			characters[character_name] = data
			sorted_characters[#sorted_characters + 1] = character_name
		end
	end
end

function MailMinder:OnEnable()
	_G.hooksecurefunc("SendMail", function(recipient, subject, body)
		if not db.characters[REALM_NAME][recipient] then
			return
		end
		current_mail.recipient = recipient
		current_mail.subject = subject
		current_mail.is_cod = (_G.GetSendMailCOD() > 0) or nil
	end)

	if LDBIcon then
		LDBIcon:Register(ADDON_NAME, ldb_object, db.datafeed.minimap_icon)
	end

	self:RegisterEvent("MAIL_INBOX_UPDATE")
	self:RegisterEvent("MAIL_SEND_SUCCESS")
end
