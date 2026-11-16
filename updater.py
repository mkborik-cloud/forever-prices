"""
Simple AH updater - TSM-style desktop app for WoW Forever.

Downloads your auction house from the official Blizzard Battle.net API, works out
prices (min buyout, market value, 7-day average, quantity) and writes them into the
Simple AH addon as PriceData.lua. Type /reload in game to load them.

Usage:
    python updater.py --setup      # first-time setup (pick your auction house)
    python updater.py              # one update
    python updater.py --loop       # update every N minutes (see config.ini)

Uses only the Python standard library; nothing to install.
"""

import argparse
import base64
import configparser
import datetime as dt
import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.ini")
HISTORY_PATH = os.path.join(HERE, "history.json")
USER_AGENT = "SimpleAH-Updater/1.0"

DEFAULT_ADDON_DIR = r"C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\SimpleAH"

COPPER_PER_GOLD = 10000


def log(msg):
    stamp = dt.datetime.now().strftime("%H:%M:%S")
    print(f"[{stamp}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_config():
    cfg = configparser.ConfigParser()
    if os.path.exists(CONFIG_PATH):
        cfg.read(CONFIG_PATH, encoding="utf-8")
    for section in ("battlenet", "market", "paths", "update"):
        if not cfg.has_section(section):
            cfg.add_section(section)
    cfg["battlenet"].setdefault("client_id", "")
    cfg["battlenet"].setdefault("client_secret", "")
    cfg["battlenet"].setdefault("region", "eu")
    cfg["market"].setdefault("namespace", "")
    cfg["market"].setdefault("ruleset_id", "1")
    cfg["market"].setdefault("auction_house_id", "")
    cfg["market"].setdefault("label", "")
    cfg["market"].setdefault("want", "pvp horde")
    cfg["paths"].setdefault("addon_dir", DEFAULT_ADDON_DIR)
    cfg["update"].setdefault("interval_minutes", "60")
    cfg["update"].setdefault("history_days", "14")
    cfg["update"].setdefault("locale", "en_US")
    return cfg


def save_config(cfg):
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        cfg.write(f)


# ---------------------------------------------------------------------------
# Battle.net API
# ---------------------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, status, url, body=""):
        super().__init__(f"HTTP {status} for {url} {body[:200]}")
        self.status = status


class BattleNet:
    def __init__(self, client_id, client_secret, region):
        self.client_id = client_id
        self.client_secret = client_secret
        self.region = region.lower()
        self.token = None
        self.token_expires = 0

    @property
    def api_host(self):
        return f"https://{self.region}.api.blizzard.com"

    def _request(self, url, data=None, headers=None, timeout=120):
        req = urllib.request.Request(url, data=data, headers=headers or {})
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("Accept-Encoding", "gzip")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                return resp.status, raw, resp.headers
        except urllib.error.HTTPError as e:
            body = e.read()
            try:
                if e.headers.get("Content-Encoding") == "gzip":
                    body = gzip.decompress(body)
            except Exception:
                pass
            raise ApiError(e.code, url, body.decode("utf-8", "replace")) from None

    def auth(self):
        if self.token and time.time() < self.token_expires - 60:
            return
        if not self.client_id or not self.client_secret:
            raise SystemExit("client_id / client_secret missing in config.ini. See README.md.")
        basic = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
        data = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
        _, raw, _ = self._request(
            "https://oauth.battle.net/token", data=data,
            headers={"Authorization": f"Basic {basic}",
                     "Content-Type": "application/x-www-form-urlencoded"})
        payload = json.loads(raw)
        self.token = payload["access_token"]
        self.token_expires = time.time() + int(payload.get("expires_in", 3600))

    def get(self, path, namespace, locale="en_US", retries=3):
        self.auth()
        sep = "&" if "?" in path else "?"
        url = f"{self.api_host}{path}{sep}namespace={namespace}&locale={locale}"
        for attempt in range(retries):
            try:
                _, raw, headers = self._request(url, headers={"Authorization": f"Bearer {self.token}"})
                return json.loads(raw), headers
            except ApiError as e:
                if e.status == 429 or e.status >= 500:
                    wait = 5 * (attempt + 1)
                    log(f"  {e.status}, retrying in {wait}s ...")
                    time.sleep(wait)
                    continue
                raise
        raise ApiError(0, url, "prilis vela pokusov")


# ---------------------------------------------------------------------------
# Setup / discovery
# ---------------------------------------------------------------------------

def ah_name(entry):
    name = entry.get("name")
    if isinstance(name, dict):
        name = name.get("en_US") or next(iter(name.values()), "?")
    return name or "?"


def setup(cfg, args):
    """WoW Forever: auction houses live at /data/wow/ruleset/{id}/auctions/{ahId}.
    The API ignores the ruleset in the path; the auction house ID decides (e.g. 113 = EU PvP Horde)."""
    region = cfg["battlenet"]["region"]
    ns = args.namespace or f"dynamic-forever-{region}"
    bn = BattleNet(cfg["battlenet"]["client_id"], cfg["battlenet"]["client_secret"], region)
    log("Signing in to the Battle.net API ...")
    bn.auth()

    data, _ = bn.get("/data/wow/ruleset/index", ns)
    rulesets = data.get("rulesets", [])
    if not rulesets:
        raise SystemExit(f"Namespace {ns} has no rulesets.")
    names = {}
    for r in rulesets:
        try:
            d, _ = bn.get(f"/data/wow/ruleset/{r['id']}", ns)
            names[r["id"]] = ah_name(d)
        except ApiError:
            names[r["id"]] = f"ruleset {r['id']}"
    log("Rulesets: " + ", ".join(f"{i}={n}" for i, n in sorted(names.items())))
    ruleset_id = sorted(names)[0]

    idx, _ = bn.get(f"/data/wow/ruleset/{ruleset_id}/auctions/index", ns)
    houses = [(a["id"], ah_name(a)) for a in idx.get("auctions", [])]

    if args.ah:
        ah_id = int(args.ah)
        label = next((n for i, n in houses if i == ah_id), "Auction House")
    else:
        print()
        print("Auction houses (the ID is what counts; Blizzard does not say which ruleset each belongs to):")
        for i, (aid, name) in enumerate(houses, 1):
            print(f"  {i:3d}) AH {aid}: {name}")
        choice = input("Pick a number: ").strip()
        if not choice.isdigit() or not (1 <= int(choice) <= len(houses)):
            raise SystemExit("Invalid choice.")
        ah_id, label = houses[int(choice) - 1]

    cfg["market"]["namespace"] = ns
    cfg["market"]["ruleset_id"] = str(ruleset_id)
    cfg["market"]["auction_house_id"] = str(ah_id)
    if not cfg["market"]["label"] or args.ah:
        cfg["market"]["label"] = f"EU Forever {label} ({ah_id})"
    save_config(cfg)
    log(f"Saved: AH {ah_id} ({label})")


# ---------------------------------------------------------------------------
# Price calculation
# ---------------------------------------------------------------------------

def unit_price(a):
    """Returns (unit price in copper, quantity), or None for bid-only auctions."""
    qty = int(a.get("quantity") or 1)
    if a.get("unit_price"):
        return int(a["unit_price"]), qty
    buyout = a.get("buyout")
    if buyout:
        return int(buyout) // max(1, qty), qty
    return None


def market_value(units):
    """TSM-like: mean of the cheapest ~15% of units, outliers removed."""
    units.sort()
    total = sum(q for _, q in units)
    take = max(1, int(total * 0.15 + 0.5))
    picked, acc = [], 0
    for price, q in units:
        if acc >= take:
            break
        n = min(q, take - acc)
        picked.append((price, n))
        acc += n
    # drop outliers above 1.5x the median of the picked units
    expanded_mid = acc // 2
    run, median = 0, picked[0][0]
    for price, n in picked:
        run += n
        if run > expanded_mid:
            median = price
            break
    kept = [(p, n) for p, n in picked if p <= median * 1.5] or picked
    s = sum(p * n for p, n in kept)
    c = sum(n for _, n in kept)
    return s // c


def compute_prices(auctions):
    per_item = {}
    for a in auctions:
        item = a.get("item") or {}
        item_id = item.get("id")
        if not item_id or item.get("pet_species_id"):
            continue  # battle pets are skipped for now
        up = unit_price(a)
        entry = per_item.setdefault(item_id, {"units": [], "qty": 0, "auctions": 0})
        entry["auctions"] += 1
        entry["qty"] += int(a.get("quantity") or 1)
        if up:
            entry["units"].append(up)

    result = {}
    for item_id, e in per_item.items():
        if not e["units"]:
            continue
        min_buy = min(p for p, _ in e["units"])
        mv = market_value(e["units"])
        result[item_id] = {"min": min_buy, "market": mv, "qty": e["qty"], "auctions": e["auctions"]}
    return result


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

def load_history():
    if os.path.exists(HISTORY_PATH):
        try:
            with open(HISTORY_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            log("history.json is damaged, starting a new one")
    return {"days": {}}


def _bucket(history, day, key):
    d = history["days"].setdefault(day, {})
    return d.setdefault(str(key), {}) if key is not None else d


def update_history(history, prices, keep_days, key=None):
    """Adds this scan to today's running mean. key separates markets in one history file."""
    today = dt.date.today().isoformat()
    day = _bucket(history, today, key)
    for item_id, p in prices.items():
        k = str(item_id)
        prev = day.get(k)
        # running daily mean of market value: [sum, count]
        day[k] = [prev[0] + p["market"], prev[1] + 1] if prev else [p["market"], 1]
    cutoff = (dt.date.today() - dt.timedelta(days=keep_days)).isoformat()
    for d in [d for d in history["days"] if d < cutoff]:
        del history["days"][d]


def averages(history, days=7, key=None):
    cutoff = (dt.date.today() - dt.timedelta(days=days - 1)).isoformat()
    sums = {}
    for d, bucket in history["days"].items():
        if d < cutoff:
            continue
        items = bucket.get(str(key), {}) if key is not None else bucket
        for k, (s, c) in items.items():
            acc = sums.setdefault(k, [0.0, 0])
            acc[0] += s / c
            acc[1] += 1
    return {int(k): int(v[0] / v[1]) for k, v in sums.items()}


def save_history(history):
    tmp = HISTORY_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(history, f, separators=(",", ":"))
    os.replace(tmp, HISTORY_PATH)


# ---------------------------------------------------------------------------
# Lua output
# ---------------------------------------------------------------------------

def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def lua_market_block(m):
    """One market as Lua. Items are filled inside their own functions so a big
    market never hits Lua's per-function constant limit."""
    mid = int(m["id"])
    out = [
        f"M[{mid}] = {{ name = {lua_str(m['name'])}, group = {lua_str(m.get('group', ''))}, "
        f"faction = {lua_str(m.get('faction', ''))}, scanned = {int(m['scanned'])}, "
        f"count = {len(m['prices'])}, items = {{}} }}",
    ]
    items = sorted(m["prices"].items())
    avg = m.get("avg", {})
    for start in range(0, len(items), 15000):
        out.append(f"do local d = M[{mid}].items; (function()")
        for item_id, p in items[start:start + 15000]:
            out.append(f'd[{item_id}]="{p["min"]},{p["market"]},{avg.get(item_id, 0)},{p["qty"]},{p["auctions"]}"')
        out.append("end)() end")
    return out


def render_lua(markets, region="EU"):
    lines = [
        "-- Generated by Simple AH. Do not edit by hand.",
        f"SimpleAHData = {{ version = 2, region = {lua_str(region)}, updated = {int(time.time())}, markets = {{}} }}",
        "local M = SimpleAHData.markets",
    ]
    for m in markets:
        lines.extend(lua_market_block(m))
    return "\n".join(lines) + "\n"


def write_text_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


def write_lua(addon_dir, prices, avg7, meta):
    path = os.path.join(addon_dir, "PriceData.lua")
    market = {"id": meta["id"], "name": meta["market"], "group": meta.get("group", ""),
              "faction": meta.get("faction", ""), "scanned": meta["scanned"],
              "prices": prices, "avg": avg7}
    write_text_atomic(path, render_lua([market]))
    return path


# ---------------------------------------------------------------------------
# Update run
# ---------------------------------------------------------------------------

def run_update(cfg):
    m = cfg["market"]
    if not m["namespace"] or not m.get("auction_house_id"):
        raise SystemExit("Run this first: python updater.py --setup")
    bn = BattleNet(cfg["battlenet"]["client_id"], cfg["battlenet"]["client_secret"], cfg["battlenet"]["region"])

    base = f"/data/wow/ruleset/{m.get('ruleset_id') or 1}/auctions/{m['auction_house_id']}"
    log(f"Downloading auction house: {m['label'] or base}")
    data, headers = bn.get(base, m["namespace"], cfg["update"]["locale"])
    auctions = data.get("auctions", [])
    try:
        com, _ = bn.get(base + "/commodities", m["namespace"], cfg["update"]["locale"])
        commodities = com.get("auctions", [])
    except ApiError as e:
        log(f"  commodities unavailable ({e.status})")
        commodities = []
    log(f"  {len(auctions)} auctions + {len(commodities)} commodity listings")
    auctions = auctions + commodities

    scanned = time.time()
    lm = headers.get("Last-Modified")
    if lm:
        try:
            scanned = dt.datetime.strptime(lm, "%a, %d %b %Y %H:%M:%S %Z").replace(
                tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            pass

    prices = compute_prices(auctions)
    log(f"  {len(prices)} items priced")

    history = load_history()
    update_history(history, prices, int(cfg["update"]["history_days"]))
    save_history(history)
    avg7 = averages(history, 7)

    out = write_lua(cfg["paths"]["addon_dir"], prices, avg7, {
        "id": m["auction_house_id"], "scanned": scanned, "market": m["label"] or "EU Forever",
        "group": m.get("group", ""), "faction": data.get("name", "").split(" ")[0]})
    log(f"Wrote {out}  ->  type /reload in game")


def main():
    ap = argparse.ArgumentParser(description="Simple AH updater")
    ap.add_argument("--setup", action="store_true", help="pick and save your auction house")
    ap.add_argument("--namespace", help="force an API namespace during --setup")
    ap.add_argument("--ah", help="auction house ID for --setup (no prompts)")
    ap.add_argument("--loop", action="store_true", help="keep updating every interval_minutes")
    args = ap.parse_args()

    cfg = load_config()
    if not os.path.exists(CONFIG_PATH):
        save_config(cfg)
        print(f"Created {CONFIG_PATH}. Fill in client_id and client_secret, then run --setup.")
        return

    if args.setup:
        setup(cfg, args)
        if input("Run the first update now? [Y/n]: ").strip().lower() in ("", "a", "y"):
            run_update(cfg)
        return

    if not args.loop:
        run_update(cfg)
        return

    interval = max(5, int(cfg["update"]["interval_minutes"])) * 60
    while True:
        try:
            run_update(cfg)
        except (ApiError, urllib.error.URLError, OSError) as e:
            log(f"Error: {e}")
        log(f"Next update in {interval // 60} min. (Ctrl+C to stop)")
        time.sleep(interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
