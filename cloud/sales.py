"""
Estimated sales per day, from consecutive hourly auction house snapshots.

Blizzard's API has no sales data, only the auctions that are up right now.
An auction that disappears between two snapshots while it still had LONG
(2-12 h) or VERY_LONG (12-48 h) left cannot have expired, so it was bought
(or cancelled, which makes this a slight overestimate). A commodity whose
quantity drops had part of it bought.

The previous snapshot is kept in a compact binary file (sorted auction IDs as
deltas, item IDs, quantities, a VERY_LONG flag), zlib-compressed.
"""

import array
import base64
import datetime as dt
import json
import os
import zlib

COUNTED = ("LONG", "VERY_LONG")
NORMAL_GAP = 2.5 * 3600   # up to this, LONG auctions can't have expired in between
LONG_GAP = 11 * 3600      # up to this, VERY_LONG auctions can't have expired in between
MIN_COVER = 6 * 3600      # don't publish a rate from less tracking than this
WINDOW_DAYS = 7


# ---------------------------------------------------------------------------
# Snapshot file
# ---------------------------------------------------------------------------

def take(auctions):
    """auction id -> (item id, quantity, very_long) for auctions that will count next hour."""
    out = {}
    for a in auctions:
        tl = a.get("time_left")
        item = (a.get("item") or {}).get("id")
        if tl in COUNTED and item and not (a.get("item") or {}).get("pet_species_id"):
            out[int(a["id"])] = (int(item), min(int(a.get("quantity") or 1), 65535), tl == "VERY_LONG")
    return out


def quantities(auctions):
    """auction id -> quantity for everything currently listed."""
    return {int(a["id"]): int(a.get("quantity") or 1) for a in auctions if a.get("id")}


def _pack(snap):
    ids = sorted(snap)
    deltas, items, qtys, flags = array.array("Q"), array.array("I"), array.array("H"), array.array("B")
    prev = 0
    for i in ids:
        item, q, vl = snap[i]
        deltas.append(i - prev)
        prev = i
        items.append(item)
        qtys.append(q)
        flags.append(1 if vl else 0)
    raw = b"".join(x.tobytes() for x in (deltas, items, qtys, flags))
    return {"n": len(ids), "data": base64.b64encode(zlib.compress(raw, 9)).decode()}


def _unpack(blob):
    n = blob["n"]
    raw = zlib.decompress(base64.b64decode(blob["data"]))
    deltas, items, qtys, flags = array.array("Q"), array.array("I"), array.array("H"), array.array("B")
    pos = 0
    for arr in (deltas, items, qtys, flags):
        size = arr.itemsize * n
        arr.frombytes(raw[pos:pos + size])
        pos += size
    out, cur = {}, 0
    for k in range(n):
        cur += deltas[k]
        out[cur] = (items[k], qtys[k], bool(flags[k]))
    return out


def load_snapshots(path):
    """market id -> {"scanned": t, "auctions": {...}}"""
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, "rb") as f:
            doc = json.loads(zlib.decompress(f.read()))
        return {int(k): {"scanned": v["scanned"], "auctions": _unpack(v)} for k, v in doc.items()}
    except Exception as e:  # damaged or old format: start over
        print(f"sales snapshot unreadable ({e}), starting fresh", flush=True)
        return {}


def save_snapshots(path, snaps):
    doc = {str(k): {"scanned": v["scanned"], **_pack(v["auctions"])} for k, v in snaps.items()}
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(zlib.compress(json.dumps(doc, separators=(",", ":")).encode(), 6))
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Counting
# ---------------------------------------------------------------------------

def sold_between(prev, prev_scanned, current_qty, scanned):
    """item id -> units bought between two snapshots of one market, or None if they can't be compared."""
    gap = scanned - prev_scanned
    if gap <= 0 or gap > LONG_GAP:
        return None
    only_very_long = gap > NORMAL_GAP
    sold = {}
    for aid, (item, q, very_long) in prev.items():
        if only_very_long and not very_long:
            continue
        now = current_qty.get(aid)
        if now is None:
            n = q
        elif now < q:
            n = q - now          # part of a commodity stack was bought
        else:
            continue
        sold[item] = sold.get(item, 0) + n
    return sold


def record(history, market_id, sold, scanned, start, keep_days=8):
    """Adds the sales between snapshot times start and scanned to history["sold"][day][market][item]."""
    day = dt.datetime.utcfromtimestamp(scanned).date().isoformat()
    bucket = history.setdefault("sold", {}).setdefault(day, {}).setdefault(str(market_id), {})
    for item, n in sold.items():
        k = str(item)
        bucket[k] = bucket.get(k, 0) + n
    since = history.setdefault("sold_since", {})
    since.setdefault(str(market_id), start)
    cutoff = (dt.datetime.utcfromtimestamp(scanned).date() - dt.timedelta(days=keep_days)).isoformat()
    for d in [d for d in history["sold"] if d < cutoff]:
        del history["sold"][d]


def per_day(history, market_id, now):
    """item id -> estimated units sold per day (average over up to 7 days)."""
    since = history.get("sold_since", {}).get(str(market_id))
    if not since:
        return {}
    today = dt.datetime.utcfromtimestamp(now).date()
    first_day = today - dt.timedelta(days=WINDOW_DAYS - 1)
    window_start = dt.datetime(first_day.year, first_day.month, first_day.day,
                               tzinfo=dt.timezone.utc).timestamp()
    covered = now - max(since, window_start)
    if covered < MIN_COVER:
        return {}
    totals = {}
    for d, markets in history.get("sold", {}).items():
        if d < first_day.isoformat():
            continue
        for k, n in markets.get(str(market_id), {}).items():
            totals[int(k)] = totals.get(int(k), 0) + n
    days = covered / 86400
    return {item: round(n / days, 1) for item, n in totals.items() if n > 0}
