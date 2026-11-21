local _, ns = ...

local function help()
	ns.print("commands:")
	local lines = {
		"/ho  - show or hide the window",
		"/hh <message>  - talk in the room from the normal chat box",
		"/ho create <room name>  - start a room",
		"/ho invite <First Last>  - invite a friend (or target them and type /ho invite)",
		"/ho who  - who's in the room and who's online",
		"/ho remove <First Last>  - take someone out of the room",
		"/ho leave  - leave the room",
		"/ho channels  - list the chat channels you're in",
		"/ho cleanup <name>  - leave all channels starting with <name> (name1, name2, ...)",
		"/ho fixchat  - what to do when channels are greyed out",
		"/ho echo auto|always|never  - copy room lines to your main chat",
		"/ho sound on|off,  /ho emotes on|off,  /ho reset (window position)",
		"/ho status  - connection details",
	}
	for _, line in ipairs(lines) do
		DEFAULT_CHAT_FRAME:AddMessage("   " .. line)
	end
end

local function who()
	local r = ns.Room.get()
	if not r then
		ns.print("You're not in a room.")
		return
	end
	local parts = {}
	for _, m in ipairs(ns.Room.members()) do
		local label = ("|c%s%s|r"):format(ns.classHex(m.class), m.name)
		if m.me then
			label = label .. " (you)"
		elseif not m.online then
			label = label .. " |cff9d9d9d(offline)|r"
		end
		parts[#parts + 1] = label
	end
	ns.print(("%s: %s"):format(r.name, table.concat(parts, ", ")))
end

local function onOff(value, current)
	if value == "on" then return true end
	if value == "off" then return false end
	return not current
end

local function status()
	local r = ns.Room.get()
	ns.print(("version %s, you are %s"):format(ns.VERSION, tostring(ns.me)))
	DEFAULT_CHAT_FRAME:AddMessage(("   room: %s"):format(r and (r.name .. " (" .. r.id .. ")") or "none"))
	DEFAULT_CHAT_FRAME:AddMessage(("   friends online: %d, messages waiting to send: %d"):format(ns.Room.onlineCount(), ns.Comm.queued()))
	DEFAULT_CHAT_FRAME:AddMessage(("   boss-fight chat lock: %s, reportable (logged) messages: %s"):format(
		ns.lockdown() and "on" or "off", ns.Comm.usingLogged() and "yes" or "no"))
end

SLASH_HANGOUT1 = "/hangout"
SLASH_HANGOUT2 = "/ho"
SlashCmdList.HANGOUT = function(msg)
	msg = strtrim(msg or "")
	local cmd, rest = msg:match("^(%S+)%s*(.*)$")
	cmd = cmd and strlower(cmd) or ""
	rest = rest or ""

	if cmd == "" then
		ns.UI.toggle()
	elseif cmd == "help" then
		help()
	elseif cmd == "create" or cmd == "new" then
		ns.Room.create(rest)
	elseif cmd == "invite" or cmd == "inv" or cmd == "add" then
		ns.Room.invite(rest)
	elseif cmd == "who" or cmd == "list" then
		who()
	elseif cmd == "remove" or cmd == "kick" then
		ns.Room.remove(rest)
	elseif cmd == "leave" then
		ns.Room.leave()
	elseif cmd == "channels" then
		ns.Channels.list()
	elseif cmd == "cleanup" then
		local prefix, confirm = rest:match("^(%S+)%s*(%S*)$")
		ns.Channels.cleanup(prefix, confirm and strlower(confirm) == "confirm")
	elseif cmd == "fixchat" then
		ns.Channels.fixHelp()
	elseif cmd == "echo" then
		local v = strlower(rest)
		if v == "auto" or v == "always" or v == "never" then ns.db.echo = v end
		ns.print(("Copy to main chat: %s"):format(ns.db.echo))
	elseif cmd == "sound" then
		ns.db.sound = onOff(strlower(rest), ns.db.sound)
		ns.print(("Sound: %s"):format(ns.db.sound and "on" or "off"))
	elseif cmd == "emotes" then
		ns.db.emotes = onOff(strlower(rest), ns.db.emotes)
		ns.print(("Emotes: %s"):format(ns.db.emotes and "on" or "off"))
	elseif cmd == "reset" then
		ns.UI.resetPosition()
	elseif cmd == "status" then
		status()
	elseif cmd == "debug" then
		ns.db.debug = not ns.db.debug
		ns.print(("Debug: %s"):format(ns.db.debug and "on" or "off"))
	else
		help()
	end
end

SLASH_HANGOUTSAY1 = "/hh"
SlashCmdList.HANGOUTSAY = function(msg)
	ns.Room.say(msg or "")
end
