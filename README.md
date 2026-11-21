# Hangout

Chat rooms for you and your friends in WoW Forever that don't use custom chat channels.

Right now, Forever's `/join` channels split people who are on different servers behind the scenes. Friends land in separate copies of the same channel, can't see each other, or can't reply. Hangout skips channels completely. Every line you type is sent straight to each friend in the room as a hidden whisper. Each person's copy of Hangout keeps the member list in sync with everyone else's.

## Install

Everyone in the group needs Hangout.

- **CurseForge app (recommended):** search for Hangout, pick your WoW Forever install, and click Install. The app keeps it up to date.
- **By hand:** put the `Hangout` folder in your Forever AddOns folder, usually `World of Warcraft\_forever_\Interface\AddOns\`, then restart the game or type `/reload`. Copies installed by hand don't update themselves.

Twitch Emotes v2 is optional. If you have it, emotes show up as pictures in the room.

## Getting started

1. One person creates the room: `/ho create Night Owls`
2. They invite each friend: `/ho invite Moorwyn Stormgaard`. You can also target the friend and type `/ho invite`, or click **Invite** in the window, which fills in whoever you have targeted.
3. The friend clicks **Join**. After that, anyone in the room can invite more people.

Membership is remembered. When you log in, Hangout finds whoever from the room is online by itself.

`/ho help` lists every command, grouped by what you're trying to do.

## Talking

- `/ho` opens or closes the room. Type in the box at the bottom and press Enter. Sending steps back out of the box, like the normal chat box, so Enter opens it again for your next line. `/ho keeptyping on` keeps the cursor in the box instead.
- `/hh your message` talks to the room from the normal chat box.
- **Slash commands work in the Hangout box.** `/wave`, `/sit`, `/reload`, `/w Name hi`, another addon's commands: anything that works in the normal chat box works here. Only lines that don't start with `/` are said in the room, so `/dance` dances rather than being typed out.
- **Links:** click into the Hangout box, then shift-click an item, a quest in your quest log, or a link in chat. You can also type `/hh ` in normal chat and shift-click links there as usual. In the room, links can be clicked and show tooltips on hover. Quest links work too, because nothing goes through a server channel that could strip them.
- **Emote picker fix:** Twitch Emotes rebuilds your whole line when you pick an emote from its list, and gets it wrong when there's a slash command in front (`/hh hello guys :wav` loses the middle) or repeats your words when there isn't. Hangout repairs the line in its own box and in your normal chat boxes. `/ho emotefix off` if you'd rather it didn't.
- **Emotes:** with Twitch Emotes v2 installed, type `:` in the Hangout box to get the same emote picker as in normal chat. Emote words show up as pictures for everyone in the room who has Twitch Emotes, animated ones included, and hovering one names it. Friends without it see the plain word.
- Key bindings: Options > Keybindings > AddOns > Hangout.

## Several rooms

You can be in up to eight rooms at once, each with its own tab, members and history.

- Click a tab to switch, or press **Tab** in the message box to cycle through them.
- Press **+** on the tab strip to start another room, or use `/ho create <name>`.
- `/ho rooms` lists them with who's online and what you haven't read. `/ho switch <room>` brings one to the front.
- `/hh` and `/ho invite` always mean the room that's in front.
- **Right-click a tab** to invite someone, see who's there, or leave that room.
- Hover the window's title bar to see everyone in the room and who's online, or type `/ho who`.

## Where it shows up

- `/ho mode window` (the default) keeps room lines in the Hangout window.
- `/ho mode inline` has no window at all: room lines appear in your normal chat alongside Guild and Loot, written the way a channel line is written.

  ```
  [Night Owls] Boa Woa: raid at 8
  ```

  Click the room name to bring that room to the front. Talk with `/hh your message`, or press `/ho` (or Enter) to open the chat box already pointed at the room. There's no timestamp of Hangout's own, so the line matches whatever your chat settings already do.

A note on the numbers real channels have, like `[8. peepos]`: Hangout can't have one. Those come from the server's list of joined channels, and that list is the thing that breaks on Forever, which is the reason Hangout exists. The room name is the closest thing to it, and unlike a number it always points at the right room.

## The window

- `/ho` opens and closes it. Drag the title bar to move it, the corner to resize it, and `/ho reset` puts it back in the middle.
- **Minimize** (the `_` button) folds it into a small box. The box can be dragged anywhere, lights up when someone talks, and shows how many lines you haven't read. Click it to open the window again, or right-click to put it away entirely. `/ho min` does the same thing.
- **Enter** opens the Hangout box when the room is where you last talked, the same way WoW reopens whichever channel you used last. Say something in say, guild, a whisper or anywhere else and the key goes straight back to normal chat, and putting the window away hands it back as well. `/ho enter off` if you'd rather keep Enter for normal chat always.
- `/ho echo auto|always|never` decides whether lines are also copied into your main chat while you can't see the room. Copies read like a channel line, and the room name is clickable:

  ```
  [Night Owls] Boa Woa: raid at 8
  ```

  They don't carry a timestamp of Hangout's own, so they match whatever your chat settings already do.

## Settings

The gear button in the title bar opens a small panel with everything in it, and `/ho settings` does the same. Hover any row to see what it does and what changes when you turn it on. Each one is also a command if you prefer typing:

- **Colour:** click the swatch for Blizzard's colour picker, or `/ho color ffb873`. It colours room lines, room names, the tabs and the minimized box. Right-click the swatch (or `/ho color reset`) for the original orange.
- **Text size:** `/ho font 14`, anything from 8 to 24. Starts from whatever your chat font uses.
- **Background:** `/ho opacity 70` makes the window 70% solid, down to 10% for nearly see-through. The minimized box follows it.
- **Lines show up in** (the window or your normal chat), **whisper sound**, **Twitch emotes**, **fix the emote picker**, **Enter opens Hangout**, **keep typing after sending**, **unread badges**, **flash taskbar**, and **copy lines to chat**.

### Alerts

`/ho alerts` shows what's on. All of it is optional.

- **Unread badge** (on by default): the number of unread lines sits on the room's tab, and on the minimized box, which also lights up. `/ho alerts badge off` turns it off. Inline mode has nothing to count, since the lines are already in front of you.
- **Taskbar flash** (off by default): `/ho alerts taskbar on` blinks WoW in the Windows taskbar when a line arrives while you're in another window.
- **Sound** (on by default): the whisper sound plays for lines in a room you aren't looking at. `/ho sound off` turns it off.

## Fixing the channel mess

- `/ho channels` lists every channel you're in.
- `/ho cleanup name` shows which channels starting with "name" would be left (name1, name2, name510, ...). Then `/ho cleanup name confirm` leaves them. General, Trade and the other built-in channels are never touched.
- `/ho fixchat` explains what to do when channels are greyed out and can't be selected. You rename a chat settings file while the game is closed.

## All commands

```
/ho                     show or hide the room
/hh <message>           talk in the room
/ho help                every command, grouped
/ho create <name>       start a room
/ho invite <First Last> invite someone (or target them)
/ho who                 who's in the room and who's online
/ho remove <First Last> take someone out of the room
/ho leave [room]        leave a room
/ho rooms               list your rooms
/ho switch <room>       bring a room to the front
/ho mode window|inline  where room lines show up
/ho window              open the window
/ho min                 fold it into the small box
/ho settings            text size, background, sounds, alerts
/ho color [hex|reset]   the colour Hangout draws itself in
/ho font <8-24>         text size
/ho opacity <10-100>    how solid the background is
/ho enter on|off        Enter opens the Hangout box after you talk here
/ho keeptyping on|off   stay in the box after sending a line
/ho alerts              unread badges and taskbar flashing
/ho echo auto|always|never   copy room lines to main chat
/ho sound on|off
/ho emotes on|off
/ho emotefix on|off     repair lines the emote picker rebuilds wrongly
/ho channels            list your chat channels
/ho cleanup <name>      leave broken channels starting with <name>
/ho fixchat             help for greyed-out channels
/ho reset               put the window back in the middle
/ho status              connection details
/ho debug               show what Hangout is doing
```

## Limits

- Friends need to be on the same faction. Forever keeps Horde and Alliance chat apart.
- During boss encounters, Blizzard blocks addons from sending chat. Your lines wait and go out when the fight ends. Incoming lines still arrive.
- Trial and Veteran accounts can't send addon messages, so they can read but not talk.
- Friends who log in show up after a few seconds. If someone doesn't, typing in the room makes Hangout check on them again. Otherwise it checks every 5 minutes.
