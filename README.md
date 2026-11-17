# Simple AH

TSM-style auction house prices for WoW Forever (EU), with an in-game search.

Three parts:

- **Cloud job** (`cloud/fetch_all.py`, run hourly by `.github/workflows/update-prices.yml`): downloads every EU Forever auction house from the Blizzard API and publishes `prices.lua` on the `data` branch.
- **Client** (`client/simple_ah_client.py`, built into `SimpleAH.exe`): downloads `prices.lua` into the addon once per new hourly Blizzard snapshot and starts with Windows. No API key needed.
- **Addon** (`addon/SimpleAH`): search window and tooltip prices. Picks the Alliance or Horde auction house from the character's faction.

Addons can't reach the internet, so new prices show up in game after `/reload` or a relog.

## For players

Unzip `SimpleAH.zip`, copy the `SimpleAH` folder into `World of Warcraft\_forever_\Interface\AddOns`, then run `SimpleAH.exe` once.

| Command | What it does |
|---|---|
| `/ah [text]` | open the search, optionally with a query |
| shift-click an item | while the search is open, look up exactly that item |
| `/ah bind` | set a key that opens the search (or click the key button in the window, or *Options → Keybindings → AddOns → Simple AH*) |
| Stats button / `/ah stats` | on the Buy tab next to Filter: show only browse results with the stats you tick (spell power, healing, agility, defense, …) or consumable effects (spell damage elixirs, healing/mana potions, food, oils, …) |
| Profession window | under the selected recipe: reagent cost (AH or vendor price, whichever is cheaper; vendor prices are learned when you open a vendor), AH value of the result and profit after the 5% cut (hover for a breakdown) |
| `/ah market [group\|blackwater]` | choose another ruleset group or the neutral auction house |
| `/ah tooltip` | show or hide prices in item tooltips |
| `/ah scale 1.2` | window size (0.5–2) |
| `/ah info` | data status |
| `/ah reset` | reset window position |

| Column | Meaning |
|---|---|
| Min | cheapest unit listed |
| Market | mean of the cheapest ~15% of units, outliers removed (similar to TSM DBMarket) |
| 7d avg | mean daily market value over the last 7 days |
| Qty | units listed |

## Forever auction API

Namespace `dynamic-forever-eu`. Paths:
- `/data/wow/ruleset/{id}/auctions/{ahId}`
- `/data/wow/ruleset/{id}/auctions/{ahId}/commodities`

The ruleset in the path is ignored; the auction house ID decides. EU IDs come in groups of Alliance / Horde / Blackwater:

| Group | Alliance | Horde | Blackwater |
|---|---|---|---|
| pvp (confirmed) | 110 | 113 | 116 |
| g2 | 111 | 114 | 117 |
| g3 (empty) | 112 | 115 | 118 |
| g4 | 119 | 120 | 121 |
| g5 | 123 | 124 | 125 |

## Maintainer setup

- Repository secrets `BNET_CLIENT_ID` and `BNET_CLIENT_SECRET` hold a Battle.net API client from https://develop.battle.net/access/clients.
- `client/build.bat` builds `client/dist/SimpleAH.zip`.
- `updater.py` is the original single-machine updater; it uses `config.ini` (not committed) and writes the same file format.
