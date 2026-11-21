-- Hangout: a chat room for friends on WoW Forever.
--
-- Custom chat channels (/join name) are unreliable on Forever: players on different
-- internal servers end up in separate copies of the same channel, and addon messages
-- sent into a channel are accepted but never delivered. Hangout skips channels
-- entirely and whispers every message (as a hidden addon message) to each friend in
-- the room. Each copy of the addon keeps the member list in sync with the others.

local ADDON, ns = ...

-- The release build swaps "@project-version@" in the .toc for the git tag (v1.2.3).
local function tocVersion()
	local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	local v = getMetadata and getMetadata(ADDON, "Version")
	if type(v) ~= "string" or v == "" or v:find("@", 1, true) then return "dev" end
	return (v:gsub("^v", ""))
end

ns.VERSION = tocVersion()
ns.HEX = "ffffb873"                 -- room colour (soft orange)
ns.R, ns.G, ns.B = 1.0, 0.72, 0.45

local defaults = {
	echo = "auto",   -- "auto": copy room lines to the main chat while the window is closed
	sound = true,    -- whisper sound for new lines while the window is closed
	emotes = true,   -- run Twitch Emotes (and other chat filters) over room lines
	debug = false,
	shown = false,
}

local function copyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then dst[k] = v end
	end
end

-- WoW: under Midnight-era rules some event arguments are "secret" and can't be read.
function ns.readable(v)
	return type(v) == "string" and not (issecretvalue and issecretvalue(v))
end

function ns.now()
	return GetServerTime()
end

-- Lower-case lookup key for a character name ("Moorwyn Stormgaard" -> "moorwyn stormgaard").
function ns.key(name)
	if not ns.readable(name) or name == "" then return nil end
	local short = Ambiguate and Ambiguate(name, "none") or name
	short = strtrim(short)
	if short == "" then return nil end
	return strlower(short)
end

local function surnameSeparator()
	local consts = Constants and Constants.CharacterNameSeparatorConsts
	return consts and consts.CHARACTERNAME_SURNAME_SEPARATOR or " "
end

-- WoW Forever: UnitName returns first name and surname; whispers take "First Last".
function ns.unitFullName(unit)
	local first, second = UnitName(unit)
	if not ns.readable(first) then return nil end
	if ns.readable(second) and second ~= "" then
		return first .. surnameSeparator() .. second
	end
	return first
end

function ns.myName()
	return ns.unitFullName("player")
end

-- Tidy a typed name: "moorwyn   stormgaard" -> "Moorwyn Stormgaard".
function ns.normalizeName(input)
	if not ns.readable(input) then return nil end
	local s = strtrim(input)
	if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
		-- Forever also accepts "First-Last"; keep one spelling so keys match.
		s = s:gsub("%-", " ")
	end
	s = s:gsub("%s+", " ")
	if s == "" then return nil end
	local parts = {}
	for word in s:gmatch("%S+") do
		parts[#parts + 1] = word:sub(1, 1):upper() .. word:sub(2):lower()
	end
	return table.concat(parts, " ")
end

function ns.classHex(classFile)
	if classFile and classFile ~= "" then
		local c = C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classFile)
		if c and c.GenerateHexColor then return c:GenerateHexColor() end
		local rc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
		if rc and rc.colorStr then return rc.colorStr end
	end
	return "ffd8d8d8"
end

function ns.lockdown()
	if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
		return C_ChatInfo.InChatMessagingLockdown() and true or false
	end
	return false
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

function ns.base36(n)
	n = math.floor(n or 0)
	if n <= 0 then return "0" end
	local s = ""
	while n > 0 do
		local d = n % 36
		s = DIGITS:sub(d + 1, d + 1) .. s
		n = math.floor(n / 36)
	end
	return s
end

function ns.randomId(len)
	local t = {}
	for i = 1, len do
		local d = math.random(1, 36)
		t[i] = DIGITS:sub(d, d)
	end
	return table.concat(t)
end

function ns.print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(("|c%sHangout|r: %s"):format(ns.HEX, msg))
end

function ns.debug(fmt, ...)
	if ns.db and ns.db.debug then
		ns.print("|cff888888" .. fmt:format(...) .. "|r")
	end
end

-- Tiny event hub. Names starting with HANGOUT_ are internal and never registered.
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns.on(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		if not event:find("^HANGOUT_") then
			local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
			if not ok then ns.debug("event %s isn't available on this client", event) end
		end
	end
	table.insert(handlers[event], fn)
end

function ns.fire(event, ...)
	local list = handlers[event]
	if not list then return end
	for _, fn in ipairs(list) do fn(...) end
end

eventFrame:SetScript("OnEvent", function(_, event, ...) ns.fire(event, ...) end)

ns.on("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	HangoutDB = HangoutDB or {}
	copyDefaults(HangoutDB, defaults)
	HangoutCharDB = HangoutCharDB or {}
	HangoutCharDB.history = HangoutCharDB.history or {}
	ns.db, ns.char = HangoutDB, HangoutCharDB
	ns.fire("HANGOUT_INIT")
end)

ns.on("PLAYER_LOGIN", function()
	ns.me = ns.myName()
	ns.meKey = ns.key(ns.me)
	ns.myClass = select(2, UnitClass("player")) or ""
	ns.fire("HANGOUT_LOGIN")
end)
