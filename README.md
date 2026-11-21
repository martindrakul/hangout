# Hangout

A chat room for you and your friends in WoW Forever that doesn't use custom chat channels.

Right now, Forever's `/join` channels split people who are on different servers behind the scenes. Friends land in separate copies of the same channel, can't see each other, or can't reply. Hangout skips channels completely. Every line you type is sent straight to each friend in the room as a hidden whisper. Each person's copy of Hangout keeps the member list in sync with everyone else's.

## Install

Everyone in the group needs Hangout.

- **CurseForge app (recommended):** search for Hangout, pick your WoW Forever install, and click Install. The app keeps it up to date.
- **By hand:** put the `Hangout` folder in your Forever AddOns folder, usually `World of Warcraft\_forever_\Interface\AddOns\`, then restart the game or type `/reload`. Copies installed by hand don't update themselves.

Twitch Emotes v2 is optional. If you have it, emotes show up as pictures in the room.

## Getting started

1. One person creates the room: `/ho create Night Owls`
2. They invite each friend: `/ho invite Moorwyn Stormgaard`. You can also target the friend and type `/ho invite`.
3. The friend clicks **Join**. After that, anyone in the room can invite more people.

Membership is remembered. When you log in, Hangout finds whoever from the room is online by itself.

## Talking

- `/ho` opens or closes the window. Type in the box at the bottom and press Enter.
- `/hh your message` talks to the room from the normal chat box.
- **Links:** click into the Hangout box, then shift-click an item, a quest in your quest log, or a link in chat. You can also type `/hh ` in normal chat and shift-click links there as usual. In the room, links can be clicked and show tooltips on hover. Quest links work too, because nothing goes through a server channel that could strip them.
- **Emotes:** with Twitch Emotes v2 installed, type `:` in the Hangout box to get the same emote picker as in normal chat. Emote words show up as pictures for everyone in the room who has Twitch Emotes. Friends without it see the plain word.
- When the window is closed, room lines are copied to your main chat and a whisper sound plays.
- Key bindings: Options > Keybindings > AddOns > Hangout.

## Fixing the channel mess

- `/ho channels` lists every channel you're in.
- `/ho cleanup name` shows which channels starting with "name" would be left (name1, name2, name510, ...). Then `/ho cleanup name confirm` leaves them. General, Trade and the other built-in channels are never touched.
- `/ho fixchat` explains what to do when channels are greyed out and can't be selected. You rename a chat settings file while the game is closed.

## All commands

```
/ho                     show or hide the window
/hh <message>           talk in the room
/ho create <name>       start a room
/ho invite <First Last> invite someone (or target them)
/ho who                 who's in the room and who's online
/ho remove <First Last> take someone out of the room
/ho leave               leave the room
/ho channels            list your chat channels
/ho cleanup <name>      leave broken channels starting with <name>
/ho fixchat             help for greyed-out channels
/ho echo auto|always|never   copy room lines to main chat
/ho sound on|off
/ho emotes on|off
/ho reset               put the window back in the middle
/ho status              connection details
/ho debug               show what Hangout is doing
```

## Limits

- Friends need to be on the same faction. Forever keeps Horde and Alliance chat apart.
- During boss encounters, Blizzard blocks addons from sending chat. Your lines wait and go out when the fight ends. Incoming lines still arrive.
- Trial and Veteran accounts can't send addon messages, so they can read but not talk.
- Friends who log in show up after a few seconds. If someone doesn't, typing in the room makes Hangout check on them again. Otherwise it checks every 5 minutes.
