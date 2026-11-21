-- The Hangout window: a tab per room, the message pane with clickable links and the
-- input box, plus the little box it minimizes into, the invite prompt and the
-- unread/alert bookkeeping.

local _, ns = ...

local UI = {}
ns.UI = UI

local frame, messages, input, title, subtitle, inviteFrame, mini
local tabStrip, inviteButton, settings, settingsRefresh
local create, renderRoom   -- defined further down, used by the settings panel above
local tabs = {}
local unread = {}           -- roomId -> lines you haven't looked at
local shownRoom             -- whose history is currently drawn in the pane
local sent, sentPos = {}, nil
local lastSound = 0
local lineCounter = 0
local menuFrame

local TAB_HEIGHT = 20

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

local function formatLine(name, class, text, t, body)
	return ("|cff9d9d9d%s|r %s: %s"):format(date("%H:%M", t), nameLink(name, class), body or runChatFilters(text, name))
end
UI.formatLine = formatLine

-- The way the normal chat draws a channel line: "[Night Owls] Boa Woa: raid at 8".
-- No timestamp of our own, so it matches whatever your chat settings already do, and
-- the room name is a link that brings that room to the front.
local function channelLine(roomId, name, class, text, body)
	local r = ns.Room.get(roomId)
	local label = r and r.name or "Hangout"
	local tag
	if roomId then
		tag = ("|c%s|Hhangout:%s|h[%s]|h|r"):format(ns.HEX, roomId, label)
	else
		tag = ("|c%s[%s]|r"):format(ns.HEX, label)
	end
	return ("%s |c%s%s|r: %s"):format(tag, ns.classHex(class), name, body or runChatFilters(text, name))
end

-- Clicking the room name in a chat line switches to that room.
local function hookRoomLinks()
	if type(hooksecurefunc) ~= "function" or type(SetItemRef) ~= "function" then return end
	hooksecurefunc("SetItemRef", function(link)
		local id = type(link) == "string" and link:match("^hangout:(.+)$")
		local r = id and ns.Room.get(id)
		if r and ns.Room.activeId() ~= id then
			UI.selectRoom(id)
			ns.print(("Now talking in %s."):format(r.name))
		end
	end)
end

-- A right-click menu, however this client builds them.
local function contextMenu(owner, entries)
	if MenuUtil and MenuUtil.CreateContextMenu then
		local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
			for _, e in ipairs(entries) do
				if e.title then root:CreateTitle(e.text) else root:CreateButton(e.text, e.fn) end
			end
		end)
		if ok then return true end
	end
	if type(UIDropDownMenu_Initialize) == "function" and type(ToggleDropDownMenu) == "function" then
		menuFrame = menuFrame or CreateFrame("Frame", "HangoutContextMenu", UIParent, "UIDropDownMenuTemplate")
		local ok = pcall(function()
			UIDropDownMenu_Initialize(menuFrame, function()
				for _, e in ipairs(entries) do
					local info = UIDropDownMenu_CreateInfo()
					info.text = e.text
					info.notCheckable = true
					info.isTitle = e.title and true or nil
					info.disabled = e.title and true or nil
					info.func = e.fn
					UIDropDownMenu_AddButton(info)
				end
			end, "MENU")
			ToggleDropDownMenu(1, nil, menuFrame, "cursor", 0, 0)
		end)
		if ok then return true end
	end
	return false
end

-- Popups ---------------------------------------------------------------------------

local function popupEditText(dialog)
	local box = dialog and (dialog.editBox or (dialog.GetName and _G[(dialog:GetName() or "") .. "EditBox"]))
	return box and box:GetText() or ""
end

local function registerPopups()
	if type(StaticPopupDialogs) ~= "table" then return end
	StaticPopupDialogs["HANGOUT_CREATE_ROOM"] = {
		text = "Name the new Hangout room:",
		button1 = "Create", button2 = CANCEL or "Cancel",
		hasEditBox = true, maxLetters = 24,
		timeout = 0, whileDead = true, hideOnEscape = true,
		OnAccept = function(dialog) ns.Room.create(popupEditText(dialog)) end,
		EditBoxOnEnterPressed = function(box)
			local dialog = box:GetParent()
			ns.Room.create(box:GetText())
			if dialog and dialog.Hide then dialog:Hide() end
		end,
		EditBoxOnEscapePressed = function(box) local d = box:GetParent() if d and d.Hide then d:Hide() end end,
	}
	StaticPopupDialogs["HANGOUT_INVITE"] = {
		text = "Invite who to %s?\n|cff9d9d9dFirst and last name. They need Hangout too.|r",
		button1 = "Invite", button2 = CANCEL or "Cancel",
		hasEditBox = true, maxLetters = 48,
		timeout = 0, whileDead = true, hideOnEscape = true,
		OnAccept = function(dialog, roomId) ns.Room.invite(popupEditText(dialog), roomId) end,
		EditBoxOnEnterPressed = function(box, roomId)
			local dialog = box:GetParent()
			ns.Room.invite(box:GetText(), roomId)
			if dialog and dialog.Hide then dialog:Hide() end
		end,
		EditBoxOnEscapePressed = function(box) local d = box:GetParent() if d and d.Hide then d:Hide() end end,
	}
end

function UI.promptCreateRoom()
	if type(StaticPopup_Show) == "function" and type(StaticPopupDialogs) == "table" then
		StaticPopup_Show("HANGOUT_CREATE_ROOM")
	else
		ns.print("Start a room with |cffffffff/ho create <name>|r")
	end
end

-- Ask who to invite, prefilled with your target if you have one.
function UI.promptInvite(roomId)
	local r = ns.Room.get(roomId)
	if not r then
		ns.print("Create a room first: |cffffffff/ho create <name>|r")
		return
	end
	if type(StaticPopup_Show) ~= "function" or type(StaticPopupDialogs) ~= "table" then
		ns.print("Invite with |cffffffff/ho invite First Last|r")
		return
	end
	local dialog = StaticPopup_Show("HANGOUT_INVITE", r.name, nil, r.id)
	local target = UnitIsPlayer("target") and ns.unitFullName("target")
	if dialog and target then
		local box = dialog.editBox or _G[(dialog:GetName() or "") .. "EditBox"]
		if box then
			box:SetText(target)
			box:HighlightText()
		end
	end
end

-- Tabs -----------------------------------------------------------------------------

local function tabMenu(roomId, owner)
	local r = ns.Room.get(roomId)
	if not r then return end
	local shown = contextMenu(owner or tabs[1], {
		{ text = r.name, title = true },
		{ text = "Invite someone", fn = function() UI.promptInvite(roomId) end },
		{ text = "Who's here", fn = function() ns.Commands.who(roomId) end },
		{ text = "Leave this room", fn = function() ns.Room.leave(roomId) end },
	})
	if not shown then
		ns.print(("%s: |cffffffff/ho invite <name>|r, |cffffffff/ho who|r, |cffffffff/ho leave|r"):format(r.name))
	end
end

local function makeTab(index)
	local tab = CreateFrame("Button", nil, tabStrip)
	tab:SetHeight(TAB_HEIGHT)
	tab:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	local bg = tab:CreateTexture(nil, "BACKGROUND")
	if bg then
		bg:SetAllPoints()
		if bg.SetColorTexture then bg:SetColorTexture(1, 1, 1, 1) end
	end
	tab.bg = bg

	local label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", 7, 0)
	label:SetPoint("RIGHT", -7, 0)
	label:SetJustifyH("CENTER")
	tab.label = label

	tab:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			tabMenu(self.roomId, self)
		elseif self.plus then
			UI.promptCreateRoom()
		else
			UI.selectRoom(self.roomId)
		end
	end)
	tab:SetScript("OnEnter", function(self)
		if not self.roomId then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		local r = ns.Room.get(self.roomId)
		if r then
			GameTooltip:SetText(r.name)
			local n = ns.Room.onlineCount(self.roomId)
			GameTooltip:AddLine(("%d of %d here"):format(n + 1, #ns.Room.members(self.roomId)), 1, 1, 1)
			GameTooltip:AddLine("Right-click for invite, who, leave.", 0.6, 0.6, 0.6, true)
			GameTooltip:Show()
		end
	end)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
	tabs[index] = tab
	return tab
end

local function layoutTabs()
	if not tabStrip then return end
	local list = ns.Room.ordered()
	local activeId = ns.Room.activeId()
	local x, index = 0, 0

	-- Share out the strip so eight tabs still fit instead of running off the edge.
	local avail = tabStrip:GetWidth() or 0
	if avail < 60 then avail = (frame:GetWidth() or 470) - 20 end
	avail = avail - 26 -- leave room for the "+" tab
	local budget = #list > 0 and math.max(44, math.floor(avail / #list) - 3) or 44
	local maxChars = math.max(4, math.floor((budget - 18) / 6))

	for i, r in ipairs(list) do
		index = i
		local tab = tabs[index] or makeTab(index)
		local name = r.name
		if #name > maxChars then name = name:sub(1, maxChars - 1) .. "-" end
		local count = unread[r.id] or 0
		local badge = ""
		if count > 0 and ns.db.alerts.badge then
			badge = ("  |cffff5555%s|r"):format(count > 99 and "99+" or tostring(count))
		end
		local isActive = r.id == activeId
		tab.roomId, tab.plus = r.id, nil
		tab.label:SetText((isActive and ("|c" .. ns.HEX .. name .. "|r") or ("|cffb0b0b0" .. name .. "|r")) .. badge)
		tab:SetWidth(math.min(math.max(50, (tab.label:GetStringWidth() or 40) + 18), budget))
		tab:ClearAllPoints()
		tab:SetPoint("LEFT", tabStrip, "LEFT", x, 0)
		if tab.bg and tab.bg.SetColorTexture then
			if isActive then
				tab.bg:SetColorTexture(0.34, 0.26, 0.17, 0.95)
			else
				tab.bg:SetColorTexture(0.12, 0.12, 0.14, 0.75)
			end
		end
		tab:Show()
		x = x + tab:GetWidth() + 3
	end

	-- the "+" tab for starting another room
	if #list < ns.Room.MAX_ROOMS then
		index = index + 1
		local plus = tabs[index] or makeTab(index)
		plus.roomId, plus.plus = nil, true
		plus.label:SetText("|cff9d9d9d+|r")
		plus:SetWidth(22)
		plus:ClearAllPoints()
		plus:SetPoint("LEFT", tabStrip, "LEFT", x, 0)
		if plus.bg and plus.bg.SetColorTexture then plus.bg:SetColorTexture(0.12, 0.12, 0.14, 0.75) end
		plus:Show()
	end

	for i = index + 1, #tabs do tabs[i]:Hide() end
end

-- Members (the list lives in the title-bar tooltip and /ho who) ------------------

local function memberTooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
	local r = ns.Room.get()
	if not r then
		GameTooltip:SetText("Hangout")
		GameTooltip:AddLine("Not in a room. /ho create <name>", 1, 1, 1, true)
	else
		GameTooltip:SetText(r.name)
		for _, m in ipairs(ns.Room.members(r.id)) do
			local state = m.me and "you" or (m.online and "online" or "offline")
			local shade = m.online and 1 or 0.5
			GameTooltip:AddDoubleLine(("|c%s%s|r"):format(ns.classHex(m.class), m.name), state, 1, 1, 1, shade, shade, shade)
		end
	end
	GameTooltip:Show()
end

-- The window -----------------------------------------------------------------------

local function savePosition()
	local point, _, relPoint, x, y = frame:GetPoint()
	ns.db.pos = { point, relPoint, x, y }
	ns.db.size = { frame:GetWidth(), frame:GetHeight() }
end

-- Animated emotes.
--
-- Twitch Emotes draws an animated emote as one frame of a sprite sheet, and rewrites
-- the coordinates in every visible line about 30 times a second to advance it. Its own
-- loop (TwitchEmotesAnimator_OnUpdate) only walks Blizzard's CHAT_FRAMES, so a line in
-- our pane would sit on frame one forever. Run the same update over our lines instead.
local animElapsed, animLines, animScanAt = 0, nil, 0

local function emoteLines(pane)
	if pane.visibleLines then return pane.visibleLines end
	-- No visibleLines on this client: the line font strings are regions of the frame.
	-- They get reused, so looking them up occasionally is enough.
	local now = GetTime()
	if animLines and now - animScanAt < 2 then return animLines end
	animScanAt = now
	animLines = {}
	for _, region in ipairs({ pane:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "FontString" then
			animLines[#animLines + 1] = region
		end
	end
	return animLines
end

-- Only runs while the window is open: OnUpdate doesn't fire on a hidden frame.
local function animateEmotes(pane, elapsed)
	if not ns.db or not ns.db.emotes then return end
	local update = TwitchEmotesAnimator_UpdateEmoteInFontString
	if type(update) ~= "function" then return end
	-- Twitch Emotes has its own switch for this; don't animate when it's off.
	if type(Emoticons_Settings) == "table" and Emoticons_Settings.ENABLE_ANIMATEDEMOTES == false then return end
	animElapsed = animElapsed + (elapsed or 0)
	if animElapsed < 0.033 then return end
	animElapsed = 0
	for _, line in ipairs(emoteLines(pane)) do
		-- Leave the line under the cursor alone, so its tooltip doesn't jump.
		if line.messageInfo == nil or line.messageInfo ~= TwitchEmotes_HoverMessageInfo then
			pcall(update, line, 28, 28)
		end
	end
end

-- Minimized: the window folds into a small box that pulses when a line arrives.

local function updateMini()
	if not mini then return end
	local r = ns.Room.get()
	local name = r and r.name or "Hangout"
	if #name > 12 then name = name:sub(1, 11) .. "-" end
	local total = UI.unreadCount()
	local badge = ""
	if total > 0 then
		badge = ("  |cffff5555%s|r"):format(total > 99 and "99+" or tostring(total))
	end
	mini.label:SetText(("|c%s%s|r%s"):format(ns.HEX, name, badge))
end

local function stopFlash()
	if not mini then return end
	mini.flashing = false
	if mini.glow and mini.glow.SetAlpha then mini.glow:SetAlpha(0) end
end

local function startFlash()
	if not mini then return end
	mini.flashing = true
	mini.phase = 0
end

local function createMini()
	if mini then return end
	mini = CreateFrame("Button", "HangoutMiniFrame", UIParent, "BackdropTemplate")
	mini:SetBackdrop(BACKDROP)
	mini:SetBackdropColor(0.04, 0.04, 0.06, 0.9)
	mini:SetBackdropBorderColor(0.6, 0.48, 0.36, 1)
	mini:SetSize(136, 26)
	mini:SetFrameStrata("MEDIUM")
	mini:SetClampedToScreen(true)
	mini:SetMovable(true)
	mini:EnableMouse(true)
	mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	mini:RegisterForDrag("LeftButton")
	local pos = ns.db.minPos
	if pos then
		mini:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		mini:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
	end
	mini:Hide()

	local glow = mini:CreateTexture(nil, "ARTWORK")
	if glow then
		glow:SetAllPoints()
		if glow.SetColorTexture then glow:SetColorTexture(ns.R, ns.G, ns.B, 1) end
		if glow.SetAlpha then glow:SetAlpha(0) end
	end
	mini.glow = glow

	local label = mini:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", 8, 0)
	label:SetPoint("RIGHT", -8, 0)
	label:SetJustifyH("LEFT")
	mini.label = label

	mini:SetScript("OnDragStart", function(self) self:StartMoving() end)
	mini:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		ns.db.minPos = { point, relPoint, x, y }
	end)
	mini:SetScript("OnClick", function(_, button)
		if button == "RightButton" then UI.hide() else UI.window() end
	end)
	mini:SetScript("OnEnter", function(self)
		stopFlash()
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		local r = ns.Room.get()
		GameTooltip:SetText(r and r.name or "Hangout")
		local total = UI.unreadCount()
		if total > 0 then
			GameTooltip:AddLine(("%d unread"):format(total), 1, 1, 1)
		end
		GameTooltip:AddLine("Click to open, right-click to put it away.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
	mini:SetScript("OnUpdate", function(self, elapsed)
		if not self.flashing or not self.glow or not self.glow.SetAlpha then return end
		self.phase = (self.phase or 0) + (elapsed or 0) * 3.2
		self.glow:SetAlpha(0.10 + 0.24 * math.abs(math.sin(self.phase)))
	end)
end

-- Look of the window: how solid the background is, and how big the text is.

local function applyOpacity()
	local a = (ns.db and ns.db.opacity) or 0.85
	if frame and frame.SetBackdropColor then frame:SetBackdropColor(0.04, 0.04, 0.06, a) end
	if mini and mini.SetBackdropColor then mini:SetBackdropColor(0.04, 0.04, 0.06, math.min(1, a + 0.05)) end
	if settings and settings.SetBackdropColor then settings:SetBackdropColor(0.04, 0.04, 0.06, math.max(0.9, a)) end
end
UI.applyOpacity = applyOpacity

local function applyFont()
	if not messages then return end
	local file, size, flags = messages:GetFont()
	if not file then return end
	local want = ns.db.fontSize or size
	if not want then return end
	pcall(messages.SetFont, messages, file, want, flags)
	if input then
		local ifile, _, iflags = input:GetFont()
		if ifile then pcall(input.SetFont, input, ifile, want, iflags) end
	end
end
UI.applyFont = applyFont

-- The size in use, whether it came from us or from your chat font.
function UI.fontSize()
	if ns.db and ns.db.fontSize then return ns.db.fontSize end
	if messages then
		local _, size = messages:GetFont()
		if size then return math.floor(size + 0.5) end
	end
	return 14
end

function UI.setFontSize(size)
	size = tonumber(size)
	if not size then return nil end
	size = math.max(8, math.min(24, math.floor(size + 0.5)))
	ns.db.fontSize = size
	applyFont()
	if settingsRefresh then settingsRefresh() end
	return size
end

-- Takes a fraction: 0.1 is nearly see-through, 1 is solid.
function UI.setOpacity(fraction)
	local a = tonumber(fraction)
	if not a then return nil end
	a = math.max(0.1, math.min(1, a))
	ns.db.opacity = a
	applyOpacity()
	if settingsRefresh then settingsRefresh() end
	return a
end

-- Apply a new colour everywhere it shows: the lines already drawn keep the colour
-- they were drawn in, so redraw the room as well.
function UI.setColor(r, g, b)
	ns.setColor(r, g, b)
	applyOpacity()
	renderRoom(shownRoom or ns.Room.activeId())
	updateMini()
	UI.refresh()
	if settingsRefresh then settingsRefresh() end
	return ns.R, ns.G, ns.B
end

function UI.resetColor()
	local d = ns.DEFAULT_COLOR
	return UI.setColor(d[1], d[2], d[3])
end

-- Blizzard's colour picker, however this client opens it.
function UI.chooseColor()
	local was = { ns.R, ns.G, ns.B }
	local function apply()
		if ColorPickerFrame and ColorPickerFrame.GetColorRGB then
			UI.setColor(ColorPickerFrame:GetColorRGB())
		end
	end
	local info = {
		r = was[1], g = was[2], b = was[3],
		hasOpacity = false,
		swatchFunc = apply,
		opacityFunc = apply,
		cancelFunc = function() UI.setColor(was[1], was[2], was[3]) end,
	}
	if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow(info)
	elseif type(OpenColorPicker) == "function" then
		OpenColorPicker(info)
	else
		ns.print("No colour picker on this client. Use |cffffffff/ho color ffb873|r instead.")
	end
end

local function createSettings()
	if settings then return end
	settings = CreateFrame("Frame", "HangoutSettings", UIParent, "BackdropTemplate")
	settings:SetBackdrop(BACKDROP)
	settings:SetBackdropBorderColor(0.6, 0.48, 0.36, 1)
	settings:SetSize(224, 250)
	settings:SetFrameStrata("DIALOG")
	settings:SetClampedToScreen(true)
	settings:EnableMouse(true)
	settings:Hide()

	local heading = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	heading:SetPoint("TOPLEFT", 12, -10)
	heading:SetText(("|c%sHangout settings|r"):format(ns.HEX))

	local close = CreateFrame("Button", nil, settings, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function() settings:Hide() end)

	local rows, y = {}, -34

	local function tip(owner, title, body)
		owner:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(title)
			GameTooltip:AddLine(body, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	-- An invisible strip behind each row, so hovering the label explains it too.
	local function hoverRow(title, body)
		local hover = CreateFrame("Button", nil, settings)
		hover:SetPoint("TOPLEFT", 8, y + 2)
		hover:SetPoint("TOPRIGHT", -8, y + 2)
		hover:SetHeight(22)
		hover:SetFrameLevel((settings:GetFrameLevel() or 0) + 1)
		tip(hover, title, body)
		return hover
	end

	local function lift(button)
		button:SetFrameLevel((settings:GetFrameLevel() or 0) + 5)
	end

	local function colorRow(text, body)
		hoverRow(text, body)
		local label = settings:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", 12, y - 4)
		label:SetText(text)
		local swatch = CreateFrame("Button", nil, settings)
		swatch:SetSize(40, 16)
		swatch:SetPoint("TOPRIGHT", settings, "TOPRIGHT", -12, y - 1)
		lift(swatch)
		swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		local border = swatch:CreateTexture(nil, "BACKGROUND")
		if border then
			border:SetPoint("TOPLEFT", -1, 1)
			border:SetPoint("BOTTOMRIGHT", 1, -1)
			if border.SetColorTexture then border:SetColorTexture(0.6, 0.48, 0.36, 1) end
		end
		local fill = swatch:CreateTexture(nil, "ARTWORK")
		if fill then fill:SetAllPoints() end
		swatch:SetScript("OnClick", function(_, button)
			if button == "RightButton" then UI.resetColor() else UI.chooseColor() end
		end)
		tip(swatch, text, body)
		rows[#rows + 1] = function()
			if fill and fill.SetColorTexture then fill:SetColorTexture(ns.R, ns.G, ns.B, 1) end
		end
		y = y - 24
	end

	local function stepper(text, body, get, bump, step)
		hoverRow(text, body)
		local label = settings:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", 12, y - 4)
		label:SetText(text)
		local minus = CreateFrame("Button", nil, settings, "UIPanelButtonTemplate")
		minus:SetSize(20, 18)
		minus:SetPoint("TOPRIGHT", settings, "TOPRIGHT", -82, y)
		minus:SetText("-")
		lift(minus)
		local value = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		value:SetPoint("TOPRIGHT", settings, "TOPRIGHT", -42, y - 4)
		value:SetWidth(36)
		value:SetJustifyH("CENTER")
		local plus = CreateFrame("Button", nil, settings, "UIPanelButtonTemplate")
		plus:SetSize(20, 18)
		plus:SetPoint("TOPRIGHT", settings, "TOPRIGHT", -12, y)
		plus:SetText("+")
		lift(plus)
		minus:SetScript("OnClick", function() bump(-step) end)
		plus:SetScript("OnClick", function() bump(step) end)
		tip(minus, text, body)
		tip(plus, text, body)
		rows[#rows + 1] = function() value:SetText(get()) end
		y = y - 24
	end

	local function toggle(text, body, get, flip)
		local b = CreateFrame("Button", nil, settings, "UIPanelButtonTemplate")
		b:SetSize(200, 20)
		b:SetPoint("TOPLEFT", 12, y)
		lift(b)
		b:SetScript("OnClick", function()
			flip()
			if settingsRefresh then settingsRefresh() end
		end)
		tip(b, text, body)
		rows[#rows + 1] = function() b:SetText(("%s: |cffffffff%s|r"):format(text, get())) end
		y = y - 23
	end

	colorRow("Colour",
		"The colour Hangout draws itself in: room lines, room names in your chat, the tabs and the minimized box. Click to pick one, right-click for the original orange.")
	stepper("Text size",
		"How big the text is in the message pane and the typing box, from 8 to 24. It starts out at whatever your chat font uses.",
		function() return tostring(UI.fontSize()) end,
		function(d) UI.setFontSize(UI.fontSize() + d) end, 1)
	stepper("Background",
		"How solid the window background is. 10% is nearly see-through, 100% is solid. The minimized box follows it.",
		function() return ("%d%%"):format(math.floor(((ns.db.opacity or 0.85) * 100) + 0.5)) end,
		function(d) UI.setOpacity((ns.db.opacity or 0.85) + d) end, 0.05)
	toggle("Lines show up in",
		"the window: room lines stay in the Hangout window. your chat: no window at all, room lines appear in your normal chat written like a channel line, and you talk with /hh.",
		function() return ns.db.mode == "inline" and "your chat" or "the window" end,
		function() UI.setMode(ns.db.mode == "inline" and "window" or "inline") end)
	toggle("Whisper sound",
		"Plays the whisper sound when a line arrives in a room you aren't looking at. At most once every 8 seconds, however busy the room gets.",
		function() return ns.db.sound and "on" or "off" end,
		function() ns.db.sound = not ns.db.sound end)
	toggle("Twitch emotes",
		"Turns emote words into pictures in room lines, using Twitch Emotes if you have it. Off shows the plain word instead.",
		function() return ns.db.emotes and "on" or "off" end,
		function() ns.db.emotes = not ns.db.emotes end)
	toggle("Fix the emote picker",
		"Twitch Emotes rebuilds your whole line when you pick an emote and gets it wrong, losing what you typed before it or repeating it. This puts the line back. Turn it off if it ever gets in the way.",
		function() return ns.db.emoteFix and "on" or "off" end,
		function() ns.db.emoteFix = not ns.db.emoteFix end)
	toggle("Enter opens Hangout",
		"After you talk in the room, Enter opens the Hangout box instead of the normal chat box. Talking anywhere else gives the key straight back, and so does closing the window.",
		function() return ns.db.enterKey and "on" or "off" end,
		function()
			ns.db.enterKey = not ns.db.enterKey
			if UI.applyEnterKey then UI.applyEnterKey() end
		end)
	toggle("Keep typing after sending",
		"on: the cursor stays in the box after you send, so you can keep typing. off: the box steps back out like the normal chat box, and Enter opens it again for the next line.",
		function() return ns.db.keepTyping and "on" or "off" end,
		function() ns.db.keepTyping = not ns.db.keepTyping end)
	toggle("Unread badges",
		"Shows how many lines you haven't read on each room tab, and on the minimized box.",
		function() return ns.db.alerts.badge and "on" or "off" end,
		function() ns.db.alerts.badge = not ns.db.alerts.badge layoutTabs() end)
	toggle("Flash taskbar",
		"Blinks WoW in the Windows taskbar when a line arrives while you're in another window. It does nothing while WoW is the window you're looking at.",
		function() return ns.db.alerts.taskbar and "on" or "off" end,
		function() ns.db.alerts.taskbar = not ns.db.alerts.taskbar end)
	toggle("Copy lines to chat",
		"auto: room lines are copied into your main chat while you can't see the room. always: copied even when the window is open. never: not copied at all.",
		function() return ns.db.echo end,
		function()
			ns.db.echo = (ns.db.echo == "auto" and "always") or (ns.db.echo == "always" and "never") or "auto"
		end)

	settings:SetHeight(-y + 14)
	settingsRefresh = function()
		for _, fn in ipairs(rows) do fn() end
	end
	settings:SetScript("OnShow", function() settingsRefresh() end)
	applyOpacity()
end

-- Open or close the settings panel beside the window.
function UI.settings()
	create()
	createSettings()
	if settings:IsShown() then
		settings:Hide()
		return
	end
	settings:ClearAllPoints()
	settings:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
	settingsRefresh()
	settings:Show()
end

-- Enter key.
--
-- WoW remembers the chat type you last used, so Enter reopens it. Do the same for the
-- room: once the last thing you said was said here, Enter opens the Hangout box
-- instead of the normal chat box, until you talk somewhere else. Putting the window
-- away entirely hands the key straight back.
local enterOwner, enterPending

local function wantsEnterKey()
	if not ns.db or not ns.db.enterKey then return false end
	if ns.lastChat ~= "hangout" then return false end
	if not ns.Room.get() then return false end
	-- Inline mode has no window of its own, so the key follows you there too.
	if ns.db.mode == "inline" then return true end
	return (frame ~= nil and frame:IsShown()) or ns.db.minimized == true
end

local function applyEnterKey()
	if not ns.db then return end
	if type(SetOverrideBinding) ~= "function" or type(ClearOverrideBindings) ~= "function" then return end
	-- Changing bindings isn't allowed mid-fight; pick it up when the fight ends.
	if InCombatLockdown and InCombatLockdown() then
		enterPending = true
		return
	end
	enterPending = false
	enterOwner = enterOwner or CreateFrame("Frame", "HangoutKeyOwner", UIParent)
	ClearOverrideBindings(enterOwner)
	if not wantsEnterKey() then return end
	pcall(SetOverrideBinding, enterOwner, false, "ENTER", "HANGOUT_FOCUS")
	pcall(SetOverrideBinding, enterOwner, false, "NUMPADENTER", "HANGOUT_FOCUS")
end
UI.applyEnterKey = applyEnterKey

-- You just said something in the room.
function UI.talkedHere()
	ns.lastChat = "hangout"
	applyEnterKey()
end

-- ...and these mean you said something somewhere else.
local NORMAL_CHAT = {
	"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
	"CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
	"CHAT_MSG_RAID_WARNING", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
	"CHAT_MSG_CHANNEL", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_BN_WHISPER_INFORM",
}

for _, event in ipairs(NORMAL_CHAT) do
	local isWhisper = event:find("INFORM", 1, true) ~= nil
	ns.on(event, function(_, sender)
		if ns.lastChat ~= "hangout" then return end
		-- A whisper you sent names the person you sent it to, not you.
		if isWhisper or (ns.key(sender) == ns.meKey and ns.meKey ~= nil) then
			ns.lastChat = "normal"
			applyEnterKey()
		end
	end)
end

ns.on("PLAYER_REGEN_ENABLED", function()
	if enterPending then applyEnterKey() end
end)

-- Slash commands typed in the Hangout box should do what they do in the normal chat
-- box: /wave waves, /reload reloads. Hand the line to Blizzard's own parser, which is
-- what knows about emotes, chat types and every addon's commands.
local function runSlashCommand(text)
	local box = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox
	local send = (ChatFrameUtil and ChatFrameUtil.SendText) or ChatEdit_SendText
	if box and type(send) == "function" then
		local kept = box:GetText()
		local ok = pcall(function()
			box:SetText(text)
			send(box, 0)
		end)
		pcall(box.SetText, box, kept or "")
		if ok then return true end
	end
	-- No parser to borrow: run it ourselves if it's a command some addon registered.
	local cmd, rest = text:match("^(%S+)%s*(.*)$")
	if not cmd or type(SlashCmdList) ~= "table" then return false end
	cmd = strupper(cmd)
	for name, fn in pairs(SlashCmdList) do
		local i = 1
		while _G["SLASH_" .. name .. i] do
			if strupper(_G["SLASH_" .. name .. i]) == cmd then
				pcall(fn, rest or "")
				return true
			end
			i = i + 1
		end
	end
	return false
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
		local trimmed = ns.readable(text) and strtrim(text) or ""
		if trimmed ~= "" then
			if trimmed:sub(1, 1) == "/" then
				if not runSlashCommand(trimmed) then
					ns.print(("%s isn't a command this client knows."):format(trimmed:match("^(%S+)") or trimmed))
				end
			else
				ns.Room.say(text)
			end
			sent[#sent + 1] = text
			if #sent > 30 then table.remove(sent, 1) end
		end
		sentPos = nil
		self:SetText("")
		-- Like the normal chat box: Enter sends and steps back out, so the next Enter
		-- opens it again for the next line. "Keep typing" leaves the cursor here.
		if not ns.db.keepTyping then self:ClearFocus() end
	end)
	input:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	input:SetScript("OnTabPressed", function()
		-- Tab cycles rooms, like switching chat tabs.
		local list = ns.Room.ordered()
		if #list < 2 then return end
		local activeId = ns.Room.activeId()
		for i, r in ipairs(list) do
			if r.id == activeId then
				UI.selectRoom(list[i % #list + 1].id)
				return
			end
		end
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

function create()
	if frame then return end

	frame = CreateFrame("Frame", "HangoutFrame", UIParent, "BackdropTemplate")
	frame:SetBackdrop(BACKDROP)
	frame:SetBackdropColor(0.04, 0.04, 0.06, 0.85)
	frame:SetBackdropBorderColor(0.6, 0.48, 0.36, 1)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then frame:SetResizeBounds(330, 180, 1000, 800) end
	frame:EnableMouse(true)
	local size = ns.db.size
	frame:SetSize(size and size[1] or 470, size and size[2] or 280)
	local pos = ns.db.pos
	if pos then
		frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
	end
	frame:Hide()

	local bar = CreateFrame("Frame", nil, frame)
	bar:SetPoint("TOPLEFT", 4, -4)
	bar:SetPoint("TOPRIGHT", -132, -4)
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
	title:SetJustifyH("LEFT")

	subtitle = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	subtitle:SetPoint("LEFT", title, "RIGHT", 8, 0)
	subtitle:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
	subtitle:SetJustifyH("LEFT")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function() UI.hide() end)

	tabStrip = CreateFrame("Frame", nil, frame)
	tabStrip:SetPoint("TOPLEFT", 10, -26)
	tabStrip:SetPoint("TOPRIGHT", -10, -26)
	tabStrip:SetHeight(TAB_HEIGHT)

	messages = CreateFrame("ScrollingMessageFrame", nil, frame)
	messages:SetPoint("TOPLEFT", 10, -50)
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
	messages:SetScript("OnHyperlinkEnter", function(self, link, text, ...)
		local kind = type(link) == "string" and link:match("^(%a+):")
		-- Twitch Emotes wraps every emote in a "tel" link and names it on hover, but
		-- only hooks Blizzard's chat frames, so run its handler for our pane too.
		if kind == "tel" then
			local shown = type(Emoticons_OnHyperlinkEnter) == "function"
				and pcall(Emoticons_OnHyperlinkEnter, self, link, text, ...)
			if not shown then
				local name = link:match("^tel:(.+)$")
				if name then
					GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
					GameTooltip:SetText(name, 1, 0.82, 0)
					GameTooltip:Show()
				end
			end
			return
		end
		if not (kind and TOOLTIP_LINKS[kind]) then return end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then
			GameTooltip:Show()
		else
			GameTooltip:Hide()
		end
	end)
	messages:SetScript("OnHyperlinkLeave", function(self, ...)
		GameTooltip:Hide()
		if type(Emoticons_OnHyperlinkLeave) == "function" then
			pcall(Emoticons_OnHyperlinkLeave, self, ...)
		end
	end)
	messages:SetScript("OnUpdate", animateEmotes)

	local gear = CreateFrame("Button", nil, frame)
	gear:SetSize(16, 16)
	gear:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -110, -6)
	gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
	gear:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
	gear:SetScript("OnClick", function() UI.settings() end)
	gear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Settings")
		GameTooltip:AddLine("Text size, background, sounds and alerts.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	gear:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local minimize = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	minimize:SetSize(20, 18)
	minimize:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -26, -5)
	minimize:SetText("_")
	minimize:SetScript("OnClick", function() UI.minimize() end)
	minimize:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Minimize")
		GameTooltip:AddLine("Folds into a small box that lights up when someone talks.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	minimize:SetScript("OnLeave", function() GameTooltip:Hide() end)

	inviteButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	inviteButton:SetSize(56, 18)
	inviteButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -48, -5)
	inviteButton:SetText("Invite")
	inviteButton:SetScript("OnClick", function() UI.promptInvite(ns.Room.activeId()) end)
	inviteButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Invite a friend")
		GameTooltip:AddLine("Target someone first and their name is filled in.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	inviteButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

	frame:SetScript("OnSizeChanged", layoutTabs)

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
	applyOpacity()
	applyFont()
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

-- The Twitch Emotes suggestion list rebuilds the whole line when you pick an emote,
-- and gets it wrong two ways (Lib-EditBox-AutoComplete.lua, EditBoxAutoCompleteButton_OnClick):
-- with a slash command in front it returns "<command> <emote>" and throws away
-- everything you typed in between, and without one it repeats the words you had typed.
-- Both are repairable, because the line you typed is still known: replacing its last
-- word with the emote is all the picker was ever meant to do.
local pickerText = {}   -- editbox -> the last line the player typed in it

-- Last resort when we never saw the line: undo a prefix that was repeated verbatim.
local function undoRepeatedPrefix(text, suggestion)
	local words = {}
	for word in text:gmatch("%S+") do words[#words + 1] = word end
	local n = #words
	if n < 3 or n % 2 == 0 or words[n] ~= suggestion then return nil end
	local half = (n - 1) / 2
	for i = 1, half do
		if words[i] ~= words[half + i] then return nil end
	end
	local kept = {}
	for i = half + 1, n do kept[#kept + 1] = words[i] end
	return table.concat(kept, " ")
end

local function watchPicker(box)
	if not box or pickerText[box] ~= nil then return end
	local settings = box.settings
	if type(settings) ~= "table" then return end
	pickerText[box] = ""

	-- Only what the player types counts; the picker's own SetText must not.
	box:HookScript("OnTextChanged", function(self, byUser)
		if byUser then pickerText[self] = self:GetText() or "" end
	end)

	local orig = settings.onSuggestionApplied
	settings.onSuggestionApplied = function(suggestion)
		if orig then pcall(orig, suggestion) end
		if not ns.db or not ns.db.emoteFix then return end
		if not ns.readable(suggestion) then return end
		local current = box:GetText()
		if not ns.readable(current) then return end

		local fixed
		local before = pickerText[box]
		if ns.readable(before) and before ~= "" then
			local head, last = before:match("^(.-)(%S+)$")
			if last then fixed = head .. suggestion .. (settings.addSpace and " " or "") end
		end
		fixed = fixed or undoRepeatedPrefix(current, suggestion)
		if not fixed or fixed == current then return end
		box:SetText(fixed)
		box:SetCursorPosition(#fixed)
		pickerText[box] = fixed
	end
end
UI.watchPicker = watchPicker

-- Twitch Emotes puts the same picker on Blizzard's chat boxes, where the same bug
-- eats "/hh hello guys :wav". Repair those too, once it has set them up.
function UI.watchChatPickers()
	if type(CHAT_FRAMES) ~= "table" then return end
	for _, frameName in ipairs(CHAT_FRAMES) do
		local f = _G[frameName]
		local box = f and (f.editBox or _G[frameName .. "EditBox"])
		if box then pcall(watchPicker, box) end
	end
end

-- Give the Hangout box the same ":" emote picker Twitch Emotes adds to chat boxes.
local function attachEmotePicker()
	if not input or input.hangoutPicker then return end
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
		watchPicker(input)
	else
		ns.debug("couldn't add the emote picker: %s", tostring(err))
	end
end

-- Draw a room's saved history into the pane. Newest-first, because BackFillMessage
-- adds to the old end.
function renderRoom(id)
	create()
	shownRoom = id
	if messages.Clear then messages:Clear() end
	if not id then
		messages:AddMessage("|cff9d9d9dNo rooms yet. Press + above, or type /ho create <name>.|r")
		return
	end
	local h = ns.Room.history(id)
	if #h == 0 then
		local r = ns.Room.get(id)
		messages:AddMessage(("|cff9d9d9dNothing said in %s yet. Say hello.|r"):format(r and r.name or "here"))
		return
	end
	messages:BackFillMessage("|cff6f6f6f---- earlier ----|r")
	for i = #h, 1, -1 do
		local e = h[i]
		messages:BackFillMessage(formatLine(e.n, e.c, e.x, e.t), ns.R * 0.8, ns.G * 0.8, ns.B * 0.8)
	end
end

-- Is this room in front of the player right now?
local function inFront(roomId)
	if ns.db.mode == "inline" then
		return true -- it lands in the chat you're already reading
	end
	return frame ~= nil and frame:IsShown() and ns.Room.activeId() == roomId
end

local function clearUnread(roomId)
	if roomId and unread[roomId] then
		unread[roomId] = nil
		layoutTabs()
		updateMini()
	end
end

function UI.unreadCount(roomId)
	if roomId then return unread[roomId] or 0 end
	local total = 0
	for _, n in pairs(unread) do total = total + n end
	return total
end

-- Public -------------------------------------------------------------------------

function UI.refresh()
	if not title then return end
	local r = ns.Room.get()
	if not r then
		title:SetText("Hangout")
		subtitle:SetText("|cff9d9d9d- no rooms yet (/ho create <name>)|r")
	else
		local n = ns.Room.onlineCount(r.id)
		local who = n == 0 and "nobody else online" or (n == 1 and "1 friend online" or (n .. " friends online"))
		title:SetText(("|c%s%s|r"):format(ns.HEX, r.name))
		subtitle:SetText(("|cff9d9d9d%s|r"):format(who))
	end
	if inviteButton then
		if r then inviteButton:Enable() else inviteButton:Disable() end
	end
	layoutTabs()
	updateMini()
end

-- Rooms were added, removed or renamed.
function UI.roomsChanged()
	if not ns.db then return end
	create()
	local activeId = ns.Room.activeId()
	if shownRoom ~= activeId then renderRoom(activeId) end
	UI.refresh()
end

function UI.selectRoom(id)
	if not ns.Room.setActive(id) then return end
	clearUnread(id)
	renderRoom(id)
	UI.refresh()
end

function UI.chat(roomId, name, class, text, t, mine)
	create()
	local inline = ns.db.mode == "inline"
	local body = runChatFilters(text, name)
	local line = formatLine(name, class, text, t, body)

	if inline then
		DEFAULT_CHAT_FRAME:AddMessage(channelLine(roomId, name, class, text, body), ns.R, ns.G, ns.B)
	end
	if roomId == shownRoom then
		messages:AddMessage(line, ns.R, ns.G, ns.B)
	end

	local front = inFront(roomId)
	if not mine then
		if not front then
			unread[roomId] = (unread[roomId] or 0) + 1
			layoutTabs()
			if ns.db.minimized then
				startFlash()
				updateMini()
			end
		end
		-- Inline lines are read where they land, but the ping and the taskbar flash
		-- are still worth having when you're looking somewhere else.
		if not front or inline then
			if ns.db.sound and GetTime() - lastSound > 8 then
				lastSound = GetTime()
				if SOUNDKIT and SOUNDKIT.TELL_MESSAGE then PlaySound(SOUNDKIT.TELL_MESSAGE) end
			end
			-- Windows blinks the taskbar button only when WoW isn't the front window,
			-- which is exactly when this is wanted.
			if ns.db.alerts.taskbar and type(FlashClientIcon) == "function" then pcall(FlashClientIcon) end
		end
	end

	-- In window mode lines can also be copied into your main chat while you can't see
	-- the room; inline mode is already there.
	if not inline then
		local echo = ns.db.echo
		if echo == "always" or (echo == "auto" and not (frame and frame:IsShown())) then
			DEFAULT_CHAT_FRAME:AddMessage(channelLine(roomId, name, class, text, body), ns.R, ns.G, ns.B)
		end
	end
end

function UI.note(roomId, text)
	if not ns.db then return end
	create()
	local line = "|cff9d9d9d" .. text .. "|r"
	if ns.db.mode == "inline" then
		local r = ns.Room.get(roomId)
		DEFAULT_CHAT_FRAME:AddMessage(("|c%s[%s]|r %s"):format(ns.HEX, r and r.name or "Hangout", line))
	end
	if roomId == nil or roomId == shownRoom then
		messages:AddMessage(line)
	end
end

function UI.show()
	-- Inline mode has no window to raise: open the chat box ready to talk instead.
	if ns.db.mode == "inline" and ns.Room.get() and type(ChatFrame_OpenChat) == "function" then
		clearUnread(ns.Room.activeId())
		ChatFrame_OpenChat("/hh ")
		return
	end
	UI.window()
end

-- Open the standalone window whatever the display mode is.
function UI.window()
	create()
	createMini()
	stopFlash()
	mini:Hide()
	ns.db.minimized = false
	if shownRoom ~= ns.Room.activeId() then renderRoom(ns.Room.activeId()) end
	frame:Show()
	ns.db.shown = true
	clearUnread(ns.Room.activeId())
	UI.refresh()
	applyEnterKey()
end

-- Fold the window into the little box.
function UI.minimize()
	create()
	createMini()
	frame:Hide()
	ns.db.shown = false
	ns.db.minimized = true
	stopFlash()
	updateMini()
	mini:Show()
	applyEnterKey()
end

function UI.hide()
	if frame then frame:Hide() end
	if mini then
		stopFlash()
		mini:Hide()
	end
	if ns.db then
		ns.db.shown = false
		ns.db.minimized = false
	end
	applyEnterKey()
end

function UI.toggle()
	create()
	if frame:IsShown() then
		UI.hide()
	else
		UI.show()
	end
end

function UI.focus()
	if ns.db.mode == "inline" then
		UI.show()
		return
	end
	UI.window()
	input:SetFocus()
end

-- "window" or "inline".
function UI.setMode(want)
	if want ~= "window" and want ~= "inline" then return nil end
	ns.db.mode = want
	if want == "inline" then UI.hide() else UI.window() end
	applyEnterKey()
	if settingsRefresh then settingsRefresh() end
	return want
end

function UI.resetPosition()
	ns.db.pos, ns.db.size = nil, nil
	if frame then
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
		frame:SetSize(470, 280)
	end
end

-- Invite prompt -------------------------------------------------------------------

local inviteQueue = {}

local function showNextInvite()
	if not inviteFrame or inviteFrame:IsShown() then return end
	local nextOne = table.remove(inviteQueue, 1)
	if nextOne then UI.showInvite(nextOne.from, nextOne.id, nextOne.name) end
end

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
		showNextInvite()
	end)
	inviteFrame.yes = yes

	local no = CreateFrame("Button", nil, inviteFrame, "UIPanelButtonTemplate")
	no:SetSize(120, 22)
	no:SetPoint("BOTTOMLEFT", inviteFrame, "BOTTOM", 6, 12)
	no:SetText("No thanks")
	no:SetScript("OnClick", function()
		local d = inviteFrame.data
		inviteFrame:Hide()
		if d then ns.Room.declineInvite(d.from, d.id) end
		showNextInvite()
	end)
	inviteFrame.no = no
end

function UI.showInvite(from, id, name)
	if not inviteFrame then createInvite() end
	if name == "" then name = "Hangout" end
	-- One prompt at a time, but the others wait their turn instead of being lost:
	-- with several rooms, two friends inviting you at once is normal.
	if inviteFrame:IsShown() then
		if inviteFrame.data and inviteFrame.data.id == id then return end
		for _, q in ipairs(inviteQueue) do
			if q.id == id then return end
		end
		inviteQueue[#inviteQueue + 1] = { from = from, id = id, name = name }
		return
	end
	local full = ns.Room.count() >= ns.Room.MAX_ROOMS
	local extra = full and ("\n|cffff5555(You're in %d rooms already \226\128\148 leave one first.)|r"):format(ns.Room.MAX_ROOMS) or ""
	inviteFrame.text:SetText(("%s invites you to the Hangout room |c%s%s|r.%s"):format(from, ns.HEX, name, extra))
	local data = { from = from, id = id, name = name }
	inviteFrame.data = data
	inviteFrame:Show()
	if SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE then PlaySound(SOUNDKIT.IG_PLAYER_INVITE) end
	if ns.db.alerts.taskbar and type(FlashClientIcon) == "function" then pcall(FlashClientIcon) end
	C_Timer.After(120, function()
		if inviteFrame.data == data and inviteFrame:IsShown() then
			inviteFrame:Hide()
			showNextInvite()
		end
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

ns.on("HANGOUT_INIT", registerPopups)

ns.on("HANGOUT_LOGIN", function()
	create()
	hookLinkInsertion()
	hookRoomLinks()
	applyEnterKey()
	renderRoom(ns.Room.activeId())
	UI.refresh()
	if ns.db.mode ~= "inline" then
		if ns.db.minimized then
			UI.minimize()
		elseif ns.db.shown then
			UI.window()
		end
	end
	-- Let Twitch Emotes finish loading before drawing old lines with emotes.
	-- Twitch Emotes sets up the chat boxes at login too; look again a little later in
	-- case it hadn't finished the first time.
	C_Timer.After(3, UI.watchChatPickers)
	C_Timer.After(12, UI.watchChatPickers)
	C_Timer.After(2, function()
		attachEmotePicker()
		renderRoom(ns.Room.activeId())
		UI.refresh()
	end)
end)
