# ForeverPrices

TSM-style auction house prices for WoW Forever (EU). It works in two parts:

- **Desktop updater** (`updater.py`) downloads your auction house from the official Blizzard Battle.net API, works out prices and writes them into the addon.
- **Addon** (`_forever_\Interface\AddOns\ForeverPrices`) gives you a search window and prices in item tooltips.

Addons can't reach the internet, so new prices show up in game after `/reload` or a relog.

## 1. Battle.net API client (once, free)

1. Go to https://develop.battle.net/access/clients and sign in.
2. **Create Client**:
   - Client Name: something unique, e.g. `ForeverPrices-MB7342`
   - Redirect URL: `http://localhost`
   - Service URL: tick "I do not have a service URL"
   - Intended use: "Personal auction house price tracker"
3. Copy the **Client ID** and **Client Secret** into `config.ini`. Keep the secret private.

## 2. Auction house

Already set to **EU PvP Horde = AH 113**.

The Forever API uses namespace `dynamic-forever-eu` and these paths:
- `/data/wow/ruleset/{id}/auctions/{ahId}`
- `/data/wow/ruleset/{id}/auctions/{ahId}/commodities`

The API ignores the ruleset in the path, so the auction house ID is what counts. Known EU IDs:
- 113 = PvP Horde (confirmed by the Thorium Bar price)
- 110–118 and 119–125 are the other groups (Alliance, Horde, Blackwater)

To switch, run `python updater.py --setup --ah <ID>`.

## 3. Everyday use

- `2 - Run updater.bat` updates every hour. Leave the window running.
- In game:
  - `/reload` loads the new prices.
  - `/fp` or your key binding opens the search.
  - Type a name, or **shift-click any item** (bags, chat, AH, loot) while the window is open to look up exactly that item.

| Command | What it does |
|---|---|
| `/fp [text]` | open the search, optionally with a query |
| `/fp bind` | set a key that opens the search; you can also click the key button in the window, or use *Options → Keybindings → AddOns → Forever Prices* |
| `/fp tooltip` | show or hide prices in item tooltips |
| `/fp scale 1.2` | window size (0.5–2) |
| `/fp info` | data status |
| `/fp reset` | reset window position |

## Columns

| Column | Meaning |
|---|---|
| Min | cheapest unit listed |
| Market | mean of the cheapest ~15% of units, outliers removed (similar to TSM DBMarket) |
| 7d avg | mean daily market value over 7 days, from `history.json`; accurate after a few days of running the updater |
| Qty | units listed |

The first time you open the search, the addon loads item names in the background ("Loading names X%"). They are saved, so later sessions start ready.
