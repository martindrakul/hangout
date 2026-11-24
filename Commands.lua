local _, ns = ...

local Commands = {}
ns.Commands = Commands

local function line(text)
	DEFAULT_CHAT_FRAME:AddMessage("   " .. text)
end

local function heading(text)
	DEFAULT_CHAT_FRAME:AddMessage(("  |c%s%s|r"):format(ns.HEX, text))
end

local function help()
	ns.print("commands (anything you type that isn't a command talks in the room):")
	heading("the room")
	line("|cffffffff/ho|r  show or hide the room")
	line("|cffffffff/hh <message>|r  talk in the room from the normal chat box")
	line("|cffffffff/ho create <name>|r  start a room")
	line("|cffffffff/ho invite|r  invite your target, or |cffffffff/ho invite First Last|r")
	line("|cffffffff/ho who|r  who's in the room and who's online")
	line("|cffffffff/ho remove <First Last>|r  take someone out")
	line("|cffffffff/ho leave [room]|r  leave a room")
	heading("several rooms")
	line(("|cffffffff/ho rooms|r  list your rooms (up to %d)"):format(ns.Room.MAX_ROOMS))
	line("|cffffffff/ho switch <room>|r  bring a room to the front (Tab in the box cycles)")
	heading("where it shows up")
	line("|cffffffff/ho mode window|r  the Hangout window (default)")
	line("|cffffffff/ho mode inline|r  your normal chat, like a channel line")
	heading("the window")
	line("|cffffffff/ho window|r  open it,  |cffffffff/ho min|r  fold it into the small box")
	line("|cffffffff/ho settings|r  the gear button: text size, background, alerts")
	line("|cffffffff/ho reset|r  put it back in the middle at its old size")
	heading("settings (all of these are in /ho settings too)")
	line("|cffffffff/ho font <8-24>|r,  |cffffffff/ho opacity <10-100>|r")
	line("|cffffffff/ho color|r  pick the colour Hangout draws itself in")
	line("|cffffffff/ho sound on|off|r,  |cffffffff/ho emotes on|off|r")
	line("|cffffffff/ho emotefix on|off|r  repair lines the emote picker rebuilds wrongly")
	line("|cffffffff/ho enter on|off|r  Enter opens the room box after you talk here")
	line("|cffffffff/ho keeptyping on|off|r  stay in the box after sending a line")
	line("|cffffffff/ho alerts|r  unread badges and taskbar flashing")
	line("|cffffffff/ho echo auto|always|never|r  copy room lines to your main chat")
	heading("broken channels")
	line("|cffffffff/ho channels|r  list the chat channels you're in")
	line("|cffffffff/ho cleanup <name>|r  leave all channels starting with <name>")
	line("|cffffffff/ho fixchat|r  what to do when channels are greyed out")
	line("|cffffffff/ho status|r  connection details")
end
Commands.help = help

function Commands.who(roomId)
	local r = ns.Room.get(roomId)
	if not r then
		ns.print("You're not in a room.")
		return
	end
	local parts = {}
	for _, m in ipairs(ns.Room.members(r.id)) do
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

local function rooms()
	local list = ns.Room.ordered()
	if #list == 0 then
		ns.print("No rooms yet. |cffffffff/ho create <name>|r, or ask a friend to invite you.")
		return
	end
	local activeId = ns.Room.activeId()
	ns.print(("your rooms (%d of %d):"):format(#list, ns.Room.MAX_ROOMS))
	for _, r in ipairs(list) do
		local unread = ns.UI.unreadCount(r.id)
		line(("%s|c%s%s|r  |cff9d9d9d%d online%s|r"):format(
			r.id == activeId and "> " or "  ",
			ns.HEX, r.name,
			ns.Room.onlineCount(r.id),
			unread > 0 and (", " .. unread .. " unread") or ""))
	end
end

local function switch(rest)
	if strtrim(rest) == "" then
		rooms()
		return
	end
	local r = ns.Room.byName(rest)
	if not r then
		ns.print(("No room called \"%s\". |cffffffff/ho rooms|r lists them."):format(rest))
		return
	end
	ns.UI.selectRoom(r.id)
	ns.print(("Now talking in %s."):format(r.name))
end

local function onOff(value, current)
	if value == "on" then return true end
	if value == "off" then return false end
	return not current
end

local function alerts(rest)
	local what, value = rest:match("^(%S*)%s*(%S*)$")
	what = what and strlower(what) or ""
	value = value and strlower(value) or ""
	local a = ns.db.alerts
	if what == "taskbar" then
		a.taskbar = onOff(value, a.taskbar)
	elseif what == "badge" then
		a.badge = onOff(value, a.badge)
	elseif what ~= "" then
		ns.print("|cffffffff/ho alerts taskbar on|off|r or |cffffffff/ho alerts badge on|off|r")
		return
	end
	ns.print("alerts:")
	line(("unread badge on the tab: |cffffffff%s|r"):format(a.badge and "on" or "off"))
	line(("flash WoW in the taskbar: |cffffffff%s|r"):format(a.taskbar and "on" or "off"))
	line(("whisper sound: |cffffffff%s|r  (|cffffffff/ho sound on|off|r)"):format(ns.db.sound and "on" or "off"))
end

local MODES = {
	window = "the Hangout window",
	inline = "your normal chat, like a channel line",
}

local function mode(rest)
	local want = strlower(strtrim(rest))
	if not MODES[want] then
		ns.print(("Room lines show up in: |cffffffff%s|r (%s)."):format(ns.db.mode, MODES[ns.db.mode] or "?"))
		line("|cffffffff/ho mode window|r  the Hangout window")
		line("|cffffffff/ho mode inline|r  your normal chat, like a channel line")
		return
	end
	if want == ns.db.mode then
		ns.print(("Already using %s."):format(MODES[want]))
		return
	end
	ns.UI.setMode(want)
	if want == "inline" then
		ns.print("Room lines show up in your normal chat now. Talk with |cffffffff/hh <message>|r, or |cffffffff/ho|r to start typing.")
		line("Click a room name in chat to bring that room to the front.")
	else
		ns.print("Back to the Hangout window.")
	end
end

local function status()
	local r = ns.Room.get()
	ns.print(("version %s, you are %s"):format(ns.VERSION, tostring(ns.me)))
	line(("rooms: %d, in front: %s"):format(ns.Room.count(), r and r.name or "none"))
	line(("lines in: %s"):format(MODES[ns.db.mode] or ns.db.mode))
	line(("window: %s, text size %d, background %d%%"):format(
		ns.db.minimized and "minimized" or (ns.db.shown and "open" or "closed"),
		ns.UI.fontSize(), math.floor(((ns.db.opacity or 0.85) * 100) + 0.5)))
	line(("friends online: %d, messages waiting to send: %d"):format(ns.Room.onlineCount(), ns.Comm.queued()))
	-- The flag and an actual refusal are different things: the client can say chat is
	-- restricted while our whispers still get through.
	line(("chat restricted flag: %s, actually being refused: %s"):format(
		ns.lockdown() and "on" or "off", ns.Comm.lockedOut and "yes" or "no"))
	line(("reportable (logged) messages: %s"):format(ns.Comm.usingLogged() and "yes" or "no"))
end

-- Said once, the first time Hangout loads on an account.
local function welcome()
	if ns.db.welcomed then return end
	ns.db.welcomed = true
	if ns.Room.count() > 0 then
		ns.print("updated. New: several rooms as tabs, alerts, and a minimize button.")
		line("The window folds into a small box that lights up when someone talks.")
		line("|cffffffff/ho help|r lists everything.")
		return
	end
	ns.print("hello! A private chat room for you and your friends, no chat channels involved.")
	line("|cffffffff/ho create <name>|r starts a room, then |cffffffff/ho invite First Last|r adds a friend.")
	line("|cffffffff/ho|r opens it, |cffffffff/hh <message>|r talks from the normal chat box.")
	line("|cffffffff/ho help|r lists every command.")
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
	elseif cmd == "help" or cmd == "commands" or cmd == "?" then
		help()
	elseif cmd == "create" or cmd == "new" then
		ns.Room.create(rest)
	elseif cmd == "invite" or cmd == "inv" or cmd == "add" then
		ns.Room.invite(rest)
	elseif cmd == "who" or cmd == "list" then
		Commands.who()
	elseif cmd == "rooms" or cmd == "tabs" then
		rooms()
	elseif cmd == "switch" or cmd == "room" or cmd == "go" then
		switch(rest)
	elseif cmd == "remove" or cmd == "kick" then
		ns.Room.remove(rest)
	elseif cmd == "leave" then
		local r = rest ~= "" and ns.Room.byName(rest) or ns.Room.get()
		if rest ~= "" and not r then
			ns.print(("No room called \"%s\"."):format(rest))
		else
			ns.Room.leave(r and r.id)
		end
	elseif cmd == "window" or cmd == "open" then
		ns.UI.window()
	elseif cmd == "min" or cmd == "minimize" then
		ns.UI.minimize()
	elseif cmd == "mode" then
		mode(rest)
	elseif cmd == "settings" or cmd == "options" or cmd == "config" then
		ns.UI.settings()
	elseif cmd == "font" or cmd == "fontsize" or cmd == "text" then
		local size = ns.UI.setFontSize(strtrim(rest))
		if size then
			ns.print(("Text size: %d"):format(size))
		else
			ns.print(("Text size is %d. |cffffffff/ho font 14|r, anything from 8 to 24."):format(ns.UI.fontSize()))
		end
	elseif cmd == "opacity" or cmd == "alpha" or cmd == "background" then
		local value = tonumber(strtrim(rest))
		if value then
			local a = ns.UI.setOpacity(value > 1 and value / 100 or value)
			ns.print(("Background: %d%%"):format(math.floor(a * 100 + 0.5)))
		else
			ns.print(("Background is %d%%. |cffffffff/ho opacity 70|r, anything from 10 to 100."):format(
				math.floor(((ns.db.opacity or 0.85) * 100) + 0.5)))
		end
	elseif cmd == "color" or cmd == "colour" then
		local want = strlower(strtrim(rest))
		if want == "reset" or want == "default" then
			ns.UI.resetColor()
			ns.print("Colour: back to the original orange.")
		elseif want == "" then
			ns.UI.chooseColor()
		else
			local hex = want:match("^#?(%x%x%x%x%x%x)$")
			if not hex then
				ns.print("|cffffffff/ho color|r opens the picker, or give it a hex colour like |cffffffff/ho color ffb873|r.")
			else
				ns.UI.setColor(tonumber(hex:sub(1, 2), 16) / 255,
					tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255)
				ns.print(("Colour: |c%s%s|r"):format(ns.HEX, hex))
			end
		end
	elseif cmd == "enter" then
		ns.db.enterKey = onOff(strlower(rest), ns.db.enterKey)
		ns.UI.applyEnterKey()
		ns.print(("Enter opens the Hangout box after you talk here: %s"):format(ns.db.enterKey and "on" or "off"))
	elseif cmd == "keeptyping" or cmd == "stay" then
		ns.db.keepTyping = onOff(strlower(rest), ns.db.keepTyping)
		ns.print(("Keep typing after sending: %s"):format(ns.db.keepTyping and "on" or "off"))
	elseif cmd == "alerts" or cmd == "alert" then
		alerts(rest)
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
	elseif cmd == "emotefix" then
		ns.db.emoteFix = onOff(strlower(rest), ns.db.emoteFix)
		ns.print(("Repair the Twitch Emotes picker: %s"):format(ns.db.emoteFix and "on" or "off"))
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

ns.on("HANGOUT_LOGIN", function()
	-- After the usual login chatter, so it doesn't scroll straight past.
	C_Timer.After(4, welcome)
end)
