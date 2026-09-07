SpaceCraft
==========

Run SpaceCraft.exe.

Keep SpaceCraft.exe and SpaceCraft.pck together in this folder -- the .pck holds
the game itself and the .exe will not start without it.


Playing with other people
-------------------------

From the main menu:

  Host Co-op Game   opens your game to others and keeps playing on this machine.
                    Others join using your address on the local network.

  Join Co-op Game   asks for an address. Type the host's, or the address of a
                    dedicated server (see the Server folder).

  127.0.0.1         joins a server running on this same computer.

To skip the menu and go straight to a server, make a shortcut to SpaceCraft.exe
and add the address to the end of its target:

  SpaceCraft.exe -- --join=203.0.113.10
  SpaceCraft.exe -- --join=203.0.113.10:24566

The bare "--" is required: it separates the engine's own options from the
game's.

Co-op always uses a fresh world and never touches your single-player save.

Whoever hosts owns the world. Everyone else generates the same terrain from its
seed, so only the CHANGES people make travel over the network.


What is shared, and what is not
-------------------------------

Shared: the terrain, everything anyone builds or mines (including eighth-block
detail work), and where everyone is standing.

On a dedicated server, what you are carrying is remembered as well, and comes
back when you rejoin -- along with your suit, your hotbar and the recipes you
have learned. You still spawn at the home world each session.

Not shared yet: creatures, water flow, machines and ships. Those are simulated
on each player's own machine, so they will differ between you.
