#!/bin/sh
# Starts the dedicated server on the default port (UDP 24565).
#
# It saves its world and picks it back up next time, so there is nothing to pass
# to carry on where everyone left off -- just run this again.
#
# Options:  --port=NNNNN  --world=NAME  --seed=NNNNN
#
# The bare "--" is required: it separates the engine's own options from the
# game's, and without it the server tries to start as a normal game and fails
# for want of a display.
cd "$(dirname "$0")" || exit 1
exec ./SpaceCraftServer.x86_64 --headless -- --server "$@"
