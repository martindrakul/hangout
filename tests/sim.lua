-- Offline simulation of several WoW clients running Hangout, talking through a fake
-- server that routes addon whispers. Run: lua5.1 sim.lua /path/to/Hangout

local ADDON_DIR = arg[1] or "../Hangout"
local FILES = { "Core.lua", "Comm.lua", "Room.lua", "UI.lua", "Channels.lua", "Commands.lua" }

---------------------------------------------------------------- clock & timers
local clock = 1000
local timers = {}
local function schedule(at, fn, interval) timers[#timers + 1] = { at = at, fn = fn, interval = interval } end
local function advance(dt)
	local target = clock + dt
	while true do
		local nextT, idx
		for i, t in ipairs(timers) do
			if not t.cancelled and t.at <= target and (not nextT or t.at < nextT) then nextT, idx = t.at, i end
		end
		if not idx then break end
		local t = timers[idx]
		clock = t.at
		if t.interval then t.at = t.at + t.interval else table.remove(timers, idx) end
		t.fn(t.handle)
	end
	clock = target
end

---------------------------------------------------------------- string helpers (WoW globals)
local function strtrim(s, chars)
	assert(type(s) == "string", "strtrim expects a string")
	assert(chars == nil or type(chars) == "string", "strtrim got a non-string second argument (gsub count leak?)")
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
local function wipe(t) for k in pairs(t) do t[k] = nil end return t end

---------------------------------------------------------------- server
local clients = {}       -- lowercase full name -> client
local server = { log = {} }

local function deliver(client, event, ...)
	local args = { ... }
	schedule(clock + 0.05, function() client.fire(event, unpack(args)) end)
end

function server.send(from, prefix, text, kind, target, logged)
	assert(kind == "WHISPER", "only whispers expected, got " .. tostring(kind))
	assert(#text <= 255, "addon message too long: " .. #text)
	assert(#prefix <= 16, "prefix too long")
	if from.lockdown then return 11 end
	if from.trial then return 9 end
	local to = clients[target:lower()]
	server.log[#server.log + 1] = { from = from.name, to = target, text = text }
	if not to or not to.online then
		deliver(from, "CHAT_MSG_SYSTEM", ("No player named '%s' is currently playing."):format(target))
		return 0
	end
	if to.prefixes[prefix] then
		deliver(to, logged and "CHAT_MSG_ADDON_LOGGED" or "CHAT_MSG_ADDON", prefix, text, "WHISPER", from.name, to.name, 0, 0, "", 0)
	end
	return 0
end

---------------------------------------------------------------- frame stubs
local function newObject(client, kind)
	local o = { _scripts = {}, _shown = kind ~= "Frame-hidden", _lines = {}, _text = "", _focus = false, _events = {} }
	local mt = {}
	mt.__index = function(t, k)
		-- WoW widget methods are CamelCase; plain fields start lower-case and are nil until set
		if type(k) == "string" and k:match("^%u") then return function() end end
		return nil
	end
	setmetatable(o, mt)
	function o:SetScript(name, fn) self._scripts[name] = fn end
	function o:GetScript(name) return self._scripts[name] end
	function o:HookScript(name, fn) self._scripts[name] = fn end
	function o:GetName() return self._name end
	function o:CreateTexture() return newObject(client, "Texture") end
	function o:SetAlpha(a) self._alpha = a end
	function o:GetStringWidth() return 40 end
	function o:GetFrameLevel() return self._level or 1 end
	function o:SetFrameLevel(level) self._level = level end
	function o:SetFont(file, size, flags) self._font = { file, size, flags } end
	function o:GetFont()
		local f = self._font or { "Fonts\FRIZQT__.TTF", 14, "" }
		return f[1], f[2], f[3]
	end
	function o:SetBackdropColor(r, g, b, a) self._backdropAlpha = a end
	function o:Show() self._shown = true end
	function o:Hide() self._shown = false end
	function o:IsShown() return self._shown end
	function o:AddMessage(text) table.insert(self._lines, 1, text) end
	function o:BackFillMessage(text) table.insert(self._lines, text) end
	function o:SetText(text) self._text = text end
	function o:GetText() return self._text end
	function o:Insert(text) self._text = self._text .. text end
	function o:HasFocus() return self._focus end
	function o:SetFocus() self._focus = true end
	function o:ClearFocus() self._focus = false end
	function o:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
	function o:GetWidth() return 430 end
	function o:GetHeight() return 250 end
	function o:CreateFontString() return newObject(client, "FontString") end
	function o:RegisterEvent(event)
		if event == "BOGUS_EVENT" then error("unknown event") end
		client.registered[event] = client.registered[event] or {}
		table.insert(client.registered[event], self)
	end
	return o
end

---------------------------------------------------------------- client factory
local function newClient(first, last, class, withTE, seed)
	local c = { withTE = withTE, name = first .. " " .. last, online = true, lockdown = false, instance = false,
		prefixes = {}, registered = {}, filters = {}, printed = {}, overrides = {}, frames = {} }
	c.key = c.name:lower()
	clients[c.key] = c

	local env = {}
	setmetatable(env, { __index = _G })
	c.env = env

	env.strtrim, env.strlower, env.strupper, env.wipe = strtrim, string.lower, string.upper, wipe
	env.format = string.format
	env._G = env   -- addon code that looks a frame up by name ("ChatFrame5") stays inside this client
	env.date = function(fmt, t) return "12:00" end
	env.GetTime = function() return clock end
	env.GetServerTime = function() return 1800000000 + math.floor(clock) end
	env.Ambiguate = function(name) return (name:gsub("%-.*$", "")) end
	env.UnitName = function(unit)
		if unit == "player" then return first, last end
		if unit == "target" and c.target then return c.target[1], c.target[2] end
	end
	env.UnitIsPlayer = function(unit) return unit == "target" and c.target ~= nil end
	env.UnitClass = function() return class:sub(1, 1) .. class:sub(2):lower(), class end
	env.RegionalUniqueNamesEnabled = function() return true end
	env.IsInInstance = function() return c.instance, c.instance and "party" or "none" end
	env.IsShiftKeyDown = function() return false end
	env.RAID_CLASS_COLORS = { MAGE = { colorStr = "ff3fc7eb" }, WARRIOR = { colorStr = "ffc69b6d" } }
	env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
	env.SOUNDKIT = { TELL_MESSAGE = 1, IG_PLAYER_INVITE = 2 }
	env.PlaySound = function(id) c.sounds = (c.sounds or 0) + 1 end
	env.UIParent = newObject(c, "Frame")
	env.GameTooltip = newObject(c, "Frame")
	env.ChatFontNormal = {}
	env.SlashCmdList = {}
	env.SetItemRef = function() end
	env.GetPlayerLink = function(name, display) return "|Hplayer:" .. name .. "|h" .. display .. "|h" end
	env.hooksecurefunc = function(a, b, c)
		if type(a) == "table" then
			local orig = a[b]
			a[b] = function(...) local r = orig(...); c(...); return r end
		else
			-- hooksecurefunc("GlobalName", fn)
			local orig = env[a]
			env[a] = function(...)
				local r
				if orig then r = orig(...) end
				b(...)
				return r
			end
		end
	end
	env.GetChannelList = function()
		local out = {}
		for i, name in ipairs(c.channels or {}) do out[#out + 1] = i; out[#out + 1] = name; out[#out + 1] = false end
		return unpack(out)
	end
	env.LeaveChannelByName = function(name)
		for i, n in ipairs(c.channels or {}) do if n == name then table.remove(c.channels, i) break end end
	end
	env.DEFAULT_CHAT_FRAME = newObject(c, "Frame")
	c.chat = env.DEFAULT_CHAT_FRAME
	env.ChatFrame1 = env.DEFAULT_CHAT_FRAME
	env.ChatFrame1._name = "ChatFrame1"
	env.ChatFrame1.editBox = newObject(c, "EditBox")
	env.CHAT_FRAMES = { "ChatFrame1" }
	env.FlashClientIcon = function() c.flashes = (c.flashes or 0) + 1 end
	env.ChatFrame_OpenChat = function(text) c.openedChat = text end
	env.InCombatLockdown = function() return c.combat or false end
	-- Blizzard's parser: run the slash command if something registered it.
	env.ChatEdit_SendText = function(box)
		local text = box:GetText() or ""
		c.sentCommand = text
		local cmd, rest = text:match("^(%S+)%s*(.*)$")
		if not cmd then return end
		cmd = cmd:upper()
		for name, fn in pairs(env.SlashCmdList) do
			local i = 1
			while env["SLASH_" .. name .. i] do
				if env["SLASH_" .. name .. i]:upper() == cmd then
					fn(rest or "")
					return
				end
				i = i + 1
			end
		end
	end
	env.ColorPickerFrame = {
		GetColorRGB = function() local p = c.picked or {} return p[1], p[2], p[3] end,
		SetupColorPickerAndShow = function(_, info) c.colorInfo = info end,
	}
	env.SetOverrideBinding = function(_, _, key, command) c.overrides[key] = command end
	env.ClearOverrideBindings = function() c.overrides = {} end
	env.StaticPopupDialogs = {}
	env.StaticPopup_Show = function(which, a, b, data)
		local dialog = newObject(c, "Frame")
		dialog._name = "StaticPopup1"
		dialog.editBox = newObject(c, "EditBox")
		dialog.which, dialog.data = which, data
		c.popup = dialog
		return dialog
	end

	env.C_Timer = {
		After = function(d, fn) schedule(clock + d, fn) end,
		NewTicker = function(d, fn)
			local h = {}
			function h:Cancel() self.cancelled = true end
			schedule(clock + d, fn, d)
			timers[#timers].handle = h
			return h
		end,
	}
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(p) c.prefixes[p] = true return 0 end,
		SendAddonMessage = function(p, text, kind, target) return server.send(c, p, text, kind, target, false) end,
		SendAddonMessageLogged = function(p, text, kind, target)
			if c.loggedBroken then return 0 end -- accepted, never delivered
			return server.send(c, p, text, kind, target, true)
		end,
		InChatMessagingLockdown = function() return c.lockdown end,
	}
	env.ChatFrameUtil = {
		AddMessageEventFilter = function(event, fn)
			c.filters[event] = c.filters[event] or {}
			table.insert(c.filters[event], fn)
		end,
		ProcessMessageEventFilters = function(frame, event, ...)
			local args = { ... }
			for _, fn in ipairs(c.filters[event] or {}) do
				local res = { fn(frame, event, unpack(args)) }
				if res[1] then return true, unpack(args) end
				if res[2] then args = { select(2, unpack(res)) } end
			end
			return false, unpack(args)
		end,
		InsertLink = function(text) return false end,
	}
	env.CreateFrame = function(kind, name, parent, template)
		local o = newObject(c, kind)
		o._name = name
		o._parent = parent
		c.frames[#c.frames + 1] = o
		if kind == "Frame" and name == "HangoutFrame" then o._shown = true end
		if kind == "ScrollingMessageFrame" then c.pane = o end
		if name then env[name] = o end
		return o
	end

	function c.fire(event, ...)
		for _, f in ipairs(c.registered[event] or {}) do
			local fn = f._scripts.OnEvent
			if fn then fn(f, event, ...) end
		end
		-- chat filters for system messages decide whether it shows in chat
		if event == "CHAT_MSG_SYSTEM" then
			local shown = true
			for _, fn in ipairs(c.filters[event] or {}) do
				if fn(c.chat, event, ...) then shown = false end
			end
			if shown then c.chat:AddMessage("SYSTEM: " .. (...)) end
		end
	end

	if c.withTE then
		env.TwitchEmotes_emoticons = { kekw = "KEKW", KEKW = "KEKW", Kekw = "KEKW", [":bruh:"] = ":bruh:" }
		env.AllTwitchEmoteNames = { "KEKW", ":bruh:" }
		env.EditBoxAutoCompleteBox = newObject(c, "Frame")
		env.Emoticons_Settings = { ENABLE_AUTOCOMPLETE = true }
		env.SetupAutoComplete = function(box, list, n, settings)
			box.settings = settings   -- the real library stores it on the edit box
			c.picker = { box = box, list = list, settings = settings }
		end
	end
	local ns = {}
	local knownGlobals = {}
	for k in pairs(env) do knownGlobals[k] = true end
	for _, file in ipairs(FILES) do
		local chunk = assert(loadfile(ADDON_DIR .. "/" .. file))
		setfenv(chunk, env)
		chunk("Hangout", ns)
	end
	c.newGlobals = {}
	for k in pairs(env) do
		if not knownGlobals[k] then c.newGlobals[#c.newGlobals + 1] = k end
	end
	table.sort(c.newGlobals)
	c.ns = ns
	if seed then env.HangoutCharDB = seed end
	c.fire("ADDON_LOADED", "Hangout")
	c.fire("PLAYER_LOGIN")
	return c
end

local function slash(c, cmd, msg) c.env.SlashCmdList[cmd](msg) end
local function window(c) return c.env.HangoutFrame end
local function lines(c) return c.env.HangoutFrame and c.ns and c.ns.UI and c.env.HangoutFrame end

-- the message pane is the first ScrollingMessageFrame created; find lines via UI.chat hook
local function spyChat(c)
	c.got = {}
	local orig = c.ns.UI.chat
	c.ns.UI.chat = function(roomId, name, class, text, t, mine)
		c.got[#c.got + 1] = { room = roomId, name = name, text = text, mine = mine }
		return orig(roomId, name, class, text, t, mine)
	end
	local origNote = c.ns.UI.note
	c.notes = {}
	c.ns.UI.note = function(roomId, text)
		c.notes[#c.notes + 1] = text
		return origNote(roomId, text)
	end
end

-- Click Join (or No thanks) on the invite prompt, the way a player does.
local function clickJoin(c)
	local f = c.env.HangoutInviteFrame
	assert(f and f:IsShown(), "no invite prompt is showing for " .. c.name)
	local d = f.data
	f.yes._scripts.OnClick()
	return d
end

local function clickDecline(c)
	local f = c.env.HangoutInviteFrame
	assert(f and f:IsShown(), "no invite prompt is showing for " .. c.name)
	f.no._scripts.OnClick()
end

local function lastGotIn(c, roomName)
	local r = c.ns.Room.byName(roomName)
	if not r then return nil end
	for i = #c.got, 1, -1 do
		if c.got[i].room == r.id then return c.got[i] end
	end
	return nil
end

local function lastGot(c) return c.got[#c.got] end
local function rosterKeys(c)
	local r = c.ns.Room.get()
	if not r then return "(no room)" end
	local keys = {}
	for k, e in pairs(r.roster) do keys[#keys + 1] = k .. (e.g and "(gone)" or "") end
	table.sort(keys)
	return table.concat(keys, ", ")
end

local passed, failed = 0, 0
local function check(cond, label)
	if cond then passed = passed + 1; print("  ok   " .. label)
	else failed = failed + 1; print("  FAIL " .. label) end
end

---------------------------------------------------------------- scenarios
print("setup: three friends log in")
local A = newClient("Moorwyn", "Stormgaard", "MAGE")
local B = newClient("Ironfist", "Dawncrusher", "WARRIOR", true)
local C = newClient("Lyra", "Brightwater", "MAGE")
for _, c in ipairs({ A, B, C }) do spyChat(c) end
advance(10)

print("the addon keeps itself to itself")
-- A local that gets defined after its first use quietly becomes a global, which then
-- reads back as nil. Anything new here that isn't deliberate is that mistake.
local ALLOWED_GLOBALS = {
	SLASH_HANGOUT1 = true, SLASH_HANGOUT2 = true, SLASH_HANGOUTSAY1 = true,
	BINDING_HEADER_HANGOUT = true, BINDING_NAME_HANGOUT_TOGGLE = true,
	BINDING_NAME_HANGOUT_FOCUS = true,
	Hangout_Toggle = true, Hangout_Focus = true,
}
local strays = {}
for _, name in ipairs(A.newGlobals) do
	if not ALLOWED_GLOBALS[name] then strays[#strays + 1] = name end
end
check(#strays == 0, "no stray globals: " .. (#strays > 0 and table.concat(strays, ", ") or "none"))

print("logged self-test")
check(A.ns.Comm.usingLogged(), "logged addon messages detected as working")

print("A creates a room and invites B and C")
slash(A, "HANGOUT", "create Night Owls")
check(A.ns.Room.get() and A.ns.Room.get().name == "Night Owls", "room created")
slash(A, "HANGOUT", "invite ironfist dawncrusher")
advance(1)
check(B.env.HangoutInviteFrame and B.env.HangoutInviteFrame:IsShown(), "B sees invite prompt")
clickJoin(B)
advance(2)
C.target = { "Lyra", "Brightwater" }
A.target = { "Lyra", "Brightwater" }
slash(A, "HANGOUT", "invite")
advance(1)
local d = clickJoin(C)
advance(3)
print("    A roster: " .. rosterKeys(A))
print("    B roster: " .. rosterKeys(B))
print("    C roster: " .. rosterKeys(C))
check(rosterKeys(A) == rosterKeys(B) and rosterKeys(B) == rosterKeys(C), "member lists match everywhere")
check(A.ns.Room.onlineCount() == 2 and B.ns.Room.onlineCount() == 2 and C.ns.Room.onlineCount() == 2, "everyone sees 2 friends online")

print("chat with an item link, a quest link and a long text (forces chunks)")
local link = "|cff1eff00|Hitem:2589::::::::12:::::::|h[Linen Cloth]|h|r"
local quest = "|cffffff00|Hquest:176:10|h[Wanted: \"Hogger\"]|h|r"
local long = "hey " .. link .. " and " .. quest .. " " .. string.rep("blah ", 80) .. " Kappa ünïcödé ✓ end"
slash(A, "HANGOUTSAY", long)
advance(1)
check(lastGot(B) and lastGot(B).text == long, "B got the exact text (" .. #long .. " bytes)")
check(lastGot(C) and lastGot(C).text == long, "C got the exact text")
check(lastGot(A) and lastGot(A).mine, "A sees own line")

print("Twitch Emotes-style filter on B")
B.env.ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_CHANNEL", function(_, _, msg, ...)
	return false, (msg:gsub("peepoHappy", "|TInterface\\AddOns\\TwitchEmotes\\peepoHappy.tga:28:28|t")), ...
end)
local before = #B.env.HangoutFrame._lines
slash(C, "HANGOUTSAY", "gg peepoHappy")
advance(1)
local rendered = B.env.HangoutFrame._lines
local found = false
-- lines are stored on the message pane object, not the main frame; scan all objects' lines via chat echo
for _, l in ipairs(B.got) do if l.text == "gg peepoHappy" then found = true end end
check(found, "B received C's line")
local drew = false
for _, l in ipairs(B.pane._lines) do if l:find("peepoHappy.tga:28:28|t", 1, true) then drew = true end end
check(drew, "B's window shows the emote picture")
local rawOnA = false
for _, l in ipairs(A.pane._lines) do if l:find("gg peepoHappy", 1, true) then rawOnA = true end end
check(rawOnA, "A (no emote addon) shows the plain word")

print("window closed: echo to main chat + sound")
A.ns.UI.hide()
advance(10)
local echoed = #A.chat._lines
local sounds = A.sounds or 0
slash(B, "HANGOUTSAY", "you there?")
advance(1)
check(#A.chat._lines == echoed + 1, "one line copied to main chat")
check(A.chat._lines[1]:find("[Night Owls]", 1, true) and A.chat._lines[1]:find("Ironfist Dawncrusher", 1, true),
	"copied as a channel line: [room] name: message")
check(A.chat._lines[1]:find("|Hhangout:", 1, true) ~= nil, "the room name is a link back to the room")
check((A.sounds or 0) == sounds + 1, "whisper sound played once")
A.ns.UI.show()

print("shift-click a link while typing in the Hangout box")
A.env.HangoutInputBox:SetFocus()
A.env.HangoutInputBox:SetText("look: ")
A.env.ChatFrameUtil.InsertLink(link)
check(A.env.HangoutInputBox:GetText() == "look: " .. link, "link inserted into the Hangout box")
A.env.HangoutInputBox:ClearFocus()
A.env.ChatFrameUtil.InsertLink(link)
check(A.env.HangoutInputBox:GetText() == "look: " .. link, "no insert when the box isn't focused")
A.env.HangoutInputBox._scripts.OnEnterPressed(A.env.HangoutInputBox)
advance(1)
check(lastGot(B).text == "look: " .. link, "Enter in the box sends to the room")

print(":kekw: typed by hand (no picker on the sender)")
-- behaves like Twitch Emotes: split on its delimiters, look each word up
B.env.ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_CHANNEL", function(_, _, msg, ...)
	local known = B.env.TwitchEmotes_emoticons
	local out = msg:gsub("[^%s,'<>?%-%.!]+", function(word)
		if known[word] == "KEKW" then return "|TKEKW.tga:28:28|t" end
	end)
	return false, out, ...
end)
local tricky = ":kekw: lol :kekw and :bruh: and Kekw, " .. link .. " at 12:30 :nope:"
slash(A, "HANGOUTSAY", tricky)
advance(1)
local shownLine = B.pane._lines[1]
local _, pics = shownLine:gsub("KEKW%.tga", "")
check(pics == 3, "three kekw variants become pictures (got " .. pics .. ")")
check(shownLine:find(":bruh:", 1, true) ~= nil, "real colon emote :bruh: left as is")
check(shownLine:find(link, 1, true) ~= nil, "item link untouched")
check(shownLine:find("12:30", 1, true) and shownLine:find(":nope:", 1, true), "times and unknown :words: untouched")
check(lastGot(B).text == tricky, "stored text is what was sent")
check(B.picker and B.picker.box == B.env.HangoutInputBox and B.picker.settings.activationChar == ":", "emote picker attached to B's Hangout box")
check(A.picker == nil, "no picker when Twitch Emotes isn't installed")

print("C goes offline; A talks")
C.online = false
advance(200)
slash(A, "HANGOUTSAY", "anyone?")
advance(2)
check(not A.ns.Room.isOnline("lyra brightwater"), "A marks C offline (heartbeat timeout / not-found)")
local leaked = false
for _, l in ipairs(A.chat._lines) do if l:find("No player named", 1, true) then leaked = true end end
check(not leaked, "'No player named' spam stays out of A's chat")

print("C comes back")
C.online = true
C.fire("PLAYER_LOGIN")
advance(10)
check(A.ns.Room.isOnline("lyra brightwater") and B.ns.Room.isOnline("lyra brightwater"), "A and B see C online again")

print("boss-fight lockdown on A")
A.lockdown = true
slash(A, "HANGOUTSAY", "pulling now")
advance(3)
check(not (lastGot(B).text == "pulling now"), "nothing sent during lockdown")
A.lockdown = false
advance(2)
check(lastGot(B).text == "pulling now", "queued line goes out after lockdown")

print("inside an instance (throttled prefixes)")
A.instance = true
for i = 1, 12 do slash(A, "HANGOUTSAY", "spam " .. i) end
advance(30)
check(lastGot(B).text == "spam 12" and lastGot(C).text == "spam 12", "all 12 lines arrive in order, paced")
A.instance = false

print("A removes C")
slash(A, "HANGOUT", "remove lyra brightwater")
advance(3)
check(C.ns.Room.get() == nil, "C's copy leaves the room")
check(rosterKeys(B):find("lyra brightwater%(gone%)") ~= nil, "B marks C gone")
slash(C, "HANGOUTSAY", "still here?")
advance(1)
check(lastGot(B).text ~= "still here?", "C can't talk in the room anymore")

print("A invites C back")
slash(A, "HANGOUT", "invite Lyra Brightwater")
advance(1)
d = clickJoin(C)
advance(3)
check(not rosterKeys(B):find("gone"), "C is back in B's member list: " .. rosterKeys(B))
slash(C, "HANGOUTSAY", "back!")
advance(1)
check(lastGot(B).text == "back!" and lastGot(A).text == "back!", "C can talk again")

print("B leaves")
slash(B, "HANGOUT", "leave")
advance(3)
check(B.ns.Room.get() == nil, "B is out")
check(rosterKeys(A):find("ironfist dawncrusher%(gone%)") and rosterKeys(C):find("ironfist dawncrusher%(gone%)"), "A and C mark B gone")
local sentToB = 0
local mark = #server.log
slash(A, "HANGOUTSAY", "bye B")
advance(1)
for i = mark + 1, #server.log do if server.log[i].to:lower() == "ironfist dawncrusher" then sentToB = sentToB + 1 end end
check(sentToB == 0, "A stops sending to B")

print("logged messages accepted but never delivered (fallback check)")
local D = newClient("Ash", "Vale", "WARRIOR")
D.loggedBroken = true
spyChat(D)
advance(10)
check(not D.ns.Comm.usingLogged(), "D falls back to normal addon messages")

print("channel cleanup")
A.channels = { "General", "Trade", "name1", "name2", "Name510", "LookingForGroup" }
slash(A, "HANGOUT", "cleanup name")
check(#A.channels == 6, "preview doesn't leave anything")
slash(A, "HANGOUT", "cleanup name confirm")
advance(5)
check(#A.channels == 3 and A.channels[1] == "General", "left name1, name2, Name510 only")

print("a second room, side by side with the first")
slash(A, "HANGOUT", "create Raid Crew")
advance(1)
check(A.ns.Room.count() == 2, "A is in two rooms")
check(A.ns.Room.get().name == "Raid Crew", "the newest room is the one in front")
slash(A, "HANGOUT", "invite Lyra Brightwater")
advance(1)
d = clickJoin(C)
advance(3)
check(C.ns.Room.count() == 2, "C is in both rooms: joining one doesn't drop the other")
slash(A, "HANGOUTSAY", "raid at 8")
advance(1)
check(lastGotIn(C, "Raid Crew") and lastGotIn(C, "Raid Crew").text == "raid at 8", "the line landed in Raid Crew")
check(lastGotIn(C, "Night Owls").text ~= "raid at 8", "and not in Night Owls")
check(#C.ns.Room.history(C.ns.Room.byName("Raid Crew").id) == 1, "each room keeps its own history")
slash(A, "HANGOUT", "switch Night")
check(A.ns.Room.get().name == "Night Owls", "/ho switch brings a room to the front")
slash(A, "HANGOUTSAY", "anyone up for dungeons")
advance(1)
check(lastGotIn(C, "Night Owls").text == "anyone up for dungeons", "/hh talks in whichever room is in front")

print("unread badges")
local nightId = C.ns.Room.byName("Night Owls").id
local raidId = C.ns.Room.byName("Raid Crew").id
check(C.ns.UI.unreadCount(nightId) > 0, "unread piles up for the room you're not looking at")
check(C.ns.UI.unreadCount(raidId) == 0, "nothing unread in the room that's in front")
C.ns.UI.selectRoom(nightId)
check(C.ns.UI.unreadCount(nightId) == 0, "looking at a room clears its badge")

print("taskbar flash while you're in another window")
C.ns.db.alerts.taskbar = true
C.ns.UI.selectRoom(raidId)
local flashes = C.flashes or 0
slash(A, "HANGOUTSAY", "ping")
advance(1)
check((C.flashes or 0) == flashes + 1, "WoW flashed in the taskbar once")
C.ns.db.alerts.taskbar = false
local quiet = C.flashes or 0
slash(A, "HANGOUTSAY", "ping again")
advance(1)
check((C.flashes or 0) == quiet, "and not at all when the alert is off")

print("animated emotes keep animating in the Hangout window")
B.env.TwitchEmotesAnimator_UpdateEmoteInFontString = function() B.animated = (B.animated or 0) + 1 end
B.pane.visibleLines = { newObject(B, "FontString"), newObject(B, "FontString") }
local tick = B.pane._scripts.OnUpdate
check(tick ~= nil, "the message pane has an animation tick")
tick(B.pane, 0.05)
check((B.animated or 0) == 2, "every visible line is handed to the Twitch Emotes animator")
B.animated = 0
tick(B.pane, 0.01)
check(B.animated == 0, "and it is throttled rather than running every frame")
B.ns.db.emotes = false
tick(B.pane, 0.05)
check(B.animated == 0, "nothing happens when emotes are turned off")
B.ns.db.emotes = true
B.env.TwitchEmotesAnimator_UpdateEmoteInFontString = nil
tick(B.pane, 0.05)
check(true, "and nothing breaks when Twitch Emotes isn't installed")

print("minimize: the window folds into a small box")
C.ns.UI.window()
slash(C, "HANGOUT", "min")
check(not window(C):IsShown(), "the window is out of the way")
local box = C.env.HangoutMiniFrame
check(box and box:IsShown(), "the small box is up")
check(not box.flashing, "sitting quietly to begin with")
local unreadBefore = C.ns.UI.unreadCount()
slash(A, "HANGOUTSAY", "psst")
advance(1)
check(C.ns.UI.unreadCount() == unreadBefore + 1, "a line while minimized counts as unread")
check(box.flashing, "the box flashes when a line arrives")
check(box.label:GetText():find(tostring(unreadBefore + 1), 1, true) ~= nil, "and shows how much you haven't read")
box._scripts.OnUpdate(box, 0.1)
check((box.glow._alpha or 0) > 0, "the flash is actually drawn")
box._scripts.OnClick(box, "LeftButton")
check(window(C):IsShown(), "clicking the box opens the window again")
check(not box:IsShown() and not box.flashing, "and the box goes away")
slash(C, "HANGOUT", "min")
check(box:IsShown(), "/ho min folds it away again")
slash(C, "HANGOUT", "")
check(window(C):IsShown() and not box:IsShown(), "/ho brings it back from minimized")
slash(C, "HANGOUT", "min")
box._scripts.OnClick(box, "RightButton")
check(not box:IsShown() and not window(C):IsShown(), "right-click puts it away entirely")
C.ns.UI.window()

print("emote names on hover")
B.env.Emoticons_OnHyperlinkEnter = function(_, link) B.hovered = link end
local hoverIn = B.pane._scripts.OnHyperlinkEnter
hoverIn(B.pane, "tel:KEKW", "[KEKW]")
check(B.hovered == "tel:KEKW", "an emote link goes to Twitch Emotes' own tooltip")
B.env.Emoticons_OnHyperlinkEnter = nil
hoverIn(B.pane, "tel:PepeLaugh", "[PepeLaugh]")
check(B.env.GameTooltip._text == "PepeLaugh", "and we name it ourselves when Twitch Emotes can't")

print("Enter goes back to wherever you last talked")
C.ns.UI.window()
slash(C, "HANGOUTSAY", "mine")
advance(1)
check(C.overrides["ENTER"] == "HANGOUT_FOCUS", "after talking here, Enter opens the Hangout box")
C.fire("CHAT_MSG_SAY", "hello world", C.name)
check(C.overrides["ENTER"] == nil, "after talking in say, Enter belongs to normal chat again")
slash(C, "HANGOUTSAY", "mine again")
check(C.overrides["ENTER"] == "HANGOUT_FOCUS", "and comes back when you talk here again")
C.ns.UI.hide()
check(C.overrides["ENTER"] == nil, "putting the window away hands the key back")
C.ns.UI.window()
slash(C, "HANGOUTSAY", "once more")
slash(C, "HANGOUT", "enter off")
check(C.overrides["ENTER"] == nil, "/ho enter off keeps it off")
slash(C, "HANGOUT", "enter on")
check(C.overrides["ENTER"] == "HANGOUT_FOCUS", "and on gives it back")

print("inline mode: room lines in your normal chat")
C.ns.UI.window()
slash(C, "HANGOUT", "mode inline")
advance(1)
check(not window(C):IsShown(), "no Hangout window in the way")
C.ns.UI.selectRoom(raidId)
local chatBefore = #C.chat._lines
local unreadBefore = C.ns.UI.unreadCount(nightId)
slash(A, "HANGOUTSAY", "inline please")
advance(1)
local inlineLine = C.chat._lines[1]
check(#C.chat._lines > chatBefore and inlineLine:find("inline please", 1, true), "the line lands in the normal chat")
check(inlineLine:find("[Night Owls]", 1, true) and not inlineLine:find("[Hangout]", 1, true), "styled like a channel line")
check(inlineLine:find("12:00", 1, true) == nil, "no timestamp of our own, so it matches your chat settings")
check(C.ns.UI.unreadCount(nightId) == unreadBefore, "an inline line adds no unread: it is already on screen")
C.env.SetItemRef("hangout:" .. nightId, "[Night Owls]", "LeftButton")
check(C.ns.Room.activeId() == nightId, "clicking the room name in chat brings that room to the front")
C.openedChat = nil
slash(C, "HANGOUT", "")
check(C.openedChat == "/hh ", "/ho opens the chat box ready to talk")
check(C.overrides["ENTER"] == "HANGOUT_FOCUS", "and Enter still belongs to the room while you are talking here")
slash(C, "HANGOUT", "mode window")
advance(1)
check(window(C):IsShown(), "and back to the window")

print("picking the colour Hangout draws itself in")
check(C.ns.HEX == "ffffb873", "it starts out the soft orange")
C.ns.UI.setColor(0, 1, 0)
check(C.ns.R == 0 and C.ns.G == 1 and C.ns.B == 0, "a colour can be set")
check(C.ns.HEX == "ff00ff00", "and the hex Hangout writes with follows it")
check(C.ns.db.color[2] == 1, "and it is remembered")
slash(C, "HANGOUT", "color ffb873")
check(C.ns.HEX == "ffffb873", "/ho color takes a hex colour")
C.ns.UI.setColor(0.2, 0.4, 0.6)
slash(C, "HANGOUT", "color reset")
check(C.ns.HEX == "ffffb873", "/ho color reset puts the original back")
C.picked = { 1, 0, 0 }
C.ns.UI.chooseColor()
check(C.colorInfo ~= nil, "/ho color opens Blizzard's picker")
C.colorInfo.swatchFunc()
check(C.ns.HEX == "ffff0000", "and what you pick in it is applied")
C.colorInfo.cancelFunc()
check(C.ns.HEX == "ffffb873", "cancelling puts back what you had")

print("every setting says what it does")
C.ns.UI.settings()
local panel = C.env.HangoutSettings
local explained, bare = 0, 0
for _, f in ipairs(C.frames) do
	if f._parent == panel and f._scripts.OnEnter then
		C.env.GameTooltip._text = nil
		f._scripts.OnEnter(f)
		local text = C.env.GameTooltip._text
		if text and text ~= "" then explained = explained + 1 else bare = bare + 1 end
	end
end
check(bare == 0, ("nothing in the panel is left unexplained (%d bare)"):format(bare))
check(explained >= 15, ("every row and its buttons explain themselves (%d of them)"):format(explained))
C.ns.UI.settings()

print("a stray slash command never reaches the room")
slash(C, "HANGOUTSAY", "/hh kekw")
advance(1)
local strayTo = C.ns.Room.get().name
check(lastGotIn(A, strayTo).text == "kekw", "/hh in front of the message is dropped")
slash(C, "HANGOUTSAY", "/hh /hh still here")
advance(1)
check(lastGotIn(A, strayTo).text == "still here", "even when it got doubled up")
slash(C, "HANGOUTSAY", "/hhx not a command")
advance(1)
check(lastGotIn(A, strayTo).text == "/hhx not a command", "but a word that merely starts with it is left alone")

print("the emote picker putting the line back together")
local pbox = B.env.HangoutInputBox
local function typed(text)
	pbox:SetText(text)
	pbox._scripts.OnTextChanged(pbox, true)
end
local function picked(wrongly, suggestion)
	pbox:SetText(wrongly)
	B.picker.settings.onSuggestionApplied(suggestion)
	return strtrim(pbox:GetText())
end

typed("hello guys :wav")
check(picked("/hh WAVE", "WAVE") == "hello guys WAVE", "words between the command and the emote survive")
typed("/hh hello guys :wav")
check(picked("/hh hello guys /hh WAVE", "WAVE") == "/hh hello guys WAVE", "a repeated command is dropped")
typed("")
check(picked("one two one two KEKW", "KEKW") == "one two KEKW", "a repeated prefix is undone even without the original")
typed("already right KEKW")
check(picked("already right KEKW", "KEKW") == "already right KEKW", "a line that is already right is left alone")
B.ns.db.emoteFix = false
typed("x :wav")
check(picked("/hh WAVE", "WAVE") == "/hh WAVE", "and nothing is touched when the repair is off")
B.ns.db.emoteFix = true
pbox:SetText("")

print("the same repair on Blizzard's own chat box")
local cbox = B.env.ChatFrame1.editBox
cbox.settings = { addSpace = true, onSuggestionApplied = function() end }
B.ns.UI.watchChatPickers()
cbox:SetText("hello guys :wav")
cbox._scripts.OnTextChanged(cbox, true)
cbox:SetText("/hh WAVE")
cbox.settings.onSuggestionApplied("WAVE")
check(strtrim(cbox:GetText()) == "hello guys WAVE", "/hh hello guys :wav keeps your words in normal chat")
cbox:SetText("lol :kek")
cbox._scripts.OnTextChanged(cbox, true)
cbox:SetText("lol lol KEKW")
cbox.settings.onSuggestionApplied("KEKW")
check(strtrim(cbox:GetText()) == "lol KEKW", "and an ordinary line stops repeating itself")

print("slash commands work in the Hangout box")
C.ns.UI.window()
local cmdbox = C.env.HangoutInputBox
local mark = #A.got
C.sentCommand = nil
cmdbox:SetText("/wave")
cmdbox._scripts.OnEnterPressed(cmdbox)
advance(1)
check(C.sentCommand == "/wave", "/wave is handed to the game instead of being said")
check(#A.got == mark, "and nothing is sent to the room")
check(cmdbox:GetText() == "", "the box is cleared either way")
C.sentCommand = nil
cmdbox:SetText("not a command")
cmdbox._scripts.OnEnterPressed(cmdbox)
advance(1)
check(C.sentCommand == nil, "an ordinary line is still talked, not run")
local saidTo = C.ns.Room.get().name
check(lastGotIn(A, saidTo).text == "not a command", "and it reaches the room")
cmdbox:SetText("/hh through the command")
cmdbox._scripts.OnEnterPressed(cmdbox)
advance(1)
check(lastGotIn(A, saidTo).text == "through the command", "/hh typed in the box talks to the room")

print("the box steps back out after you send")
C.ns.UI.window()
local typebox = C.env.HangoutInputBox
typebox:SetFocus()
typebox:SetText("bye")
typebox._scripts.OnEnterPressed(typebox)
advance(1)
check(not typebox:HasFocus(), "the cursor leaves the box once the line is sent")
check(typebox:GetText() == "", "and the box is empty again")
check(C.overrides["ENTER"] == "HANGOUT_FOCUS", "so Enter opens it again for the next line")
local sentTo = C.ns.Room.get().name
check(lastGotIn(A, sentTo) and lastGotIn(A, sentTo).text == "bye", "and the line still went out to " .. sentTo)
C.ns.db.keepTyping = true
typebox:SetFocus()
typebox:SetText("and another")
typebox._scripts.OnEnterPressed(typebox)
advance(1)
check(typebox:HasFocus(), "unless you turn on keep typing")
C.ns.db.keepTyping = false

print("settings: text size and background")
local wasFont = C.ns.UI.fontSize()
check(C.ns.UI.setFontSize(18) == 18, "text size can be set")
check(C.pane._font and C.pane._font[2] == 18, "and reaches the message pane")
check(C.ns.UI.setFontSize(99) == 24, "silly sizes are clamped")
C.ns.UI.setFontSize(wasFont)
check(C.ns.UI.setOpacity(0.5) == 0.5, "background opacity can be set")
check(C.env.HangoutFrame._backdropAlpha == 0.5, "and reaches the window")
slash(C, "HANGOUT", "opacity 70")
check(math.abs(C.ns.db.opacity - 0.7) < 0.001, "/ho opacity 70 means 70 per cent")
check(C.ns.UI.setOpacity(0.01) == 0.1, "and it can never go fully invisible")
C.ns.UI.setOpacity(0.85)
C.ns.UI.settings()
check(C.env.HangoutSettings and C.env.HangoutSettings:IsShown(), "the settings panel opens")
C.ns.UI.settings()
check(not C.env.HangoutSettings:IsShown(), "and closes again")

print("the Invite button fills in your target")
A.target = { "Lyra", "Brightwater" }
A.ns.UI.promptInvite(A.ns.Room.activeId())
check(A.popup and A.popup.which == "HANGOUT_INVITE", "the invite popup opened")
check(A.popup.editBox:GetText() == "Lyra Brightwater", "prefilled with the target's name")

print("saved variables from 1.1.0")
local old = {
	room = {
		id = "oldroom123", name = "Old Gang",
		roster = { ["keeper oldsave"] = { n = "Keeper Oldsave", t = 1, c = "MAGE" } },
	},
	history = { { t = 1, n = "Keeper Oldsave", c = "MAGE", x = "from the old days" } },
}
local E = newClient("Keeper", "Oldsave", "MAGE", false, old)
advance(10)
check(E.ns.Room.count() == 1, "the one old room became one tab")
check(E.ns.Room.get().name == "Old Gang", "with its name kept")
check(#E.ns.Room.history(E.ns.Room.get().id) == 1, "and its history kept")
check(E.env.HangoutCharDB.room == nil and E.env.HangoutCharDB.history == nil, "the old single-room keys are gone")

print("the welcome and /ho help")
local F = newClient("Fresh", "Start", "WARRIOR")
advance(10)
local greeted = false
for _, l in ipairs(F.chat._lines) do if l:find("/ho help", 1, true) then greeted = true end end
check(greeted, "a new player is pointed at /ho help")
check(F.ns.db.welcomed, "the greeting is only said once")
local helpMark = #F.chat._lines
slash(F, "HANGOUT", "help")
check(#F.chat._lines > helpMark + 8, "/ho help lists the commands")
slash(F, "HANGOUT", "rooms")
check(F.chat._lines[1]:find("No rooms yet", 1, true) ~= nil, "/ho rooms with none points at create")
slash(F, "HANGOUT", "nonsense")
check(#F.chat._lines > helpMark + 8, "an unknown command shows the help too")

print("two invites arriving at once")
slash(B, "HANGOUT", "create Team One")
slash(B, "HANGOUT", "create Team Two")
advance(1)
B.ns.Room.invite("Ash Vale", B.ns.Room.byName("Team One").id)
B.ns.Room.invite("Ash Vale", B.ns.Room.byName("Team Two").id)
advance(2)
check(D.env.HangoutInviteFrame:IsShown(), "the first prompt is up")
clickJoin(D)
advance(2)
check(D.env.HangoutInviteFrame:IsShown(), "the second invite waits its turn instead of being dropped")
clickJoin(D)
advance(3)
check(D.ns.Room.count() == 2, "D ends up in both rooms")

print("saying no")
B.ns.Room.invite("Lyra Brightwater", B.ns.Room.byName("Team One").id)
advance(2)
clickDecline(C)
advance(2)
check(C.ns.Room.byName("Team One") == nil, "declining leaves you out of the room")

print("room limit")
for i = 1, 10 do slash(A, "HANGOUT", "create Spare " .. i) end
check(A.ns.Room.count() == A.ns.Room.MAX_ROOMS, ("no more than %d rooms"):format(A.ns.Room.MAX_ROOMS))

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
