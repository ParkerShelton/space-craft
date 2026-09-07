SpaceCraft -- dedicated server
==============================

Double-click start-server.bat.

It prints something like:

    [server] resumed world 'server_world': 412 block changes, 9 part cells, 2 player inventories
    [server] listening on port 24565
    [server] world seed 1756869613 -- pass --seed=1756869613 to reopen this same world
    [server] system Quoor, 5 planets, home world Talos
    [server] saving to ...\server_world.dat every 60 seconds
    [server] ready

Players then start the game (in the Game folder), choose "Join Co-op Game", and
enter this machine's address -- 127.0.0.1 from this same computer, or its local
network address from another one.


Saving
------

The server saves its world and reloads it next time it starts, so restarting it
does not lose what anyone has built. Nothing needs passing to make that happen:
just start it the same way again.

It writes every 60 seconds, whenever somebody joins or leaves, and on a clean
shutdown. A crash or a power cut costs at most a minute of building.

It also remembers what each player is carrying and hands it back when they
return. Players are recognised by an id their game writes once into its own
files, so copying a game folder to a second machine and playing both at once
looks like the same player twice.

--seed is for making a NEW world with a chosen seed. Passing it to a server that
already has a saved world generates fresh terrain and then overwrites that save.
To reopen an existing world, pass nothing.

Run more than one world on the same machine by naming them:

    SpaceCraftServer.exe --headless -- --server --world=survival --port=24565
    SpaceCraftServer.exe --headless -- --server --world=creative --port=24566


On a rented box
---------------

Running it on a rented box (AWS or similar) means nobody has to forward a port
at home. See SERVER.md for that, and note the firewall rule must be UDP, not
TCP: the transport is ENet over UDP.

There is no window and no player here. The server only holds the world and the
record of what everyone has changed, and passes it around -- it never draws
anything or builds terrain, which is why it starts in a couple of seconds.
