-- The Hangout window: a message pane with clickable links and an input box, plus
-- the invite prompt.

local _, ns = ...

local UI = {}
ns.UI = UI

local frame, messages, input, title, inviteFrame
local historyRendered = false
local sent, sentPos = {}, nil
local lastSound = 0
local lineCounter = 0

local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local TOOLTIP_LINKS = {
	item = true, quest = true, spell = true, achievement = true, enchant = true,
	talent = true, currency = true,
}

-- Run the text through the chat filters that other addons registered for channel
-- chat. That's how Twitch Emotes v2 (and similar addons) turn "peepoHappy" into a
-- picture, so room lines get the same treatment as normal chat.
-- Twitch Emotes only knows bare names ("kekw", "KEKW"). Its picker turns ":kekw:" into
-- "KEKW" as you type, so a hand-typed ":kekw:" would otherwise stay as text. Swap
-- ":name:" / ":name" for the bare name when Twitch Emotes knows it, leaving links alone.
local function bareEmoteNames(text)
	local known = type(TwitchEmotes_emoticons) == "table" and TwitchEmotes_emoticons
	if not known or not text:find(":", 1, true) then return text end
	local links = {}
	local out = text:gsub("|H.-|h.-|h", function(link)
		links[#links + 1] = link
		return "\001" .. #links .. "\001"
	end)
	local function swap(word)
		if known[":" .. word .. ":"] then return nil end -- some emotes really are spelled with colons
		if known[word] then return word end
		return nil
	end
	out = out:gsub(":([%w_]+):", swap)
	out = out:gsub("^:([%w_]+)", swap)
	out = out:gsub("(%s):([%w_]+)", function(space, word)
		local bare = swap(word)
		return bare and (space .. bare) or nil
	end)
	out = out:gsub("\001(%d+)\001", function(i) return links[tonumber(i)] end)
	return out
end

local function runChatFilters(text, sender)
	if not ns.db.emotes then return text end
	text = bareEmoteNames(text)
	lineCounter = lineCounter + 1
	local lineID = 1000000000 + lineCounter
	local chatFrame = DEFAULT_CHAT_FRAME
	local out = text
	if ChatFrameUtil and ChatFrameUtil.ProcessMessageEventFilters then
		local ok, _, result = pcall(ChatFrameUtil.ProcessMessageEventFilters, chatFrame, "CHAT_MSG_CHANNEL",
			text, sender, "", "Hangout", sender, "", 0, 0, "Hangout", 0, lineID, nil)
		if ok and ns.readable(result) then out = result end
	else
		local filters = ChatFrame_GetMessageEventFilters and ChatFrame_GetMessageEventFilters("CHAT_MSG_CHANNEL")
		for _, fn in ipairs(filters or {}) do
			local ok, discard, result = pcall(fn, chatFrame, "CHAT_MSG_CHANNEL",
				out, sender, "", "Hangout", sender, "", 0, 0, "Hangout", 0, lineID, nil)
			if ok and not discard and ns.readable(result) then out = result end
		end
	end
	-- If no filter changed anything, ask Twitch Emotes directly (in case it hooks chat another way).
	if out == text and type(Emoticons_RunReplacement) == "function" then
		local ok, result = pcall(Emoticons_RunReplacement, text, nil, lineID)
		if ok and ns.readable(result) then out = result end
	end
	return out
end

local function nameLink(name, class)
	local display = ("[|c%s%s|r]"):format(ns.classHex(class), name)
	if GetPlayerLink then
		local ok, link = pcall(GetPlayerLink, name, display)
		if ok and type(link) == "string" then return link end
	end
	return display
end

local function formatLine(name, class, text, t)
	return ("|cff9d9d9d%s|r %s: %s"):format(date("%H:%M", t), nameLink(name, class), runChatFilters(text, name))
end

local function savePosition()
	local point, _, relPoint, x, y = frame:GetPoint()
	ns.db.pos = { point, relPoint, x, y }
	ns.db.size = { frame:GetWidth(), frame:GetHeight() }
end

local function memberTooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
	local r = ns.Room.get()
	if not r then
		GameTooltip:SetText("Hangout")
		GameTooltip:AddLine("Not in a room. /ho create <name>", 1, 1, 1, true)
	else
		GameTooltip:SetText(r.name)
		for _, m in ipairs(ns.Room.members()) do
			local state = m.me and "you" or (m.online and "online" or "offline")
			local shade = m.online and 1 or 0.5
			GameTooltip:AddDoubleLine(("|c%s%s|r"):format(ns.classHex(m.class), m.name), state, 1, 1, 1, shade, shade, shade)
		end
	end
	GameTooltip:Show()
end

local function setupInput()
	input = CreateFrame("EditBox", "HangoutInputBox", frame, "InputBoxTemplate")
	input:SetPoint("BOTTOMLEFT", 16, 8)
	input:SetPoint("BOTTOMRIGHT", -26, 8)
	input:SetHeight(20)
	input:SetAutoFocus(false)
	input:SetFontObject(ChatFontNormal)
	input:SetMaxBytes(1200)
	input:SetAltArrowKeyMode(false)
	input:SetScript("OnEnterPressed", function(self)
		local text = self:GetText()
		if text and strtrim(text) ~= "" then
			ns.Room.say(text)
			sent[#sent + 1] = text
			if #sent > 30 then table.remove(sent, 1) end
		end
		sentPos = nil
		self:SetText("")
	end)
	input:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	input:SetScript("OnArrowPressed", function(self, key)
		-- Leave the arrows to the Twitch Emotes picker while it's open.
		if EditBoxAutoCompleteBox and EditBoxAutoCompleteBox:IsShown() and EditBoxAutoCompleteBox.parent == self then return end
		if #sent == 0 then return end
		if key == "UP" then
			sentPos = sentPos and math.max(1, sentPos - 1) or #sent
			self:SetText(sent[sentPos])
		elseif key == "DOWN" and sentPos then
			sentPos = sentPos + 1
			if sentPos > #sent then
				sentPos = nil
				self:SetText("")
			else
				self:SetText(sent[sentPos])
			end
		end
	end)
end

local function create()
	if frame then return end

	frame = CreateFrame("Frame", "HangoutFrame", UIParent, "BackdropTemplate")
	frame:SetBackdrop(BACKDROP)
	frame:SetBackdropColor(0.04, 0.04, 0.06, 0.85)
	frame:SetBackdropBorderColor(0.6, 0.48, 0.36, 1)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then frame:SetResizeBounds(260, 140, 1000, 800) end
	frame:EnableMouse(true)
	local size = ns.db.size
	frame:SetSize(size and size[1] or 430, size and size[2] or 250)
	local pos = ns.db.pos
	if pos then
		frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
	end
	frame:Hide()

	local bar = CreateFrame("Frame", nil, frame)
	bar:SetPoint("TOPLEFT", 4, -4)
	bar:SetPoint("TOPRIGHT", -28, -4)
	bar:SetHeight(20)
	bar:EnableMouse(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function() frame:StartMoving() end)
	bar:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		savePosition()
	end)
	bar:SetScript("OnEnter", memberTooltip)
	bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

	title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", 6, 0)
	title:SetPoint("RIGHT", -4, 0)
	title:SetJustifyH("LEFT")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function() UI.hide() end)

	messages = CreateFrame("ScrollingMessageFrame", nil, frame)
	messages:SetPoint("TOPLEFT", 10, -26)
	messages:SetPoint("BOTTOMRIGHT", -10, 34)
	messages:SetFontObject(ChatFontNormal)
	messages:SetJustifyH("LEFT")
	messages:SetFading(false)
	messages:SetMaxLines(500)
	messages:SetIndentedWordWrap(true)
	messages:SetHyperlinksEnabled(true)
	messages:EnableMouseWheel(true)
	messages:SetScript("OnMouseWheel", function(self, delta)
		if IsShiftKeyDown() then
			if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
		else
			self:ScrollByAmount(delta * 3)
		end
	end)
	messages:SetScript("OnHyperlinkClick", function(_, link, text, button)
		SetItemRef(link, text, button, nil)
	end)
	messages:SetScript("OnHyperlinkEnter", function(self, link)
		local kind = type(link) == "string" and link:match("^(%a+):")
		if not (kind and TOOLTIP_LINKS[kind]) then return end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then
			GameTooltip:Show()
		else
			GameTooltip:Hide()
		end
	end)
	messages:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)

	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		savePosition()
	end)

	setupInput()
end

-- Shift-clicking an item, quest or chat link calls ChatFrameUtil.InsertLink. Blizzard's
-- version only knows its own boxes, so when ours has focus, put the link here too.
local function hookLinkInsertion()
	local function insert(text)
		if input and input:HasFocus() and ns.readable(text) then input:Insert(text) end
	end
	if ChatFrameUtil and ChatFrameUtil.InsertLink then
		hooksecurefunc(ChatFrameUtil, "InsertLink", insert)
	elseif ChatEdit_InsertLink then
		hooksecurefunc("ChatEdit_InsertLink", insert)
	end
end

-- Give the Hangout box the same ":" emote picker Twitch Emotes adds to chat boxes.
local function attachEmotePicker()
	if input.hangoutPicker then return end
	if type(SetupAutoComplete) ~= "function" or type(AllTwitchEmoteNames) ~= "table" or not EditBoxAutoCompleteBox then return end
	if type(Emoticons_Settings) == "table" and not Emoticons_Settings.ENABLE_AUTOCOMPLETE then return end
	local settings = {
		perWord = true,
		activationChar = ":",
		closingChar = ":",
		minChars = 2,
		fuzzyMatch = true,
		onSuggestionApplied = function(suggestion)
			if type(UpdateEmoteStats) == "function" then pcall(UpdateEmoteStats, suggestion, true, false, false) end
		end,
		renderSuggestionFN = Emoticons_RenderSuggestionFN,
		suggestionBiasFN = function(suggestion)
			local stats = type(TwitchEmoteStatistics) == "table" and TwitchEmoteStatistics[suggestion]
			return stats and stats[1] and stats[1] * 5 or 0
		end,
		interceptOnEnterPressed = true,
		addSpace = true,
		useTabToConfirm = type(Emoticons_Settings) == "table" and Emoticons_Settings.AUTOCOMPLETE_CONFIRM_WITH_TAB or false,
		useArrowButtons = true,
	}
	local ok, err = pcall(SetupAutoComplete, input, AllTwitchEmoteNames, 20, settings)
	if ok then
		input.hangoutPicker = true
	else
		ns.debug("couldn't add the emote picker: %s", tostring(err))
	end
end

local function renderHistory()
	if historyRendered then return end
	historyRendered = true
	create()
	local h = ns.char.history
	if #h == 0 then return end
	-- BackFillMessage adds to the old end, so go newest-first.
	messages:BackFillMessage("|cff6f6f6f---- earlier ----|r")
	for i = #h, 1, -1 do
		local e = h[i]
		messages:BackFillMessage(formatLine(e.n, e.c, e.x, e.t), ns.R * 0.8, ns.G * 0.8, ns.B * 0.8)
	end
end

function UI.refresh()
	if not title then return end
	local r = ns.Room.get()
	if not r then
		title:SetText("Hangout  |cff9d9d9d- not in a room (/ho create <name>)|r")
	else
		local n = ns.Room.onlineCount()
		local who = n == 0 and "nobody else online" or (n == 1 and "1 friend online" or (n .. " friends online"))
		title:SetText(("Hangout  |c%s%s|r  |cff9d9d9d%s|r"):format(ns.HEX, r.name, who))
	end
end

function UI.chat(name, class, text, t, mine)
	create()
	local line = formatLine(name, class, text, t)
	messages:AddMessage(line, ns.R, ns.G, ns.B)
	local shown = frame:IsShown()
	local echo = ns.db.echo
	if echo == "always" or (echo == "auto" and not shown) then
		DEFAULT_CHAT_FRAME:AddMessage(("|c%s[Hangout]|r %s"):format(ns.HEX, line), ns.R, ns.G, ns.B)
	end
	if not mine and not shown and ns.db.sound and GetTime() - lastSound > 8 then
		lastSound = GetTime()
		if SOUNDKIT and SOUNDKIT.TELL_MESSAGE then PlaySound(SOUNDKIT.TELL_MESSAGE) end
	end
end

function UI.note(text)
	if not ns.db then return end
	create()
	messages:AddMessage("|cff9d9d9d" .. text .. "|r")
end

function UI.show()
	create()
	frame:Show()
	ns.db.shown = true
	UI.refresh()
end

function UI.hide()
	if frame then frame:Hide() end
	if ns.db then ns.db.shown = false end
end

function UI.toggle()
	create()
	if frame:IsShown() then UI.hide() else UI.show() end
end

function UI.focus()
	UI.show()
	input:SetFocus()
end

function UI.resetPosition()
	ns.db.pos, ns.db.size = nil, nil
	if frame then
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
		frame:SetSize(430, 250)
	end
end

-- Invite prompt -------------------------------------------------------------------

local function createInvite()
	inviteFrame = CreateFrame("Frame", "HangoutInviteFrame", UIParent, "BackdropTemplate")
	inviteFrame:SetBackdrop(BACKDROP)
	inviteFrame:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
	inviteFrame:SetBackdropBorderColor(0.6, 0.48, 0.36, 1)
	inviteFrame:SetSize(340, 104)
	inviteFrame:SetPoint("TOP", UIParent, "TOP", 0, -160)
	inviteFrame:SetFrameStrata("DIALOG")
	inviteFrame:EnableMouse(true)
	inviteFrame:Hide()

	local text = inviteFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("TOP", 0, -14)
	text:SetWidth(310)
	text:SetJustifyH("CENTER")
	inviteFrame.text = text

	local yes = CreateFrame("Button", nil, inviteFrame, "UIPanelButtonTemplate")
	yes:SetSize(120, 22)
	yes:SetPoint("BOTTOMRIGHT", inviteFrame, "BOTTOM", -6, 12)
	yes:SetText("Join")
	yes:SetScript("OnClick", function()
		local d = inviteFrame.data
		inviteFrame:Hide()
		if d then ns.Room.acceptInvite(d.from, d.id, d.name) end
	end)

	local no = CreateFrame("Button", nil, inviteFrame, "UIPanelButtonTemplate")
	no:SetSize(120, 22)
	no:SetPoint("BOTTOMLEFT", inviteFrame, "BOTTOM", 6, 12)
	no:SetText("No thanks")
	no:SetScript("OnClick", function()
		local d = inviteFrame.data
		inviteFrame:Hide()
		if d then ns.Room.declineInvite(d.from, d.id) end
	end)
end

function UI.showInvite(from, id, name)
	if not inviteFrame then createInvite() end
	if inviteFrame:IsShown() then return end -- one prompt at a time
	if name == "" then name = "Hangout" end
	local current = ns.Room.get()
	local extra = current and ("\n|cff9d9d9d(You'll leave %s.)|r"):format(current.name) or ""
	inviteFrame.text:SetText(("%s invites you to the Hangout room |c%s%s|r.%s"):format(from, ns.HEX, name, extra))
	local data = { from = from, id = id, name = name }
	inviteFrame.data = data
	inviteFrame:Show()
	if SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE then PlaySound(SOUNDKIT.IG_PLAYER_INVITE) end
	C_Timer.After(120, function()
		if inviteFrame.data == data and inviteFrame:IsShown() then inviteFrame:Hide() end
	end)
end

-- Key bindings (Options > Keybindings > AddOns > Hangout)
BINDING_HEADER_HANGOUT = "Hangout"
BINDING_NAME_HANGOUT_TOGGLE = "Show or hide the Hangout window"
BINDING_NAME_HANGOUT_FOCUS = "Type in Hangout"

function Hangout_Toggle()
	UI.toggle()
end

function Hangout_Focus()
	-- Wait a frame so the key press itself doesn't get typed into the box.
	C_Timer.After(0, UI.focus)
end

ns.on("HANGOUT_LOGIN", function()
	create()
	hookLinkInsertion()
	UI.refresh()
	if ns.db.shown then UI.show() end
	-- Let Twitch Emotes finish loading before drawing old lines with emotes.
	C_Timer.After(2, function()
		attachEmotePicker()
		renderHistory()
	end)
end)
