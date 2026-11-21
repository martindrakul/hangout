# Changelog

## 1.2.0

- Several rooms at once, with a tab each. Click a tab to switch, press Tab in the message box to cycle, or `/ho switch <room>`. Up to eight, each with its own members and history.
- Two places for room lines to live: `/ho mode window` (the default) keeps the Hangout window, and `/ho mode inline` drops the window and writes room lines into your normal chat instead, styled like a channel line with the room name clickable to switch rooms.
- A minimize button. The window folds into a small box you can park anywhere, which lights up and counts what you haven't read when someone talks. Click it to open the window again, right-click to put it away. `/ho min` does the same from the chat box.
- A settings panel behind the gear button in the title bar: the colour Hangout draws itself in (Blizzard's own colour picker, right-click the swatch for the original orange), text size, background opacity, the whisper sound, emotes, alerts and the Enter key. Everything in it also has a command, like `/ho color ffb873`, `/ho font 14` and `/ho opacity 70`.
- Enter opens the Hangout box when the room is where you last talked, and goes straight back to the normal chat box the moment you say something anywhere else. Putting the window away hands the key back too. `/ho enter off` if you'd rather it never did this.
- Slash commands work in the Hangout box. `/wave`, `/sit`, `/reload`, another addon's commands: anything you can type in the normal chat box does the same thing here, because the line is handed to the game's own parser. Only lines that don't start with `/` are said in the room.
- Sending a line steps out of the box, the way the normal chat box does, so Enter opens it again for the next one. `/ho keeptyping on` leaves the cursor there instead.
- Alerts you can turn on: an unread count on each tab, and `/ho alerts taskbar on` to flash WoW in the taskbar while you're in another window.
- An Invite button in the window's title bar that fills in whoever you have targeted, right-click menus on the room tabs, and the member list with class colours and online status on the title-bar tooltip.
- Lines copied into your main chat now read like a channel line, `[Night Owls] Boa Woa: raid at 8`, and the room name is clickable.
- A short greeting the first time Hangout loads, and `/ho help` is now grouped by what you're trying to do.
- An invite that arrives while you're answering another one waits its turn instead of being lost.
- Animated Twitch Emotes now animate in the Hangout window. They were stopping on their first frame, because Twitch Emotes only advances the emotes in Blizzard's own chat windows. Hovering an emote also names it now, the way it does in normal chat.
- Picking an emote from the Twitch Emotes list no longer mangles the line. With a slash command in front, its own rebuild returned `<command> <emote>` and threw away everything typed in between, so `/hh hello guys :wav` arrived as the command and a wave; without one it repeated the words you had typed. Hangout now puts the line back the way you typed it, with the emote in place of the word you were completing, both in its own box and in Blizzard's chat boxes, and a stray `/hh` in front of a room message is dropped. `/ho emotefix off` leaves it alone.
- Your existing room and its history carry over as the first tab.

## 1.1.0

First release on CurseForge.

- New icon in the AddOns list.
- `/ho status` shows the version from the release.

## 1.0.1

- Twitch Emotes: the `:` emote picker now works in the Hangout box.
- Hand-typed `:kekw:` and `:kekw` show the emote picture, without touching links or times like 12:30.
- `/ho create` opens the window.

## 1.0.0

- Chat room for friends that sends each line as a hidden whisper, so it works when custom channels are broken.
- Invites, a shared member list, and online status.
- Item and quest links, with tooltips.
- Twitch Emotes support.
- Messages wait during boss-fight chat lockdowns and go out afterwards.
- `/ho cleanup` to leave piles of broken custom channels.
