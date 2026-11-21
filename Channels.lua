-- Housekeeping for the pile of broken custom channels (name1, name2, ... name510).

local _, ns = ...

local Channels = {}
ns.Channels = Channels

local PROTECTED = {
	general = true, trade = true, localdefense = true, lookingforgroup = true,
	worlddefense = true, guildrecruitment = true, services = true, newcomerchat = true,
}

local function joined()
	local list = { GetChannelList() }
	local out = {}
	for i = 1, #list, 3 do
		local id, name = list[i], list[i + 1]
		if ns.readable(name) then out[#out + 1] = { id = id, name = name } end
	end
	return out
end

local function isProtected(name)
	local lower = strlower(name)
	if PROTECTED[lower] then return true end
	if EnumerateServerChannels then
		for _, server in ipairs({ EnumerateServerChannels() }) do
			if ns.readable(server) and strlower(server) == lower then return true end
		end
	end
	return false
end

function Channels.list()
	local chans = joined()
	if #chans == 0 then
		ns.print("You're not in any chat channels.")
		return
	end
	ns.print(("You're in %d channels:"):format(#chans))
	for _, c in ipairs(chans) do
		DEFAULT_CHAT_FRAME:AddMessage(("   %d. %s"):format(c.id, c.name))
	end
end

-- Leave every custom channel whose name starts with `prefix`. Without "confirm" it
-- only shows what would be left.
function Channels.cleanup(prefix, confirm)
	prefix = prefix and strlower(strtrim(prefix)) or ""
	if #prefix < 3 then
		ns.print("Give at least 3 letters of the channel name: |cffffffff/ho cleanup name|r")
		return
	end
	local targets = {}
	for _, c in ipairs(joined()) do
		if strlower(c.name):sub(1, #prefix) == prefix and not isProtected(c.name) then
			targets[#targets + 1] = c.name
		end
	end
	if #targets == 0 then
		ns.print(("No custom channels start with \"%s\"."):format(prefix))
		return
	end
	if not confirm then
		ns.print(("This would leave %d channels: %s"):format(#targets, table.concat(targets, ", ")))
		ns.print(("Type |cffffffff/ho cleanup %s confirm|r to leave them."):format(prefix))
		return
	end
	ns.print(("Leaving %d channels..."):format(#targets))
	for i, name in ipairs(targets) do
		C_Timer.After(0.6 * i, function()
			if ns.lockdown() then return end
			LeaveChannelByName(name)
		end)
	end
	C_Timer.After(0.6 * #targets + 1, function()
		ns.print("Done. If a channel still shows up greyed out, see |cffffffff/ho fixchat|r.")
	end)
end

function Channels.fixHelp()
	ns.print("If channels stay greyed out or can't be selected, the saved chat settings on your PC are probably stuck:")
	DEFAULT_CHAT_FRAME:AddMessage("   1. Exit the game completely.")
	DEFAULT_CHAT_FRAME:AddMessage("   2. In your WoW Forever folder, open WTF\\Account\\<account>\\<server>\\<character>\\")
	DEFAULT_CHAT_FRAME:AddMessage("   3. Rename chat-cache.txt to chat-cache.old (renaming lets you undo it).")
	DEFAULT_CHAT_FRAME:AddMessage("   4. Start the game again. That character's chat tabs and channels go back to defaults.")
end
