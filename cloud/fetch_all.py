"""
Cloud job: downloads every EU WoW Forever auction house and writes one
prices.lua that the ForeverPrices downloader installs for everyone.

Runs in GitHub Actions every hour. Needs two environment variables:
    BNET_CLIENT_ID, BNET_CLIENT_SECRET

Usage:
    python cloud/fetch_all.py --out out --history out/history.json.gz
"""

import argparse
import calendar
import gzip
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import updater  # noqa: E402

REGION = "eu"
NAMESPACE = f"dynamic-forever-{REGION}"

# Auction houses come in groups of three (Alliance, Horde, Blackwater) per ruleset.
# The API does not say which ruleset a group is; "pvp" was confirmed in game
# (Thorium Bar price on EU PvP Horde = AH 113). The rest keep neutral names until confirmed.
GROUPS = {
    110: "pvp", 113: "pvp", 116: "pvp",
    111: "g2", 114: "g2", 117: "g2",
    112: "g3", 115: "g3", 118: "g3",
    119: "g4", 120: "g4", 121: "g4",
    123: "g5", 124: "g5", 125: "g5",
}
KEEP_DAYS = 8


def log(msg):
    print(msg, flush=True)


def faction_from_name(name):
    for f in ("Alliance", "Horde", "Blackwater"):
        if f.lower() in (name or "").lower():
            return f
    return "Neutral"


def load_history(path):
    if path and os.path.exists(path):
        try:
            with gzip.open(path, "rt", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            log(f"history unreadable ({e}), starting fresh")
    return {"days": {}}


def save_history(path, history):
    tmp = path + ".tmp"
    with gzip.open(tmp, "wt", encoding="utf-8") as f:
        json.dump(history, f, separators=(",", ":"))
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="out")
    ap.add_argument("--history", default=None)
    args = ap.parse_args()

    cid = os.environ.get("BNET_CLIENT_ID", "")
    secret = os.environ.get("BNET_CLIENT_SECRET", "")
    if not cid or not secret:
        cfg = updater.load_config()  # local runs fall back to config.ini
        cid, secret = cfg["battlenet"]["client_id"], cfg["battlenet"]["client_secret"]

    bn = updater.BattleNet(cid, secret, REGION)
    rulesets, _ = bn.get("/data/wow/ruleset/index", NAMESPACE)
    first = sorted(r["id"] for r in rulesets.get("rulesets", []))[0]
    index, _ = bn.get(f"/data/wow/ruleset/{first}/auctions/index", NAMESPACE)

    history_path = args.history or os.path.join(args.out, "history.json.gz")
    history = load_history(history_path)
    markets, summary = [], []

    for ah in index.get("auctions", []):
        ah_id, name = ah["id"], updater.ah_name(ah)
        base = f"/data/wow/ruleset/{first}/auctions/{ah_id}"
        try:
            data, headers = bn.get(base, NAMESPACE)
        except updater.ApiError as e:
            log(f"AH {ah_id}: {e.status}, skipped")
            continue
        auctions = data.get("auctions", [])
        try:
            com, _ = bn.get(base + "/commodities", NAMESPACE)
            auctions += com.get("auctions", [])
        except updater.ApiError:
            pass
        if not auctions:
            log(f"AH {ah_id} {name}: empty")
            continue

        prices = updater.compute_prices(auctions)
        updater.update_history(history, prices, KEEP_DAYS, key=ah_id)
        avg = updater.averages(history, 7, key=ah_id)
        scanned = time.time()
        lm = headers.get("Last-Modified")
        if lm:
            try:
                scanned = calendar.timegm(time.strptime(lm, "%a, %d %b %Y %H:%M:%S %Z"))
            except ValueError:
                pass
        markets.append({"id": ah_id, "name": name, "group": GROUPS.get(ah_id, f"ah{ah_id}"),
                        "faction": faction_from_name(name), "scanned": scanned,
                        "prices": prices, "avg": avg})
        summary.append({"id": ah_id, "name": name, "group": GROUPS.get(ah_id, f"ah{ah_id}"),
                        "items": len(prices), "listings": len(auctions), "scanned": int(scanned)})
        log(f"AH {ah_id} {name}: {len(auctions)} listings, {len(prices)} items")
        time.sleep(0.2)

    if not markets:
        raise SystemExit("No auction data received; keeping the previous files.")

    os.makedirs(args.out, exist_ok=True)
    updater.write_text_atomic(os.path.join(args.out, "prices.lua"), updater.render_lua(markets, REGION.upper()))
    with open(os.path.join(args.out, "status.json"), "w", encoding="utf-8") as f:
        json.dump({"updated": int(time.time()), "region": REGION.upper(), "markets": summary}, f, indent=1)
    save_history(history_path, history)
    log(f"Wrote {len(markets)} markets to {args.out}")


if __name__ == "__main__":
    main()
