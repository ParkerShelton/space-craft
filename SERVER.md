# Running a dedicated server

The game can run headless as a dedicated server. Players then join it by
address, so nobody has to forward a port on their own machine — only the box
running the server needs its port reachable.

## Start it

    godot --headless --path /path/to/space-craft -- --server

Options go after the bare `--`, because Godot itself consumes anything it
recognises before that:

| option | meaning |
| --- | --- |
| `--server` | run as a dedicated server (also accepts `--dedicated`) |
| `--port=N` | listen on port N instead of the default 24565 |
| `--seed=N` | generate a specific world instead of resuming or making a new one |
| `--world=NAME` | which saved world to use (default `server_world`) |

On startup it prints what it is doing:

    [server] resumed world 'server_world': 412 block changes, 27 part cells
    [server] listening on port 24565
    [server] world seed 777001 -- pass --seed=777001 to reopen this same world
    [server] system Tauuna, 4 planets, home world Pyros
    [server] saving to /home/you/.local/share/godot/app_userdata/SpaceCraft/server_world.dat every 60 seconds
    [server] ready

## Saving

The server saves its world to disk and reloads it on the next start, so
restarting it does not lose what people have built. Nothing needs to be passed
to make that happen — just start it the same way again.

It writes:

* every 60 seconds,
* whenever a player joins or leaves (the end of a building session is the moment
  most worth keeping), and
* on a clean shutdown, including Ctrl+C on most platforms.

A kill or a power cut falls back to the last periodic save, so at most a minute
of building is at risk.

The file lives beside the game's own saves under Godot's user data directory,
named after `--world` — but it is never the single-player save, so running a
server on the same machine you play on cannot touch your own world.

**`--seed` overrides resuming.** It is for creating a *new* world with a chosen
seed; passing it alongside an existing `--world` name generates fresh terrain and
then overwrites that save. To start over deliberately, use a new `--world=` name
or delete the old file. To reopen an existing world, pass nothing — the seed
comes back out of the save.

Run several worlds on one machine by giving each its own name and port:

    godot --headless --path /path/to/space-craft -- --server --world=survival --port=24565
    godot --headless --path /path/to/space-craft -- --server --world=creative --port=24566

## What the server does and does not do

It holds the world seed and the authoritative record of every block anyone has
changed, and it relays. It does **not** generate terrain meshes, run physics, or
render anything: chunks are only ever built around a player, and a dedicated
server has none. That is why it starts in a couple of seconds and stays cheap.

Everything a client sees, it generates for itself from the seed. Only the
*changes* travel, so bandwidth is proportional to how much people build rather
than to how far they walk.

A player joining is sent the seed and then every change made so far, so someone
arriving hours later sees the world as it is, not as it was generated.

## Player inventories

The server remembers what each player is carrying, and gives it back when they
return -- across a rejoin and across a server restart.

Players are recognised by an id their game writes once into its own user data
(`player_uid.txt`), not by peer id (issued fresh on every connection, so it
would hand out the wrong backpack) and not by name (two friends both called
Steve must not share one). Copying a game folder to a second machine and
playing both at once therefore looks like the same player twice; delete that
file on one of them to split them apart.

Clients send their inventory up every few seconds when it has changed, and once
more on the way out. A crash or a pulled cable costs at most a few seconds of
gathering.

Saved along with the inventory: the equipped suit, the hotbar slot in hand, and
which recipes that player has learned. Not saved: where they were standing, so
everyone spawns at the home world each session.

## Joining from the command line

    godot --path /path/to/space-craft -- --join=203.0.113.10
    godot --path /path/to/space-craft -- --join=203.0.113.10:24566

Skips the menu and connects straight to that server -- handy for a desktop
shortcut. Without a port it uses 24565.

## On a cloud box (AWS or similar)

1. Install Godot 4.6 and copy the project across.
2. Open the port (default UDP **24565**) in the instance's security group.
3. Run the command above, ideally under `systemd`, `screen` or `tmux` so it
   survives you logging out.
4. Players choose **Join Co-op Game** and enter the instance's public IP.

The transport is ENet over UDP — make sure the rule is UDP, not TCP.

## Known limits

Creatures, water flow, machines and ships are still simulated per-client and are
not synchronised, so those will differ between players. Assembling parts into a
working machine is likewise still local to whoever swung the wrench, though the
parts themselves now replicate and save.

## "Port 24565 is already in use"

A server is still running. Godot spawns two processes when you launch the
console build, so closing the window you can see does not always end it.

On Windows, find and stop it:

    Get-Process SpaceCraftServer, Godot* | Stop-Process -Force

Or check exactly what is holding the port:

    Get-NetUDPEndpoint -LocalPort 24565 | ForEach-Object {
        Get-Process -Id $_.OwningProcess }

Or simply start the new one somewhere else with `--port=24566`.
