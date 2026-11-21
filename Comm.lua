-- Hidden addon whispers: splitting long payloads into chunks, pacing, and
-- reassembly. Everything goes out as WHISPER, because addon messages sent into
-- custom channels are accepted on Forever but never delivered.

local _, ns = ...

local Comm = {}
ns.Comm = Comm

Comm.PREFIX_CTRL = "HangoutC"   -- hellos, member lists, invites
Comm.PREFIX_MSG = "HangoutM"    -- chat lines

local CHUNK = 230               -- addon messages max out at 255 bytes, header included
local MAX_CHUNKS = 40
local PARTIAL_TTL = 30

local Result = (Enum and Enum.SendAddonMessageResult) or {}
local R_SUCCESS = Result.Success or 0
local R_INVALID_MESSAGE = Result.InvalidMessage or 2
local R_THROTTLE = Result.AddonMessageThrottle or 3
local R_CHANNEL_THROTTLE = Result.ChannelThrottle or 8
local R_LOCKDOWN = Result.AddOnMessageLockdown or 11
local R_OFFLINE = Result.TargetOffline or 12
local R_ERROR = "lua-error"

local queue = {}
local buckets = {}
local pausedUntil = 0
local partials = {}
local seq = math.random(0, 46655)
local recentlyWhispered = {}    -- key -> GetTime() of our last whisper to them
local generalFailures = 0
local warnedFailures = false

-- Logged addon messages let recipients report abuse, so Blizzard asks addons that
-- carry player-written text to use them. They only get used once a whisper to
-- ourselves proves they arrive intact on this client.
local loggedOK = false
local loggedStrikes = 0
local testNonce
local TEST_LINK = "|cffffffff|Hitem:6948::::::::1:::::::|h[Hearthstone]|h|r"

Comm.lockedOut = false

local function inInstance()
	local inside = IsInInstance()
	return inside and true or false
end

-- Whispers outside instances aren't throttled per prefix. Inside, each prefix
-- gets 10 messages that refill at 1 per second; stay a little under that.
local function takeToken(prefix)
	if not inInstance() then return true end
	local t = GetTime()
	local b = buckets[prefix]
	if not b then
		b = { tokens = 8, last = t }
		buckets[prefix] = b
	end
	b.tokens = math.min(8, b.tokens + (t - b.last))
	b.last = t
	if b.tokens >= 1 then
		b.tokens = b.tokens - 1
		return true
	end
	return false
end

-- Split text into pieces of at most `size` bytes without cutting a UTF-8 character.
function Comm.split(text, size)
	local chunks = {}
	local i, n = 1, #text
	if n == 0 then return { "" } end
	while i <= n do
		local j = math.min(i + size - 1, n)
		if j < n then
			while j > i do
				local b = text:byte(j + 1)
				if b and b >= 128 and b < 192 then j = j - 1 else break end
			end
		end
		chunks[#chunks + 1] = text:sub(i, j)
		i = j + 1
	end
	return chunks
end

local function rawSend(item)
	local useLogged = item.logged and loggedOK and C_ChatInfo.SendAddonMessageLogged
	local fn = useLogged and C_ChatInfo.SendAddonMessageLogged or C_ChatInfo.SendAddonMessage
	local ok, result = pcall(fn, item.prefix, item.text, "WHISPER", item.target)
	if not ok then
		ns.debug("send error: %s", tostring(result))
		return R_ERROR, useLogged
	end
	if result == nil or result == true then return R_SUCCESS, useLogged end
	return result, useLogged
end

function Comm.dropTarget(key)
	for i = #queue, 1, -1 do
		if queue[i].key == key then table.remove(queue, i) end
	end
end

local function failed(item, result)
	table.remove(queue, 1)
	generalFailures = generalFailures + 1
	ns.debug("dropped a message to %s (result %s)", item.target, tostring(result))
	if generalFailures >= 5 and not warnedFailures then
		warnedFailures = true
		ns.print(("Messages aren't going out (error %s). Trial and Veteran accounts can't send addon messages."):format(tostring(result)))
	end
end

function Comm.pump()
	local t = GetTime()
	if t < pausedUntil or not queue[1] then return end
	local sent = 0
	while queue[1] and sent < 25 do
		if ns.lockdown() then
			Comm.lockedOut = true
			pausedUntil = t + 1
			return
		end
		local item = queue[1]
		if not takeToken(item.prefix) then
			pausedUntil = t + 0.5
			return
		end
		local result, wasLogged = rawSend(item)
		if result == R_SUCCESS then
			table.remove(queue, 1)
			sent = sent + 1
			generalFailures = 0
		elseif result == R_THROTTLE or result == R_CHANNEL_THROTTLE then
			pausedUntil = t + 1
			return
		elseif result == R_LOCKDOWN then
			Comm.lockedOut = true
			pausedUntil = t + 2
			return
		elseif result == R_OFFLINE then
			Comm.dropTarget(item.key)
			if Comm.onOffline then Comm.onOffline(item.key) end
		elseif result == R_INVALID_MESSAGE and wasLogged then
			-- Logged messages are meant for plain text; resend this piece as a normal one.
			item.logged = false
			loggedStrikes = loggedStrikes + 1
			if loggedStrikes >= 3 then loggedOK = false end
		elseif result == R_ERROR and inInstance() and (item.tries or 0) < 5 then
			-- Some instances refuse addon messages outright; try again in a bit.
			item.tries = (item.tries or 0) + 1
			pausedUntil = t + 3
			return
		else
			failed(item, result)
		end
	end
	if not queue[1] then Comm.lockedOut = false end
end

-- Queue `payload` for `target` ("First Last"). Long payloads are chunked as
-- "<id>:<part>:<total>:<data>".
function Comm.send(prefix, target, payload, logged)
	local key = ns.key(target)
	if not key or key == ns.meKey then return false end
	local chunks = Comm.split(payload, CHUNK)
	if #chunks > MAX_CHUNKS then return false end
	seq = (seq + 1) % 46656
	local id = ns.base36(seq)
	for i, piece in ipairs(chunks) do
		queue[#queue + 1] = {
			prefix = prefix, target = target, key = key, logged = logged,
			text = id .. ":" .. i .. ":" .. #chunks .. ":" .. piece,
		}
	end
	recentlyWhispered[key] = GetTime()
	Comm.pump()
	return true
end

function Comm.queued()
	return #queue
end

function Comm.usingLogged()
	return loggedOK
end

function Comm.wasRecentlyWhispered(key, window)
	local t = key and recentlyWhispered[key]
	return t ~= nil and GetTime() - t < (window or 30)
end

function Comm.selfTest()
	if not (C_ChatInfo and C_ChatInfo.SendAddonMessageLogged) or not ns.me then return end
	testNonce = ns.randomId(6)
	local ok, result = pcall(C_ChatInfo.SendAddonMessageLogged, Comm.PREFIX_CTRL,
		"0:1:1:T~" .. testNonce .. "~" .. TEST_LINK, "WHISPER", ns.me)
	ns.debug("logged self-test sent (%s, %s)", tostring(ok), tostring(result))
end

local handlers = {}

function Comm.listen(prefix, fn)
	handlers[prefix] = fn
end

local function deliver(prefix, body, sender, senderKey)
	local fn = handlers[prefix]
	if fn then fn(body, sender, senderKey) end
end

local function onAddonMessage(event, prefix, text, channel, sender)
	if prefix ~= Comm.PREFIX_CTRL and prefix ~= Comm.PREFIX_MSG then return end
	if channel ~= "WHISPER" or not ns.readable(text) or not ns.readable(sender) then return end
	local id, part, total, body = text:match("^(%w+):(%d+):(%d+):(.*)$")
	if not id then return end
	part, total = tonumber(part), tonumber(total)
	if total < 1 or total > MAX_CHUNKS or part < 1 or part > total then return end
	-- Forever names are unique per region, so drop any server suffix.
	if Ambiguate then sender = Ambiguate(sender, "none") end
	local senderKey = ns.key(sender)
	if not senderKey then return end

	if senderKey == ns.meKey then
		if testNonce and event == "CHAT_MSG_ADDON_LOGGED" and body == "T~" .. testNonce .. "~" .. TEST_LINK then
			loggedOK = true
			testNonce = nil
			ns.debug("logged addon messages work here")
		end
		return
	end

	if total == 1 then
		deliver(prefix, body, sender, senderKey)
		return
	end

	local pkey = senderKey .. "/" .. prefix .. "/" .. id
	local p = partials[pkey]
	if not p or p.total ~= total then
		p = { total = total, got = 0, parts = {} }
		partials[pkey] = p
	end
	p.at = GetTime()
	if not p.parts[part] then
		p.parts[part] = body
		p.got = p.got + 1
	end
	if p.got == total then
		partials[pkey] = nil
		deliver(prefix, table.concat(p.parts), sender, senderKey)
	end
end

-- "No player named 'X' is currently playing." follows a whisper to someone who is
-- offline. Spot it so we can mark them offline, and keep it out of chat when it was
-- caused by one of our own hidden whispers.
local notFoundPattern

local function buildPatterns()
	if type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then return end
	local escaped = ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0")
	escaped = escaped:gsub("%%%%s", "(.+)")
	notFoundPattern = "^" .. escaped .. "$"
end

function Comm.notFoundName(text)
	if not notFoundPattern or not ns.readable(text) then return nil end
	return text:match(notFoundPattern)
end

local function systemFilter(_, _, text)
	local name = Comm.notFoundName(text)
	if name and Comm.wasRecentlyWhispered(ns.key(name), 30) then
		return true
	end
	return false
end

ns.on("HANGOUT_INIT", function()
	buildPatterns()
	C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX_CTRL)
	C_ChatInfo.RegisterAddonMessagePrefix(Comm.PREFIX_MSG)
	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then addFilter("CHAT_MSG_SYSTEM", systemFilter) end
	C_Timer.NewTicker(0.1, Comm.pump)
	C_Timer.NewTicker(5, function()
		local t = GetTime()
		for k, p in pairs(partials) do
			if t - p.at > PARTIAL_TTL then partials[k] = nil end
		end
	end)
end)

ns.on("CHAT_MSG_ADDON", function(...) onAddonMessage("CHAT_MSG_ADDON", ...) end)
ns.on("CHAT_MSG_ADDON_LOGGED", function(...) onAddonMessage("CHAT_MSG_ADDON_LOGGED", ...) end)

ns.on("CHAT_MSG_SYSTEM", function(text)
	local name = Comm.notFoundName(text)
	local key = name and ns.key(name)
	if key and Comm.wasRecentlyWhispered(key, 30) then
		Comm.dropTarget(key)
		if Comm.onOffline then Comm.onOffline(key) end
	end
end)
