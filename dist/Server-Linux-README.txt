SpaceCraft -- dedicated server (Linux, x86-64)
==============================================

One self-contained file. There is nothing to install: no Godot, no libraries
beyond what a normal desktop or server image already has.

    chmod +x SpaceCraftServer.x86_64 start-server.sh
    ./start-server.sh

(The executable bit does not survive Dropbox or a Windows filesystem, which is
why it has to be set once after copying.)

It prints something like:

    [server] resumed world 'server_world': 412 block changes, 9 part cells, 2 player inventories
    [server] listening on port 24565
    [server] world seed 1756869613 -- pass --seed=1756869613 to reopen this same world
    [server] system Quoor, 5 planets, home world Talos
    [server] saving to /home/you/.local/share/godot/app_userdata/SpaceCraft/server_world.dat every 60 seconds
    [server] ready

Players join with the machine's address, from the game's menu or straight from
the command line:

    SpaceCraft.exe -- --join=203.0.113.10


Saving
------

The server saves its world and reloads it next time it starts, so restarting it
does not lose what anyone has built. Nothing needs passing to make that happen.

It writes every 60 seconds, and whenever somebody joins or leaves. It also
tries on the way out, but do not count on that: a signal -- Ctrl+C, `systemctl
stop`, `kill` -- can end the process before it gets the chance. The periodic
save is what actually protects the world, so a stop or a crash costs at most a
minute of building, and stopping right after somebody leaves costs nothing.

--seed is for making a NEW world with a chosen seed. Passing it to a server that
already has a saved world generates fresh terrain and then overwrites that save.
To reopen an existing world, pass nothing.

    ./start-server.sh --world=survival --port=24565
    ./start-server.sh --world=creative --port=24566


The port
--------

UDP 24565 by default. The transport is ENet over UDP, so a TCP-only rule lets
nothing through -- that is the usual reason a server looks up but nobody can
reach it.

    sudo ufw allow 24565/udp

On AWS or similar, the security group needs the same: custom UDP, port 24565.


Keeping it running
------------------

Under systemd, so it comes back after a reboot and restarts if it ever dies:

    # /etc/systemd/system/spacecraft.service
    [Unit]
    Description=SpaceCraft dedicated server
    After=network.target

    [Service]
    Type=simple
    User=spacecraft
    WorkingDirectory=/opt/spacecraft
    ExecStart=/opt/spacecraft/SpaceCraftServer.x86_64 --headless -- --server
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target

    sudo systemctl enable --now spacecraft
    journalctl -u spacecraft -f          # watch it

Or, for a quick test, just run it inside tmux or screen so it survives you
logging out.

The world is saved under the user the service runs as, in
~/.local/share/godot/app_userdata/SpaceCraft/ -- worth knowing before you go
looking for it, and worth backing up.
