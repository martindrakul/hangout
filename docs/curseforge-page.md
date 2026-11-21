# CurseForge project page

Copy these into the project form at authors.curseforge.com.

## Project name

Hangout

If that name is already taken, use **Hangout Rooms**. The addon folder stays `Hangout` either way.

## Summary

A private chat room for you and your friends that works even when /join channels break.

## Category and game version

- Main category: **Chat & Communication**
- Game: World of Warcraft, file game version **WoW Forever 1.60.1** (newer Forever versions are fine too)
- License: **MIT**
- Avatar: `hangout-avatar-400.png`

## Description

Paste everything below the line into the description editor.

---

# Hangout

**A chat room for you and your friends that doesn't depend on custom chat channels.**

On WoW Forever, `/join` channels often break when friends are on different servers behind the scenes. People end up in separate copies of the same channel, can't see each other's messages, or can't reply, and you end up making name2, name3, name4…

Hangout skips channels completely. Every line you type goes straight to each friend in the room, and everyone's copy of Hangout keeps the member list in sync.

## Features

- **Its own chat window:** move it, resize it, and keep your history between sessions.
- **Item and quest links:** shift-click them into the box like normal chat. Everyone can click them and see tooltips.
- **Twitch Emotes support:** if you use Twitch Emotes v2, its `:` emote picker works in the Hangout box and emotes show up as pictures.
- **Invites with a Join button:** anyone in the room can invite more friends, and membership is remembered.
- **Online status:** see who's in the room and who's online right now.
- **Boss-fight safe:** while Blizzard blocks addon chat during encounters, your messages wait and go out when the fight ends.
- **Channel cleanup:** `/ho cleanup name` leaves the whole pile of broken name1…name510 channels in one go. General, Trade and the other built-in channels are never touched.

## Getting started

1. Everyone in the group installs Hangout.
2. One person types `/ho create Night Owls`.
3. They invite friends with `/ho invite Firstname Lastname`, or target someone and type `/ho invite`.
4. Friends click **Join**. Type `/ho` to open the window, or `/hh message` to talk from normal chat.

## Commands

- `/ho` shows or hides the window.
- `/hh <message>` talks in the room from the normal chat box.
- `/ho create <name>`, `/ho invite <First Last>`, `/ho remove <First Last>`, `/ho leave` manage the room.
- `/ho who` shows who's in the room and who's online.
- `/ho channels` lists your channels, and `/ho cleanup <name>` leaves the broken ones.
- `/ho fixchat` explains the fix for greyed-out channels you can't select.
- `/ho echo auto|always|never`, `/ho sound on|off` and `/ho emotes on|off` change settings.

You can also set key bindings under Options > Keybindings > AddOns > Hangout.

## Good to know

- Everyone in the room needs Hangout, and you need to be on the same faction.
- Trial and Veteran accounts can't send addon messages, so they can read the room but not talk.
- Twitch Emotes v2 is optional. Hangout works fine without it.
