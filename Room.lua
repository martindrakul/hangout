-- The rooms you're in: who's in each one, who's online, invites, and chat lines.
--
-- Every room has a random id and every message on the wire carries it, so one client
-- can keep several rooms apart (one tab each) and copies as old as 1.1.0 still
-- understand us. Nothing in the wire format changed when rooms became plural.
--
-- A room's member list is last-write-wins: every entry carries the server time it was
-- last changed, and newer entries replace older ones when copies are compared.
-- Removed members are kept as "gone" entries so they can't sneak back in.

local _, ns = ...

local Room = {}
ns.Room = Room

local HEARTBEAT = 60      -- tell online friends we're still here
local TIMEOUT = 150       -- no word for this long means they went offline
local REPROBE = 300       -- check on offline friends this often
local SAY_REPROBE = 120   -- ...and also when you talk, at most this often
local INVITE_ANSWER = 60
local INVITE_VALID = 600
local HISTORY = 200
local MAX_ROOMS = 8       -- tabs get silly past this, and every room costs traffic

Room.MAX_ROOMS = MAX_ROOMS

local peers = {}          -- roomId -> key -> { online, seen, ver, probedAt }
local invites = {}        -- roomId -> key -> { n, at, reported }
local seenMessages = {}   -- "<roomId>/<key>/<msgId>" -> GetTime()
local aloneNoticeAt = {}  -- roomId -> when we last said nobody else is online
local lockNoticeAt = {}   -- roomId -> when we last explained the chat lockdown
local lastHeartbeat, lastReprobe, lastSayProbe = 0, 0, 0

-- Rooms and the active tab ---------------------------------------------------------

local function rooms()
	return ns.char and ns.char.rooms or {}
end

function Room.count()
	local n = 0
	for _ in pairs(rooms()) do n = n + 1 end
	return n
end

-- The room whose tab is in front. Falls back to the first one we have if the saved
-- choice points at a room we've since left.
function Room.activeId()
	local c = ns.char
	if not c then return nil end
	if c.active and c.rooms[c.active] then return c.active end
	c.active = nil
	for _, id in ipairs(c.order) do
		if c.rooms[id] then
			c.active = id
			break
		end
	end
	if not c.active then
		for id in pairs(c.rooms) do
			c.active = id
			break
		end
	end
	return c.active
end

function Room.get(id)
	if id then return rooms()[id] end
	local active = Room.activeId()
	return active and rooms()[active] or nil
end

function Room.setActive(id)
	local c = ns.char
	if not c or not c.rooms[id] then return false end
	c.active = id
	return true
end

-- Rooms in tab order, repairing the order list if a save went stale.
function Room.ordered()
	local c = ns.char
	local out = {}
	if not c then return out end
	local seen = {}
	for i = #c.order, 1, -1 do
		local id = c.order[i]
		if not c.rooms[id] or seen[id] then table.remove(c.order, i) else seen[id] = true end
	end
	for _, id in ipairs(c.order) do out[#out + 1] = c.rooms[id] end
	for id, r in pairs(c.rooms) do
		if not seen[id] then
			c.order[#c.order + 1] = id
			out[#out + 1] = r
		end
	end
	return out
end

function Room.byName(name)
	if not ns.readable(name) then return nil end
	local want = strlower(strtrim(name))
	if want == "" then return nil end
	local list = Room.ordered()
	for _, r in ipairs(list) do
		if strlower(r.name) == want then return r end
	end
	for _, r in ipairs(list) do
		if strlower(r.name):sub(1, #want) == want then return r end
	end
	return nil
end

function Room.history(id)
	local c = ns.char
	if not c then return {} end
	id = id or Room.activeId()
	if not id then return {} end
	c.histories[id] = c.histories[id] or {}
	return c.histories[id]
end

-- Presence -------------------------------------------------------------------------

local function peerTable(id)
	local t = peers[id]
	if not t then
		t = {}
		peers[id] = t
	end
	return t
end

local function peer(id, key)
	local t = peerTable(id)
	local p = t[key]
	if not p then
		p = {}
		t[key] = p
	end
	return p
end

function Room.isOnline(key, id)
	id = id or Room.activeId()
	local t = id and peers[id]
	local p = t and t[key]
	return p ~= nil and p.online == true
end

local function invitesFor(id)
	local t = invites[id]
	if not t then
		t = {}
		invites[id] = t
	end
	return t
end

local function cleanRoomName(s)
	if not ns.readable(s) then return "" end
	s = s:gsub("[^%w%s%-_']", "")
	s = s:gsub("%s+", " ")
	s = strtrim(s)
	if #s > 24 then s = strtrim(s:sub(1, 24)) end
	return s
end
Room.cleanRoomName = cleanRoomName

local function join(...)
	return table.concat({ ... }, "~")
end

local function sendCtrl(name, payload)
	ns.Comm.send(ns.Comm.PREFIX_CTRL, name, payload, false)
end

-- Member list on the wire: "name=time=gone=class,name=time=gone=class,..."
local function encodeRoster(r)
	local parts = {}
	for _, e in pairs(r.roster) do
		parts[#parts + 1] = table.concat({ e.n, tostring(e.t or 0), e.g and "1" or "0", e.c or "" }, "=")
	end
	return join("R", r.id, r.name, table.concat(parts, ","))
end
Room.encodeRoster = encodeRoster

local function decodeRoster(s)
	local out = {}
	for item in s:gmatch("[^,]+") do
		local n, t, g, c = item:match("^([^=]+)=(%d+)=([01])=(%u*)$")
		if n then
			out[#out + 1] = { n = n, t = tonumber(t), g = g == "1", c = c ~= "" and c or nil }
		end
	end
	return out
end
Room.decodeRoster = decodeRoster

-- Returns: changed, list of newly added names, whether we ourselves were removed.
local function merge(r, entries)
	local changed, added, removedMe = false, {}, false
	for _, e in ipairs(entries) do
		local k = ns.key(e.n)
		if k then
			local cur = r.roster[k]
			local newer = not cur or e.t > cur.t or (e.t == cur.t and e.g and not cur.g)
			if newer then
				local wasActive = cur ~= nil and not cur.g
				r.roster[k] = { n = e.n, t = e.t, g = e.g, c = e.c or (cur and cur.c) }
				changed = true
				if k == ns.meKey then
					if e.g then removedMe = true end
				elseif e.g then
					peerTable(r.id)[k] = nil
				elseif not wasActive then
					added[#added + 1] = e.n
				end
			elseif cur and e.c and not cur.c then
				cur.c = e.c
			end
		end
	end
	return changed, added, removedMe
end
Room.merge = merge

function Room.members(id)
	local r = Room.get(id)
	local list = {}
	if not r then return list end
	for k, e in pairs(r.roster) do
		if not e.g then
			list[#list + 1] = {
				key = k, name = e.n, class = e.c, me = k == ns.meKey,
				online = k == ns.meKey or Room.isOnline(k, r.id),
			}
		end
	end
	table.sort(list, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return list
end

function Room.onlineCount(id)
	local n = 0
	for _, m in ipairs(Room.members(id)) do
		if m.online and not m.me then n = n + 1 end
	end
	return n
end

local function onlineNames(r)
	local names = {}
	if not r then return names end
	for k, e in pairs(r.roster) do
		if not e.g and k ~= ns.meKey and Room.isOnline(k, r.id) then names[#names + 1] = e.n end
	end
	return names
end

local function hello(r, name, wantReply)
	if not r then return end
	sendCtrl(name, join("H", r.id, ns.VERSION, ns.myClass or "", wantReply and "r" or ""))
	local k = ns.key(name)
	if k then peer(r.id, k).probedAt = GetTime() end
end

function Room.broadcastRoster(r, exceptKey)
	if not r then return end
	local payload = encodeRoster(r)
	for k, e in pairs(r.roster) do
		if not e.g and k ~= ns.meKey and k ~= exceptKey and Room.isOnline(k, r.id) then
			sendCtrl(e.n, payload)
		end
	end
end

-- Ask every offline member of every room whether they're around. `force` skips the
-- per-person cooldown.
function Room.probeOffline(force)
	local t = GetTime()
	for _, r in ipairs(Room.ordered()) do
		for k, e in pairs(r.roster) do
			if not e.g and k ~= ns.meKey and not Room.isOnline(k, r.id) then
				local p = peers[r.id] and peers[r.id][k]
				if force or not p or not p.probedAt or t - p.probedAt > 60 then
					hello(r, e.n, true)
				end
			end
		end
	end
end

local function cameOnline(r, key, name)
	local p = peer(r.id, key)
	local was = p.online
	p.online, p.seen = true, GetTime()
	if not was then
		ns.UI.note(r.id, ("%s is here."):format(name))
		ns.UI.refresh()
	end
	return p
end

function Room.markOffline(key, id)
	local r = Room.get(id)
	local p = r and peers[r.id] and peers[r.id][key]
	if p and p.online then
		p.online = false
		local e = r.roster[key]
		if e then ns.UI.note(r.id, ("%s went offline."):format(e.n)) end
		ns.UI.refresh()
	end
end

-- Accept (or refuse) traffic from `sender`. Anyone who knows a room's random id was
-- invited by someone, so unknown senders are added; removed members are refused unless
-- we invited them back.
local function admit(r, key, sender, class)
	local e = r.roster[key]
	local pending = invitesFor(r.id)
	if e and e.g then
		local inv = pending[key]
		if inv and GetTime() - inv.at < INVITE_VALID then
			e.g, e.t = false, ns.now()
			pending[key] = nil
			Room.broadcastRoster(r, key)
		else
			return nil
		end
	end
	if not e then
		e = { n = sender, t = 0 }
		r.roster[key] = e
	end
	e.n = sender
	if class and class ~= "" then e.c = class end
	pending[key] = nil
	return e
end

local function addLine(roomId, name, class, text, t, mine)
	local h = Room.history(roomId)
	h[#h + 1] = { t = t, n = name, c = class, x = text }
	while #h > HISTORY do table.remove(h, 1) end
	ns.UI.chat(roomId, name, class, text, t, mine)
end

-- Incoming ------------------------------------------------------------------------

local function onHello(sender, key, id, ver, class, flags)
	local r = rooms()[id]
	if not r then return end
	local e = admit(r, key, sender, class)
	if not e then
		-- They were removed (or left) but their copy doesn't know yet.
		if flags:find("r", 1, true) then sendCtrl(sender, encodeRoster(r)) end
		return
	end
	local p = cameOnline(r, key, sender)
	p.ver = ver
	if flags:find("r", 1, true) then
		hello(r, sender, false)
		sendCtrl(sender, encodeRoster(r))
	end
end

local function onRoster(sender, key, id, entries)
	local r = rooms()[id]
	if not r then return end
	local changed, added, removedMe = merge(r, decodeRoster(entries))
	if removedMe then
		ns.print(("You're no longer in %s (removed by %s)."):format(r.name, sender))
		Room.forget(id)
		return
	end
	local e = r.roster[key]
	if e and not e.g then cameOnline(r, key, e.n) end
	if changed then
		Room.broadcastRoster(r, key)
		ns.UI.refresh()
	end
	for _, name in ipairs(added) do hello(r, name, true) end
end

local function onInvite(sender, key, id, name)
	local r = rooms()[id]
	if r then
		-- We're already in this one; just let them know we're here.
		hello(r, sender, true)
		return
	end
	ns.UI.showInvite(sender, id, cleanRoomName(name))
end

ns.Comm.listen(ns.Comm.PREFIX_CTRL, function(body, sender, key)
	local id, ver, class, flags = body:match("^H~([^~]*)~([^~]*)~([^~]*)~([^~]*)$")
	if id then return onHello(sender, key, id, ver, class, flags) end
	local rid, _, entries = body:match("^R~([^~]*)~([^~]*)~(.*)$")
	if rid then return onRoster(sender, key, rid, entries) end
	local iid, iname = body:match("^I~([^~]*)~(.*)$")
	if iid then return onInvite(sender, key, iid, iname) end
	local did = body:match("^D~(.*)$")
	if did then
		local r = rooms()[did]
		if r then
			ns.print(("%s said no to the %s invite."):format(sender, r.name))
			invitesFor(did)[key] = nil
		end
	end
end)

ns.Comm.listen(ns.Comm.PREFIX_MSG, function(body, sender, key)
	local id, msgId, class, text = body:match("^M~([^~]*)~([^~]*)~([^~]*)~(.*)$")
	if not id then return end
	local r = rooms()[id]
	if not r then return end
	local e = admit(r, key, sender, class)
	if not e then return end
	local dedupe = id .. "/" .. key .. "/" .. msgId
	if seenMessages[dedupe] then return end
	seenMessages[dedupe] = GetTime()
	cameOnline(r, key, sender)
	text = text:gsub("[\r\n]+", " ")
	addLine(id, sender, e.c, text, ns.now(), false)
end)

-- Said when the server actually turns a message away, not merely because the client
-- flags chat as restricted: some of what it covers still lets our whispers through.
ns.Comm.onLockdown = function()
	local r = Room.get()
	if not r then return end
	local t = GetTime()
	if t - (lockNoticeAt[r.id] or 0) < 60 then return end
	lockNoticeAt[r.id] = t
	ns.UI.refresh()
	local _, kind = IsInInstance()
	if kind == "pvp" or kind == "arena" then
		ns.UI.note(r.id, "WoW is blocking addon chat in this battleground. Your line goes out when the match ends.")
	else
		ns.UI.note(r.id, "WoW is blocking addon chat during this fight. Your line goes out when it ends.")
	end
end

ns.Comm.onUnlocked = function()
	local r = Room.get()
	if r and lockNoticeAt[r.id] then
		lockNoticeAt[r.id] = nil
		ns.UI.note(r.id, "Chat is working again. Anything you typed has gone out.")
	end
	ns.UI.refresh()
end

-- A whisper that bounced means they're offline everywhere, not just in one room.
ns.Comm.onOffline = function(key)
	for _, r in ipairs(Room.ordered()) do
		Room.markOffline(key, r.id)
		local inv = invites[r.id] and invites[r.id][key]
		if inv and not inv.reported then
			inv.reported = true
			ns.print(("%s isn't online right now."):format(inv.n))
		end
	end
end

-- Actions -------------------------------------------------------------------------

function Room.create(name)
	name = cleanRoomName(name)
	if name == "" then
		ns.print("Give the room a name: |cffffffff/ho create Friends|r")
		return
	end
	if Room.count() >= MAX_ROOMS then
		ns.print(("You're in %d rooms already. Leave one first: |cffffffff/ho leave|r."):format(MAX_ROOMS))
		return
	end
	if Room.byName(name) then
		ns.print(("You're already in a room called %s."):format(name))
		return
	end
	local c = ns.char
	local id = ns.randomId(10)
	local r = { id = id, name = name, roster = {} }
	r.roster[ns.meKey] = { n = ns.me, t = ns.now(), c = ns.myClass }
	c.rooms[id] = r
	c.order[#c.order + 1] = id
	c.histories[id] = {}
	c.active = id
	ns.print(("Room %s created. Invite friends with |cffffffff/ho invite First Last|r (they need Hangout too)."):format(name))
	ns.UI.roomsChanged()
	ns.UI.show()
	return r
end

function Room.invite(name, id)
	local r = Room.get(id)
	if not r then
		ns.print("Create a room first: |cffffffff/ho create <name>|r")
		return
	end
	if not name or name == "" then
		if UnitIsPlayer("target") then name = ns.unitFullName("target") end
	end
	name = ns.normalizeName(name)
	local key = ns.key(name)
	if not key then
		ns.print("Who? |cffffffff/ho invite First Last|r, or target them and type |cffffffff/ho invite|r")
		return
	end
	if key == ns.meKey then return end
	if Room.isOnline(key, r.id) then
		ns.print(("%s is already in %s."):format(name, r.name))
		return
	end
	invitesFor(r.id)[key] = { n = name, at = GetTime() }
	sendCtrl(name, join("I", r.id, r.name))
	ns.print(("Invite to %s sent to %s."):format(r.name, name))
end

function Room.acceptInvite(from, id, name)
	local c = ns.char
	if not c.rooms[id] then
		if Room.count() >= MAX_ROOMS then
			ns.print(("You're in %d rooms already. Leave one first: |cffffffff/ho leave|r."):format(MAX_ROOMS))
			return
		end
		local r = { id = id, name = name ~= "" and name or "Hangout", roster = {} }
		r.roster[ns.meKey] = { n = ns.me, t = ns.now(), c = ns.myClass }
		local fk = ns.key(from)
		if fk then r.roster[fk] = { n = from, t = 0 } end
		c.rooms[id] = r
		c.order[#c.order + 1] = id
		c.histories[id] = c.histories[id] or {}
	end
	c.active = id
	local r = c.rooms[id]
	hello(r, from, true)
	sendCtrl(from, encodeRoster(r))
	ns.print(("You joined %s."):format(r.name))
	ns.UI.roomsChanged()
	ns.UI.show()
end

function Room.declineInvite(from, id)
	sendCtrl(from, "D~" .. id)
end

function Room.leave(id, quiet)
	local r = Room.get(id)
	if not r then
		if not quiet then ns.print("You're not in a room.") end
		return
	end
	r.roster[ns.meKey] = { n = ns.me, t = ns.now(), g = true, c = ns.myClass }
	Room.broadcastRoster(r, nil)
	ns.print(("You left %s."):format(r.name))
	Room.forget(r.id)
end

function Room.remove(name, id)
	local r = Room.get(id)
	if not r then return end
	name = ns.normalizeName(name)
	local key = ns.key(name)
	local e = key and r.roster[key]
	if not e or e.g then
		ns.print(("%s isn't in %s."):format(name or "?", r.name))
		return
	end
	if key == ns.meKey then return Room.leave(r.id) end
	r.roster[key] = { n = e.n, t = ns.now(), g = true, c = e.c }
	peerTable(r.id)[key] = nil
	Room.broadcastRoster(r, nil)
	sendCtrl(e.n, encodeRoster(r))
	ns.print(("Removed %s from %s."):format(e.n, r.name))
	ns.UI.refresh()
end

-- Drop a room and everything we remember about it.
function Room.forget(id)
	local c = ns.char
	if not c or not id then return end
	c.rooms[id] = nil
	c.histories[id] = nil
	for i = #c.order, 1, -1 do
		if c.order[i] == id then table.remove(c.order, i) end
	end
	peers[id] = nil
	invites[id] = nil
	aloneNoticeAt[id] = nil
	if c.active == id then c.active = nil end
	Room.activeId()
	ns.UI.roomsChanged()
end

function Room.say(text, id)
	local r = Room.get(id)
	if not r then
		ns.print("You're not in a room yet. |cffffffff/ho create <name>|r, or ask a friend to invite you.")
		return
	end
	if not ns.readable(text) then return end
	text = text:gsub("[\r\n]+", " ")
	text = strtrim(text)
	-- Chat addons that rewrite the edit box can leave the slash command sitting in
	-- the text (the Twitch Emotes suggestion list does), and people type "/hh" into
	-- the Hangout box out of habit. Either way, don't repeat it into the room.
	while true do
		local rest = text:match("^/hh%s+(.+)$")
		if not rest then break end
		text = strtrim(rest)
	end
	if text == "" then return end
	if #text > 2000 then
		ns.print("That message is too long.")
		return
	end
	local msgId = ns.base36(ns.now()) .. ns.randomId(3)
	local payload = "M~" .. r.id .. "~" .. msgId .. "~" .. (ns.myClass or "") .. "~" .. text
	local targets = onlineNames(r)
	for _, name in ipairs(targets) do
		ns.Comm.send(ns.Comm.PREFIX_MSG, name, payload, true)
	end
	addLine(r.id, ns.me, ns.myClass, text, ns.now(), true)
	ns.UI.talkedHere()

	local t = GetTime()
	if t - lastSayProbe > SAY_REPROBE then
		lastSayProbe = t
		Room.probeOffline(false)
	end
	if #targets == 0 and t - (aloneNoticeAt[r.id] or 0) > 60 then
		aloneNoticeAt[r.id] = t
		ns.UI.note(r.id, ("Nobody else in %s is online right now."):format(r.name))
	end
end

local function tick()
	local list = Room.ordered()
	if #list == 0 then return end
	local t = GetTime()
	local beat = t - lastHeartbeat >= HEARTBEAT
	-- While the game is refusing our messages we can't say hello, so our friends stop
	-- hearing from us and stop answering. The silence is ours, not theirs: don't take
	-- anyone offline over it, or a long battleground empties the room.
	local mute = ns.Comm.lockedOut
	for _, r in ipairs(list) do
		for k, p in pairs(peerTable(r.id)) do
			if p.online and not mute and t - (p.seen or 0) > TIMEOUT then Room.markOffline(k, r.id) end
		end
		if beat then
			for _, name in ipairs(onlineNames(r)) do hello(r, name, false) end
		end
		for k, inv in pairs(invitesFor(r.id)) do
			if not inv.reported and t - inv.at > INVITE_ANSWER then
				inv.reported = true
				ns.print(("No answer from %s. Are they online, on your faction, with Hangout installed?"):format(inv.n))
			end
			if t - inv.at > INVITE_VALID then invitesFor(r.id)[k] = nil end
		end
	end
	if beat then lastHeartbeat = t end
	if t - lastReprobe >= REPROBE then
		lastReprobe = t
		Room.probeOffline(false)
	end
	for k, at in pairs(seenMessages) do
		if t - at > 600 then seenMessages[k] = nil end
	end
end

ns.on("HANGOUT_LOGIN", function()
	lastHeartbeat, lastReprobe = GetTime(), GetTime()
	C_Timer.NewTicker(5, tick)
	-- Give the client a moment to settle after loading, then say hello to everyone.
	C_Timer.After(6, function()
		ns.Comm.selfTest()
		Room.probeOffline(true)
	end)
end)
