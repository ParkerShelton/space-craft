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
| `--seed=N` | reopen a specific world instead of generating a new one |

On startup it prints the seed it chose:

    [server] listening on port 24565
    [server] world seed 777001 -- pass --seed=777001 to reopen this same world
    [server] system Tauuna, 4 planets, home world Pyros
    [server] ready

Keep that seed. Passing it back with `--seed=` is what reopens the same world
after a restart.

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

## On a cloud box (AWS or similar)

1. Install Godot 4.6 and copy the project across.
2. Open the port (default UDP **24565**) in the instance's security group.
3. Run the command above, ideally under `systemd`, `screen` or `tmux` so it
   survives you logging out.
4. Players choose **Join Co-op Game** and enter the instance's public IP.

The transport is ENet over UDP — make sure the rule is UDP, not TCP.

## Known limits

World state currently lives in memory only: **stopping the server loses what has
been built**. The seed reopens the same terrain, not the same buildings. Saving
the edit record to disk is the obvious next step.

Creatures, water flow, machines and ships are still simulated per-client and are
not synchronised, so those will differ between players.

## "Port 24565 is already in use"

A server is still running. Godot spawns two processes when you launch the
console build, so closing the window you can see does not always end it.

On Windows, find and stop it:

    Get-Process SpaceCraftServer, Godot* | Stop-Process -Force

Or check exactly what is holding the port:

    Get-NetUDPEndpoint -LocalPort 24565 | ForEach-Object {
        Get-Process -Id $_.OwningProcess }

Or simply start the new one somewhere else with `--port=24566`.
