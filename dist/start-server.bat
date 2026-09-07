@echo off
REM Starts the dedicated server on the default port (UDP 24565).
REM
REM It saves its world and picks it back up next time, so there is nothing to
REM pass to carry on where everyone left off -- just run this again.
REM
REM Other options:
REM
REM   --port=NNNNN     listen somewhere else
REM   --world=NAME     which saved world to use (default: server_world)
REM   --seed=NNNNN     make a NEW world with this seed. Careful: alongside an
REM                    existing --world this replaces what is saved there.
REM
REM   SpaceCraftServer.exe --headless -- --server --world=creative --port=24566
REM
REM The bare "--" is required. It separates the engine's own options from the
REM game's, and without it the server starts as a normal game instead.

SpaceCraftServer.exe --headless -- --server
pause
