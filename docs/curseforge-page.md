# CurseForge project page

Copy these into the project form at authors.curseforge.com.

## Project name

Hangout

If that name is already taken, use **Hangout Rooms**. The addon folder stays `Hangout` either way.

## Summary

Private chat rooms for you and your friends that work even when /join channels break.

## Category and game version

- Main category: **Chat & Communication**
- Game: World of Warcraft, file game version **WoW Forever 1.60.1** (newer Forever versions are fine too)
- License: **MIT**
- Avatar: `hangout-avatar-400.png`

## Description

Paste everything below the line into the description editor.

---

# Hangout

**Chat rooms for you and your friends that don't depend on custom chat channels.**

On WoW Forever, `/join` channels often break when friends are on different servers behind the scenes. People end up in separate copies of the same channel, can't see each other's messages, or can't reply, and you end up making name2, name3, name4…

Hangout skips channels completely. Every line you type goes straight to each friend in the room, and everyone's copy of Hangout keeps the member list in sync.

## Features

- **Several rooms, one tab each:** up to eight, each with its own members and history. Click a tab or press Tab to switch, and unread lines show up as a count on the tab.
- **Its own window, or part of your chat:** keep rooms in the Hangout window, or `/ho mode inline` to drop the window and write room lines into your normal chat like a channel line, `[Night Owls] Boa Woa: raid at 8`, with the room name clickable.
- **Yours to set up:** a settings panel for the colour (Blizzard's own colour picker), text size, background opacity, sounds and alerts. Every row explains itself on hover, and each one is also a command.
- **Enter picks up where you left off:** once the room is where you last talked, Enter opens the Hangout box, and goes back to normal chat the moment you talk anywhere else.
- **Minimizes out of the way:** the window folds into a small box you can park anywhere. It lights up and counts what you haven't read when someone talks, and a click brings the window back.
- **Slash commands work in its box:** `/wave`, `/reload`, another addon's commands, all exactly as they do in the normal chat box.
- **Item and quest links:** shift-click them into the box like normal chat. Everyone can click them and see tooltips.
- **Twitch Emotes support:** if you use Twitch Emotes v2, its `:` emote picker works in the Hangout box, emotes show up as pictures with animated ones animating, and hovering one names it.
- **Alerts, all optional:** an unread badge on the tab, the whisper sound, and flashing WoW in the taskbar when a message arrives while you're in another window.
- **Invites with a Join button:** anyone in the room can invite more friends, membership is remembered, and invites that arrive together queue up instead of being lost.
- **Boss-fight safe:** while Blizzard blocks addon chat during encounters, your messages wait and go out when the fight ends.
- **Channel cleanup:** `/ho cleanup name` leaves the whole pile of broken name1…name510 channels in one go. General, Trade and the other built-in channels are never touched.

## Getting started

1. Everyone in the group installs Hangout.
2. One person types `/ho create Night Owls`.
3. They invite friends with `/ho invite Firstname Lastname`, target someone and type `/ho invite`, or click **Invite** in the window.
4. Friends click **Join**. Type `/ho` to open the room, or `/hh message` to talk from normal chat.

`/ho help` lists every command, grouped by what you're trying to do.

## Commands

- `/ho` shows or hides the room, and `/ho help` lists everything.
- `/hh <message>` talks in the room from the normal chat box.
- `/ho create <name>`, `/ho invite <First Last>`, `/ho remove <First Last>`, `/ho leave` manage a room.
- `/ho rooms` and `/ho switch <room>` move between rooms; `/ho who` shows who's in one and who's online.
- `/ho mode window` or `/ho mode inline` decides where room lines show up.
- `/ho window` and `/ho min` open the window or fold it into the small box, and `/ho settings` opens the settings panel.
- `/ho alerts` sets the unread badge and taskbar flashing.
- `/ho channels` lists your channels, and `/ho cleanup <name>` leaves the broken ones.
- `/ho fixchat` explains the fix for greyed-out channels you can't select.
- `/ho echo auto|always|never`, `/ho sound on|off` and `/ho emotes on|off` change settings.

You can also set key bindings under Options > Keybindings > AddOns > Hangout.

## Good to know

- Everyone in the room needs Hangout, and you need to be on the same faction.
- Trial and Veteran accounts can't send addon messages, so they can read the room but not talk.
- Twitch Emotes v2 is optional. Hangout works fine without it.
