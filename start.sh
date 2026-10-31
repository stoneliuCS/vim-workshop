#!/usr/bin/env bash
# Launch the workshop: load the commands, then play the intro into the deck.
# Opening presentation.md as an argument also stops auto-session from
# restoring this folder's saved session over the intro.
cd "$(dirname "$0")" && exec nvim presentation.md -c "luafile workshop.lua" -c "Workshop"
