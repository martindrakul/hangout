-- The room: who is in it, who is online, invites, and chat lines.
--
-- The member list is a last-write-wins map: every entry carries the server time it
-- was last changed, and newer entries replace older ones when copies are compared.
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

local peers = {}          -- key -> { online, seen, ver, probedAt }
local seenMessages = {}   -- "<key>/<msgId>" -> GetTime()
local invites = {}        -- key -> { n, at, reported }
local lastHeartbeat, lastReprobe, lastSayProbe, aloneNoticeAt = 0, 0, 0, 0

local function room()
	return ns.char and ns.char.room
end

function Room.get()
	return room()
end

local function peer(key)
	local p = peers[key]
	if not p then
		p = {}
		peers[key] = p
	end
	return p
end

function Room.isOnline(key)
	return peers[key] ~= nil and peers[key].online == true
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
local function merge(entries)
	local r = room()
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
					peers[k] = nil
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

function Room.members()
	local r = room()
	local list = {}
	if not r then return list end
	for k, e in pairs(r.roster) do
		if not e.g then
			list[#list + 1] = { key = k, name = e.n, class = e.c, me = k == ns.meKey, online = k == ns.meKey or Room.isOnline(k) }
		end
	end
	table.sort(list, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return list
end

function Room.onlineCount()
	local n = 0
	for _, m in ipairs(Room.members()) do
		if m.online and not m.me then n = n + 1 end
	end
	return n
end

local function onlineNames()
	local r = room()
	local names = {}
	if not r then return names end
	for k, e in pairs(r.roster) do
		if not e.g and k ~= ns.meKey and Room.isOnline(k) then names[#names + 1] = e.n end
	end
	return names
end

local function hello(name, wantReply)
	local r = room()
	if not r then return end
	sendCtrl(name, join("H", r.id, ns.VERSION, ns.myClass or "", wantReply and "r" or ""))
	local k = ns.key(name)
	if k then peer(k).probedAt = GetTime() end
end

function Room.broadcastRoster(exceptKey)
	local r = room()
	if not r then return end
	local payload = encodeRoster(r)
	for k, e in pairs(r.roster) do
		if not e.g and k ~= ns.meKey and k ~= exceptKey and Room.isOnline(k) then
			sendCtrl(e.n, payload)
		end
	end
end

-- Ask every offline member whether they're around. `force` skips the per-person cooldown.
function Room.probeOffline(force)
	local r = room()
	if not r then return end
	local t = GetTime()
	for k, e in pairs(r.roster) do
		if not e.g and k ~= ns.meKey and not Room.isOnline(k) then
			local p = peers[k]
			if force or not p or not p.probedAt or t - p.probedAt > 60 then
				hello(e.n, true)
			end
		end
	end
end

local function cameOnline(key, name)
	local p = peer(key)
	local was = p.online
	p.online, p.seen = true, GetTime()
	if not was then
		ns.UI.note(("%s is here."):format(name))
		ns.UI.refresh()
	end
	return p
end

function Room.markOffline(key)
	local p = peers[key]
	if p and p.online then
		p.online = false
		local r = room()
		local e = r and r.roster[key]
		if e then ns.UI.note(("%s went offline."):format(e.n)) end
		ns.UI.refresh()
	end
end

-- Accept (or refuse) traffic from `sender`. Anyone who knows the room's random id
-- was invited by someone, so unknown senders are added; removed members are refused
-- unless we invited them back.
local function admit(key, sender, class)
	local r = room()
	local e = r.roster[key]
	if e and e.g then
		local inv = invites[key]
		if inv and GetTime() - inv.at < INVITE_VALID then
			e.g, e.t = false, ns.now()
			invites[key] = nil
			Room.broadcastRoster(key)
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
	invites[key] = nil
	return e
end

local function addLine(name, class, text, t, mine)
	local h = ns.char.history
	h[#h + 1] = { t = t, n = name, c = class, x = text }
	while #h > HISTORY do table.remove(h, 1) end
	ns.UI.chat(name, class, text, t, mine)
end

-- Incoming ------------------------------------------------------------------------

local function onHello(sender, key, id, ver, class, flags)
	local r = room()
	if not r or id ~= r.id then return end
	local e = admit(key, sender, class)
	if not e then
		-- They were removed (or left) but their copy doesn't know yet.
		if flags:find("r", 1, true) then sendCtrl(sender, encodeRoster(r)) end
		return
	end
	local p = cameOnline(key, sender)
	p.ver = ver
	if flags:find("r", 1, true) then
		hello(sender, false)
		sendCtrl(sender, encodeRoster(r))
	end
end

local function onRoster(sender, key, id, entries)
	local r = room()
	if not r or id ~= r.id then return end
	local changed, added, removedMe = merge(decodeRoster(entries))
	if removedMe then
		ns.print(("You're no longer in %s (removed by %s)."):format(r.name, sender))
		Room.clear()
		return
	end
	local e = r.roster[key]
	if e and not e.g then cameOnline(key, e.n) end
	if changed then
		Room.broadcastRoster(key)
		ns.UI.refresh()
	end
	for _, name in ipairs(added) do hello(name, true) end
end

local function onInvite(sender, key, id, name)
	local r = room()
	if r and r.id == id then
		hello(sender, true)
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
		local r = room()
		if r and r.id == did then ns.print(("%s said no to the invite."):format(sender)) end
		invites[key] = nil
	end
end)

ns.Comm.listen(ns.Comm.PREFIX_MSG, function(body, sender, key)
	local id, msgId, class, text = body:match("^M~([^~]*)~([^~]*)~([^~]*)~(.*)$")
	local r = room()
	if not id or not r or id ~= r.id then return end
	local e = admit(key, sender, class)
	if not e then return end
	local dedupe = key .. "/" .. msgId
	if seenMessages[dedupe] then return end
	seenMessages[dedupe] = GetTime()
	cameOnline(key, sender)
	text = text:gsub("[\r\n]+", " ")
	addLine(sender, e.c, text, ns.now(), false)
end)

ns.Comm.onOffline = function(key)
	Room.markOffline(key)
	local inv = invites[key]
	if inv and not inv.reported then
		inv.reported = true
		ns.print(("%s isn't online right now."):format(inv.n))
	end
end

-- Actions -------------------------------------------------------------------------

function Room.create(name)
	name = cleanRoomName(name)
	if name == "" then
		ns.print("Give the room a name: |cffffffff/ho create Friends|r")
		return
	end
	local r = room()
	if r then
		ns.print(("You're already in %s. Use |cffffffff/ho leave|r first."):format(r.name))
		return
	end
	r = { id = ns.randomId(10), name = name, roster = {} }
	r.roster[ns.meKey] = { n = ns.me, t = ns.now(), c = ns.myClass }
	ns.char.room = r
	ns.print(("Room %s created. Invite friends with |cffffffff/ho invite First Last|r (they need Hangout too)."):format(name))
	ns.UI.show()
end

function Room.invite(name)
	local r = room()
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
	if Room.isOnline(key) then
		ns.print(("%s is already in the room."):format(name))
		return
	end
	invites[key] = { n = name, at = GetTime() }
	sendCtrl(name, join("I", r.id, r.name))
	ns.print(("Invite sent to %s."):format(name))
end

function Room.acceptInvite(from, id, name)
	local current = room()
	if current and current.id ~= id then Room.leave(true) end
	if not room() then
		local r = { id = id, name = name ~= "" and name or "Hangout", roster = {} }
		r.roster[ns.meKey] = { n = ns.me, t = ns.now(), c = ns.myClass }
		local fk = ns.key(from)
		if fk then r.roster[fk] = { n = from, t = 0 } end
		ns.char.room = r
	end
	hello(from, true)
	sendCtrl(from, encodeRoster(room()))
	ns.print(("You joined %s."):format(room().name))
	ns.UI.refresh()
	ns.UI.show()
end

function Room.declineInvite(from, id)
	sendCtrl(from, "D~" .. id)
end

function Room.leave(quiet)
	local r = room()
	if not r then
		if not quiet then ns.print("You're not in a room.") end
		return
	end
	r.roster[ns.meKey] = { n = ns.me, t = ns.now(), g = true, c = ns.myClass }
	Room.broadcastRoster(nil)
	ns.print(("You left %s."):format(r.name))
	Room.clear()
end

function Room.remove(name)
	local r = room()
	if not r then return end
	name = ns.normalizeName(name)
	local key = ns.key(name)
	local e = key and r.roster[key]
	if not e or e.g then
		ns.print(("%s isn't in the room."):format(name or "?"))
		return
	end
	if key == ns.meKey then return Room.leave() end
	r.roster[key] = { n = e.n, t = ns.now(), g = true, c = e.c }
	peers[key] = nil
	Room.broadcastRoster(nil)
	sendCtrl(e.n, encodeRoster(r))
	ns.print(("Removed %s from the room."):format(e.n))
	ns.UI.refresh()
end

function Room.clear()
	ns.char.room = nil
	wipe(peers)
	wipe(invites)
	ns.UI.refresh()
end

function Room.say(text)
	local r = room()
	if not r then
		ns.print("You're not in a room yet. |cffffffff/ho create <name>|r, or ask a friend to invite you.")
		return
	end
	if not ns.readable(text) then return end
	text = text:gsub("[\r\n]+", " ")
	text = strtrim(text)
	if text == "" then return end
	if #text > 2000 then
		ns.print("That message is too long.")
		return
	end
	local msgId = ns.base36(ns.now()) .. ns.randomId(3)
	local payload = "M~" .. r.id .. "~" .. msgId .. "~" .. (ns.myClass or "") .. "~" .. text
	local targets = onlineNames()
	for _, name in ipairs(targets) do
		ns.Comm.send(ns.Comm.PREFIX_MSG, name, payload, true)
	end
	addLine(ns.me, ns.myClass, text, ns.now(), true)

	local t = GetTime()
	if t - lastSayProbe > SAY_REPROBE then
		lastSayProbe = t
		Room.probeOffline(false)
	end
	if #targets == 0 and t - aloneNoticeAt > 60 then
		aloneNoticeAt = t
		ns.UI.note("Nobody else in the room is online right now.")
	end
	if ns.lockdown() then
		ns.UI.note("Chat is locked during this encounter. Your message goes out when it ends.")
	end
end

local function tick()
	local r = room()
	if not r then return end
	local t = GetTime()
	for k, p in pairs(peers) do
		if p.online and t - (p.seen or 0) > TIMEOUT then Room.markOffline(k) end
	end
	if t - lastHeartbeat >= HEARTBEAT then
		lastHeartbeat = t
		for _, name in ipairs(onlineNames()) do hello(name, false) end
	end
	if t - lastReprobe >= REPROBE then
		lastReprobe = t
		Room.probeOffline(false)
	end
	for k, inv in pairs(invites) do
		if not inv.reported and t - inv.at > INVITE_ANSWER then
			inv.reported = true
			ns.print(("No answer from %s. Are they online, on your faction, with Hangout installed?"):format(inv.n))
		end
		if t - inv.at > INVITE_VALID then invites[k] = nil end
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
