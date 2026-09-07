#!/bin/sh
# Starts the dedicated server on the default port (UDP 24565).
#
# It saves its world and picks it back up next time, so there is nothing to pass
# to carry on where everyone left off -- just run this again.
#
# Options:  --port=NNNNN  --world=NAME  --seed=NNNNN
# The bare "--" is required: it separates the engine's options from the game's.
exec ./SpaceCraftServer.exe --headless -- --server "$@"
