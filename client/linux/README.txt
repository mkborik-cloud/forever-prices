Simple AH for Linux
===================

Works with WoW Forever running through Wine, Lutris, Steam/Proton, Bottles
or similar. Needs python3 (already on almost every Linux system).

1. Copy the SimpleAH folder into your game's addon folder:
     .../World of Warcraft/_forever_/Interface/AddOns/

2. Open a terminal in this folder and run:
     python3 simple-ah.py install

   It finds the game in the usual Wine/Lutris/Steam/Bottles places. If it
   can't, give it your World of Warcraft folder, for example:
     python3 simple-ah.py install "$HOME/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft"

   That downloads the prices now and starts a small background updater
   (a systemd user service, or desktop autostart if there is no systemd).
   It starts with your login and fetches new prices once an hour, right
   after Blizzard publishes them.

3. In game: /ah to search, prices in item tooltips. New prices load at
   login or with /reload.

Other commands
  python3 simple-ah.py status      where the game is, how old the prices are
  python3 simple-ah.py update      download the newest prices right now
  python3 simple-ah.py uninstall   stop and remove the updater

Updating to a new version: copy the new SimpleAH folder over the old one
and run install again.
