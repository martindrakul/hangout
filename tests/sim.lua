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
local function newClient(first, last, class, withTE)
	local c = { withTE = withTE, name = first .. " " .. last, online = true, lockdown = false, instance = false,
		prefixes = {}, registered = {}, filters = {}, printed = {} }
	c.key = c.name:lower()
	clients[c.key] = c

	local env = {}
	setmetatable(env, { __index = _G })
	c.env = env

	env.strtrim, env.strlower, env.strupper, env.wipe = strtrim, string.lower, string.upper, wipe
	env.format = string.format
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
	env.hooksecurefunc = function(tbl, key, fn)
		local orig = tbl[key]
		tbl[key] = function(...) local r = orig(...); fn(...); return r end
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
		env.SetupAutoComplete = function(box, list, n, settings) c.picker = { box = box, list = list, settings = settings } end
	end
	local ns = {}
	for _, file in ipairs(FILES) do
		local chunk = assert(loadfile(ADDON_DIR .. "/" .. file))
		setfenv(chunk, env)
		chunk("Hangout", ns)
	end
	c.ns = ns
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
	c.ns.UI.chat = function(name, class, text, t, mine)
		c.got[#c.got + 1] = { name = name, text = text, mine = mine }
		return orig(name, class, text, t, mine)
	end
	local origNote = c.ns.UI.note
	c.notes = {}
	c.ns.UI.note = function(text) c.notes[#c.notes + 1] = text; return origNote(text) end
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

print("logged self-test")
check(A.ns.Comm.usingLogged(), "logged addon messages detected as working")

print("A creates a room and invites B and C")
slash(A, "HANGOUT", "create Night Owls")
check(A.ns.Room.get() and A.ns.Room.get().name == "Night Owls", "room created")
slash(A, "HANGOUT", "invite ironfist dawncrusher")
advance(1)
check(B.env.HangoutInviteFrame and B.env.HangoutInviteFrame:IsShown(), "B sees invite prompt")
B.ns.Room.acceptInvite(B.env.HangoutInviteFrame.data.from, B.env.HangoutInviteFrame.data.id, B.env.HangoutInviteFrame.data.name)
advance(2)
C.target = { "Lyra", "Brightwater" }
A.target = { "Lyra", "Brightwater" }
slash(A, "HANGOUT", "invite")
advance(1)
local d = C.env.HangoutInviteFrame.data
C.ns.Room.acceptInvite(d.from, d.id, d.name)
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
check(#A.chat._lines == echoed + 1 and A.chat._lines[1]:find("[Hangout]", 1, true), "line copied to main chat")
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
d = C.env.HangoutInviteFrame.data
C.ns.Room.acceptInvite(d.from, d.id, d.name)
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

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
