#!/usr/bin/env bash
# Copy Hangout into a WoW install so you can test it in game.
#
#   bash tools/deploy.sh
#   HANGOUT_ADDONS="/d/WoW/_forever_/Interface/AddOns" bash tools/deploy.sh
#
# Not part of the released addon: .pkgmeta keeps tools/ out of the zip.
set -euo pipefail

FILES=(
	Core.lua Comm.lua Room.lua UI.lua Channels.lua Commands.lua
	Bindings.xml Hangout.toc README.md
)

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

candidates=(
	"${HANGOUT_ADDONS:-}"
	"/c/Games/World of Warcraft/_forever_/Interface/AddOns"
	"/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"
)

addons=""
for dir in "${candidates[@]}"; do
	if [ -n "$dir" ] && [ -d "$dir" ]; then
		addons="$dir"
		break
	fi
done

if [ -z "$addons" ]; then
	echo "Couldn't find an AddOns folder. Set HANGOUT_ADDONS to yours, for example:" >&2
	echo "  HANGOUT_ADDONS=\"/c/Games/World of Warcraft/_forever_/Interface/AddOns\" bash tools/deploy.sh" >&2
	exit 1
fi

dest="$addons/Hangout"
mkdir -p "$dest/Media"

for f in "${FILES[@]}"; do
	cp "$root/$f" "$dest/$f"
done
cp "$root/Media/Icon.tga" "$dest/Media/Icon.tga"

echo "Copied $(( ${#FILES[@]} + 1 )) files to:"
echo "  $dest"
echo
echo "Now type /reload in game. If Hangout.toc gained or lost a file since you last"
echo "started the game, restart the client instead: /reload won't load a new file."
