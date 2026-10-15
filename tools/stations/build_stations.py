#!/usr/bin/env python3
"""
Builds the station dataset bundled with the app: every metro station, train station
and major bus terminal in the HSL area, with entrances, levels, platforms, escalators,
stairs, lifts and a walkable graph, plus a coverage report.

Sources
  - Digitransit (HSL stations and their platforms), needs DIGITRANSIT_API_KEY
  - OpenStreetMap via the Overpass API (indoor + public transport tagging)

Usage (on a machine with internet access, e.g. your Mac):
  export DIGITRANSIT_API_KEY=...
  python3 tools/stations/build_stations.py
  python3 tools/stations/build_stations.py --only Kamppi Pasila     # a few stations
  python3 tools/stations/build_stations.py --refresh                 # ignore the cache

Outputs
  App/Resources/Stations/stations.json   dataset for the app
  docs/stations/coverage.md              which stations are complete / partial / empty, and what's missing
  docs/stations/coverage.json            the same, machine-readable

Python 3.9+, standard library only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict, deque
from dataclasses import dataclass, field

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CACHE = os.path.join(os.path.dirname(__file__), ".cache")
OUT_JSON = os.path.join(ROOT, "App", "Resources", "Stations", "stations.json")
OUT_DOCS = os.path.join(ROOT, "docs", "stations")

DIGITRANSIT = "https://api.digitransit.fi/routing/v2/hsl/gtfs/v1"
OVERPASS = os.environ.get("OVERPASS_URL", "https://overpass-api.de/api/interpreter")
UA = "HSLCommuter-station-builder/1.0 (personal project)"
ATTRIBUTION = "© OpenStreetMap contributors (ODbL) · HSL/Digitransit (CC BY 4.0)"

# Major bus terminals without a single GTFS parent station. Coordinates are approximate
# seeds; the bus bays themselves come from Digitransit stops within `radius` meters.
BUS_TERMINALS = [
    ("Kamppi bus terminal", 60.1690, 24.9320, 220),
    ("Elielinaukio", 60.1712, 24.9405, 150),
    ("Rautatientori bus stops", 60.1708, 24.9455, 150),
    ("Itäkeskus bus terminal", 60.2100, 25.0800, 220),
    ("Herttoniemi bus terminal", 60.1950, 25.0300, 180),
    ("Kalasatama bus stops", 60.1875, 24.9770, 180),
    ("Matinkylä bus terminal", 60.1600, 24.7390, 220),
    ("Tapiola bus terminal", 60.1750, 24.8050, 220),
    ("Espoon keskus bus terminal", 60.2050, 24.6560, 200),
    ("Leppävaara bus terminal", 60.2190, 24.8130, 220),
    ("Tikkurila bus terminal", 60.2925, 25.0440, 220),
    ("Myyrmäki bus terminal", 60.2610, 24.8540, 200),
    ("Mellunmäki bus terminal", 60.2390, 25.1105, 180),
    ("Vuosaari bus terminal", 60.2070, 25.1440, 200),
]

# --------------------------------------------------------------------------- utils

def haversine(a, b):
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371008.8 * math.asin(math.sqrt(h))


def bbox_around(points, margin_m):
    lats = [p[0] for p in points]
    lons = [p[1] for p in points]
    dlat = margin_m / 111_195.0
    dlon = margin_m / (111_195.0 * math.cos(math.radians(sum(lats) / len(lats))))
    return (min(lats) - dlat, min(lons) - dlon, max(lats) + dlat, max(lons) + dlon)


def point_segment_distance(p, a, b):
    """Meters from p to segment ab (local equirectangular projection)."""
    k = math.cos(math.radians(p[0]))
    def xy(q): return ((q[1] - p[1]) * 111_195.0 * k, (q[0] - p[0]) * 111_195.0)
    ax, ay = xy(a); bx, by = xy(b)
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    t = 0 if l2 == 0 else max(0, min(1, (-ax * dx - ay * dy) / l2))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(cx, cy)


def distance_to_line(p, line):
    if len(line) == 1:
        return haversine(p, line[0])
    return min(point_segment_distance(p, line[i], line[i + 1]) for i in range(len(line) - 1))


def parse_levels(value):
    """OSM `level` values: "0", "-1", "0;-1", "-2--1" (range), "1.5". Returns sorted floats."""
    if value is None:
        return []
    out = set()
    for part in str(value).split(";"):
        part = part.strip()
        if not part:
            continue
        m = re.fullmatch(r"(-?\d+(?:\.\d+)?)-(-?\d+(?:\.\d+)?)", part)
        if m:
            lo, hi = sorted((float(m.group(1)), float(m.group(2))))
            v = lo
            while v <= hi + 1e-9:
                out.add(round(v, 1))
                v += 1
            continue
        try:
            out.add(round(float(part), 1))
        except ValueError:
            pass
    return sorted(out)


def http_json(url, data=None, headers=None, retries=3):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, **(headers or {})})
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:  # noqa: BLE001 - report and retry
            if attempt == retries - 1:
                raise
            wait = 5 * (attempt + 1)
            print(f"  ! {e}; retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)


def cached(name, fetch, refresh=False):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not refresh and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    data = fetch()
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f)
    return data

# --------------------------------------------------------------------------- Digitransit

def digitransit(query, variables, key):
    body = json.dumps({"query": query, "variables": variables}).encode()
    res = http_json(DIGITRANSIT, data=body, headers={
        "Content-Type": "application/json", "digitransit-subscription-key": key})
    if res.get("errors"):
        raise RuntimeError(res["errors"])
    return res["data"]


STATIONS_Q = """
query { stations {
  gtfsId name lat lon vehicleMode
  stops { gtfsId name code platformCode lat lon vehicleMode }
} }"""

NEARBY_Q = """
query($lat: Float!, $lon: Float!, $r: Int!) {
  stopsByRadius(lat: $lat, lon: $lon, radius: $r, first: 80) {
    edges { node { stop { gtfsId name code platformCode lat lon vehicleMode } } }
  }
}"""


def hsl_stations(key, refresh):
    """Metro + train stations from GTFS, plus bus terminals assembled from nearby bus stops."""
    data = cached("digitransit_stations.json", lambda: digitransit(STATIONS_Q, {}, key), refresh)
    out = []
    for s in data["stations"] or []:
        mode = (s.get("vehicleMode") or "").upper()
        if mode not in ("SUBWAY", "RAIL"):
            continue
        out.append({
            "id": s["gtfsId"], "name": s["name"], "kind": "metro" if mode == "SUBWAY" else "train",
            "center": [s["lat"], s["lon"]],
            "stops": [st for st in (s.get("stops") or [])],
        })
    for name, lat, lon, radius in BUS_TERMINALS:
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        data = cached(f"terminal_{slug}.json",
                      lambda: digitransit(NEARBY_Q, {"lat": lat, "lon": lon, "r": radius}, key), refresh)
        stops = [e["node"]["stop"] for e in (data.get("stopsByRadius") or {}).get("edges", [])
                 if (e["node"]["stop"].get("vehicleMode") or "").upper() == "BUS"]
        if not stops:
            continue
        out.append({"id": f"terminal:{slug}", "name": name, "kind": "bus", "center": [lat, lon], "stops": stops})
    return out

# --------------------------------------------------------------------------- OpenStreetMap

def overpass_query(bbox):
    s, w, n, e = bbox
    b = f"({s:.6f},{w:.6f},{n:.6f},{e:.6f})"
    return f"""[out:json][timeout:90];
(
  nwr["railway"~"^(subway_entrance|train_station_entrance|platform)$"]{b};
  nwr["public_transport"~"^(platform|station)$"]{b};
  nwr["entrance"]{b};
  nwr["highway"~"^(steps|elevator|footway|corridor|pedestrian|path)$"]{b};
  nwr["indoor"]{b};
  nwr["conveying"]{b};
  nwr["level"]["highway"]{b};
);
(._;>;);
out body;"""


def fetch_osm(station, bbox, refresh):
    key = hashlib.sha1(json.dumps([round(x, 5) for x in bbox]).encode()).hexdigest()[:12]
    def go():
        time.sleep(1.0)  # be polite to the public Overpass instance
        body = urllib.parse.urlencode({"data": overpass_query(bbox)}).encode()
        return http_json(OVERPASS, data=body)
    return cached(f"osm_{key}.json", go, refresh)

# --------------------------------------------------------------------------- model building

ESCALATOR, STAIRS, ELEVATOR, WALK, PLATFORM = "escalator", "stairs", "elevator", "walk", "platform"


@dataclass
class Station:
    id: str
    name: str
    kind: str
    center: list
    stops: list
    levels: list = field(default_factory=list)
    entrances: list = field(default_factory=list)
    platforms: list = field(default_factory=list)
    connectors: list = field(default_factory=list)
    nodes: list = field(default_factory=list)
    edges: list = field(default_factory=list)
    status: str = "empty"
    score: float = 0.0
    missing: list = field(default_factory=list)
    stats: dict = field(default_factory=dict)


def build_station(info, osm):
    st = Station(id=info["id"], name=info["name"], kind=info["kind"], center=info["center"], stops=info["stops"])
    elements = osm.get("elements", [])
    nodes = {e["id"]: e for e in elements if e["type"] == "node"}
    ways = [e for e in elements if e["type"] == "way"]

    def coords(way):
        return [[nodes[n]["lat"], nodes[n]["lon"]] for n in way.get("nodes", []) if n in nodes]

    levels = set()

    # Entrances
    for n in nodes.values():
        t = n.get("tags", {})
        if t.get("railway") in ("subway_entrance", "train_station_entrance") or "entrance" in t:
            if t.get("entrance") == "emergency":
                continue
            lv = parse_levels(t.get("level")) or [0.0]
            levels.update(lv)
            st.entrances.append({
                "id": f"n{n['id']}", "node": n["id"], "pos": [n["lat"], n["lon"]], "level": lv[0],
                "name": t.get("name"), "ref": t.get("ref"),
                "wheelchair": t.get("wheelchair"),
            })

    # Platforms (ways/areas, plus bus-bay nodes)
    for w in ways:
        t = w.get("tags", {})
        if t.get("railway") == "platform" or t.get("public_transport") == "platform":
            lv = parse_levels(t.get("level")) or [0.0]
            levels.update(lv)
            ref = t.get("ref") or t.get("local_ref") or t.get("railway:track_ref")
            st.platforms.append({"id": f"w{w['id']}", "ref": ref, "level": lv[0], "line": coords(w),
                                 "gtfsStops": []})
    for n in nodes.values():
        t = n.get("tags", {})
        if t.get("public_transport") == "platform" and t.get("highway") == "bus_stop":
            lv = parse_levels(t.get("level")) or [0.0]
            ref = t.get("ref") or t.get("local_ref")
            st.platforms.append({"id": f"n{n['id']}", "ref": ref, "level": lv[0], "line": [[n["lat"], n["lon"]]],
                                 "gtfsStops": []})

    # Vertical connectors
    for w in ways:
        t = w.get("tags", {})
        if t.get("highway") == "steps":
            kind = ESCALATOR if t.get("conveying") in ("yes", "forward", "backward", "reversible") else STAIRS
            st.connectors.append({"id": f"w{w['id']}", "kind": kind, "levels": parse_levels(t.get("level")),
                                  "line": coords(w), "conveying": t.get("conveying")})
        elif t.get("highway") == "elevator":
            st.connectors.append({"id": f"w{w['id']}", "kind": ELEVATOR, "levels": parse_levels(t.get("level")),
                                  "line": coords(w)})
    for n in nodes.values():
        t = n.get("tags", {})
        if t.get("highway") == "elevator":
            lv = parse_levels(t.get("level")) or parse_levels(t.get("repeat_on"))
            levels.update(lv)
            st.connectors.append({"id": f"n{n['id']}", "kind": ELEVATOR, "levels": lv,
                                  "line": [[n["lat"], n["lon"]]]})

    # Walk graph: every footway-like way, steps, platform edges
    walkable = []
    for w in ways:
        t = w.get("tags", {})
        hw = t.get("highway")
        if hw in ("footway", "corridor", "pedestrian", "path", "steps", "elevator") or \
           t.get("railway") == "platform" or t.get("public_transport") == "platform" or \
           t.get("indoor") == "corridor":
            if t.get("access") in ("no", "private"):
                continue
            if hw == "steps":
                kind = ESCALATOR if t.get("conveying") in ("yes", "forward", "backward", "reversible") else STAIRS
            elif hw == "elevator":
                kind = ELEVATOR
            elif t.get("railway") == "platform" or t.get("public_transport") == "platform":
                kind = PLATFORM
            else:
                kind = WALK
            lv = parse_levels(t.get("level"))
            levels.update(lv)
            walkable.append((w, kind, lv, t))

    # Node levels: from single-level non-connector ways touching them.
    node_levels = defaultdict(list)
    for w, kind, lv, _ in walkable:
        if kind in (WALK, PLATFORM) and len(lv) == 1:
            for nid in w.get("nodes", []):
                node_levels[nid].append(lv[0])
    for n in nodes.values():
        lv = parse_levels(n.get("tags", {}).get("level"))
        if len(lv) == 1:
            node_levels[n["id"]].append(lv[0])

    index = {}
    def node_index(nid):
        if nid not in index:
            n = nodes[nid]
            lvs = node_levels.get(nid)
            level = max(set(lvs), key=lvs.count) if lvs else None
            index[nid] = len(st.nodes)
            st.nodes.append([round(n["lat"], 6), round(n["lon"], 6), level, nid])
        return index[nid]

    for w, kind, lv, t in walkable:
        ids = [n for n in w.get("nodes", []) if n in nodes]
        for a, b in zip(ids, ids[1:]):
            ia, ib = node_index(a), node_index(b)
            length = haversine(st.nodes[ia][:2], st.nodes[ib][:2])
            oneway = t.get("conveying") in ("forward", "backward")
            direction = 1 if t.get("conveying") == "forward" else (-1 if t.get("conveying") == "backward" else 0)
            st.edges.append([ia, ib, round(length, 1), kind, direction if oneway else 0])

    # Elevators mapped as a single node: no extra edges needed (ways on each level share the node).
    for e in st.entrances:
        if e["node"] in nodes and e["node"] in index:
            e["graphNode"] = index[e["node"]]

    st.levels = sorted(levels) if levels else [0.0]
    match_platforms(st)
    score_station(st)
    return st


def match_platforms(st):
    """Link GTFS platforms (HSL stops) to OSM platforms by ref, then by distance (≤ 40 m)."""
    for stop in st.stops:
        pos = [stop["lat"], stop["lon"]]
        code = stop.get("platformCode") or ""
        best = None
        for p in st.platforms:
            if code and p.get("ref") and str(p["ref"]).strip() == str(code).strip():
                best = p
                break
        if best is None and st.platforms:
            d, p = min(((distance_to_line(pos, p["line"]), p) for p in st.platforms if p["line"]), key=lambda x: x[0],
                       default=(math.inf, None))
            if d <= 40:
                best = p
        if best is not None:
            best["gtfsStops"].append(stop["gtfsId"])


def reachable_from(st, starts):
    adj = defaultdict(list)
    for a, b, _, _, direction in st.edges:
        if direction >= 0:
            adj[a].append(b)
        if direction <= 0:
            adj[b].append(a)
    seen = set(starts)
    q = deque(starts)
    while q:
        u = q.popleft()
        for v in adj[u]:
            if v not in seen:
                seen.add(v)
                q.append(v)
    return seen


def platform_nodes(st, p, tol=15):
    out = set()
    for i, n in enumerate(st.nodes):
        if distance_to_line(n[:2], p["line"]) <= tol:
            out.add(i)
    return out


def score_station(st):
    gtfs_platforms = len(st.stops)
    matched = sum(1 for s in st.stops if any(s["gtfsId"] in p["gtfsStops"] for p in st.platforms))
    multi_level = len(st.levels) > 1
    vertical = [c for c in st.connectors if c["kind"] in (ESCALATOR, STAIRS, ELEVATOR)]
    starts = [e["graphNode"] for e in st.entrances if "graphNode" in e]
    reach = reachable_from(st, starts) if starts else set()
    connected = 0
    used_platforms = [p for p in st.platforms if p["gtfsStops"]]
    for p in used_platforms:
        if reach & platform_nodes(st, p):
            connected += 1

    st.stats = {
        "entrances": len(st.entrances), "gtfsPlatforms": gtfs_platforms, "matchedPlatforms": matched,
        "levels": len(st.levels), "escalators": sum(c["kind"] == ESCALATOR for c in vertical),
        "stairs": sum(c["kind"] == STAIRS for c in vertical), "elevators": sum(c["kind"] == ELEVATOR for c in vertical),
        "graphNodes": len(st.nodes), "graphEdges": len(st.edges),
        "connectedPlatforms": connected, "routablePlatforms": len(used_platforms),
    }

    parts = []
    parts.append(1.0 if st.entrances else 0.0)
    parts.append(matched / gtfs_platforms if gtfs_platforms else (1.0 if st.platforms else 0.0))
    has_data = bool(st.entrances or st.platforms)
    if st.kind != "bus":
        # A single level only counts as "no stairs needed" when something is actually mapped.
        parts.append(1.0 if has_data and (not multi_level or vertical) else 0.0)
    parts.append(connected / len(used_platforms) if used_platforms else 0.0)
    st.score = round(sum(parts) / len(parts), 2)

    if not st.entrances:
        st.missing.append("No entrances mapped (railway=subway_entrance / entrance=*)")
    if gtfs_platforms and matched < gtfs_platforms:
        st.missing.append(f"{gtfs_platforms - matched} of {gtfs_platforms} HSL platforms have no OSM platform nearby "
                          "(railway=platform / public_transport=platform with ref)")
    if st.kind != "bus" and multi_level and not vertical:
        st.missing.append("Several levels but no stairs/escalators/lifts mapped (highway=steps, conveying=*, highway=elevator)")
    if st.kind != "bus" and not multi_level and st.kind == "metro":
        st.missing.append("Only one level found: platform `level` tags are probably missing")
    if used_platforms and connected < len(used_platforms):
        st.missing.append(f"{len(used_platforms) - connected} platform(s) not reachable from an entrance "
                          "(gaps in footways/corridors between entrance and platform)")
    if st.kind != "bus" and not any(c["kind"] == ELEVATOR for c in st.connectors):
        st.missing.append("No lift mapped (step-free route unknown)")

    if not has_data:
        st.status = "empty"
    elif st.score >= 0.95:
        st.status = "complete"
    else:
        st.status = "partial"

# --------------------------------------------------------------------------- output

def to_json(st):
    r6 = lambda pts: [[round(a, 6), round(b, 6)] for a, b in pts]
    return {
        "id": st.id, "name": st.name, "kind": st.kind,
        "center": [round(st.center[0], 6), round(st.center[1], 6)],
        "levels": st.levels, "status": st.status, "score": st.score,
        "entrances": [{k: v for k, v in e.items() if k != "node" and v is not None} for e in st.entrances],
        "platforms": [{**{k: v for k, v in p.items() if k != "line" and v is not None}, "line": r6(p["line"])}
                      for p in st.platforms],
        "connectors": [{**{k: v for k, v in c.items() if k != "line" and v is not None}, "line": r6(c["line"])}
                       for c in st.connectors],
        "graph": {"nodes": [[n[0], n[1], n[2]] for n in st.nodes], "edges": st.edges},
        "stops": [{"id": s["gtfsId"], "code": s.get("code"), "platform": s.get("platformCode"),
                   "pos": [s["lat"], s["lon"]]} for s in st.stops],
        "missing": st.missing,
    }


def write_outputs(stations, out_json, out_docs):
    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    os.makedirs(out_docs, exist_ok=True)
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    dataset = {"version": 1, "generated": now, "attribution": ATTRIBUTION,
               "stations": [to_json(s) for s in stations]}
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(dataset, f, ensure_ascii=False, separators=(",", ":"))

    order = {"complete": 0, "partial": 1, "empty": 2}
    rows = sorted(stations, key=lambda s: (order[s.status], s.kind, -s.score, s.name))
    counts = defaultdict(lambda: defaultdict(int))
    for s in stations:
        counts[s.kind][s.status] += 1

    lines = [
        "# Station data coverage", "",
        f"Generated {now}. {ATTRIBUTION}.", "",
        "| Type | Complete | Partial | Empty |", "|---|---:|---:|---:|",
    ]
    for kind in ("metro", "train", "bus"):
        c = counts[kind]
        lines.append(f"| {kind} | {c['complete']} | {c['partial']} | {c['empty']} |")
    lines += ["", "Score: entrances, HSL platforms matched to OSM, stairs/escalators/lifts between levels, "
              "and a walkable path from an entrance to each platform.", "",
              "| Station | Type | Status | Score | Entrances | Platforms matched | Levels | Esc / Stairs / Lifts | Routable |",
              "|---|---|---|---:|---:|---:|---:|---|---:|"]
    for s in rows:
        x = s.stats
        lines.append(f"| {s.name} | {s.kind} | {s.status} | {s.score:.2f} | {x['entrances']} | "
                     f"{x['matchedPlatforms']}/{x['gtfsPlatforms']} | {x['levels']} | "
                     f"{x['escalators']} / {x['stairs']} / {x['elevators']} | "
                     f"{x['connectedPlatforms']}/{x['routablePlatforms']} |")
    lines += ["", "## What to map", ""]
    for s in rows:
        if s.missing:
            lines.append(f"**{s.name}** ({s.kind}, {s.status})")
            lines += [f"- {m}" for m in s.missing]
            lines.append("")
    with open(os.path.join(out_docs, "coverage.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out_docs, "coverage.json"), "w", encoding="utf-8") as f:
        json.dump([{"id": s.id, "name": s.name, "kind": s.kind, "status": s.status, "score": s.score,
                    **s.stats, "missing": s.missing} for s in rows], f, ensure_ascii=False, indent=1)
    return counts

# --------------------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="*", help="only stations whose name contains one of these")
    ap.add_argument("--refresh", action="store_true", help="ignore cached downloads")
    args = ap.parse_args(argv)

    key = os.environ.get("DIGITRANSIT_API_KEY")
    if not key:
        sys.exit("Set DIGITRANSIT_API_KEY (free key from https://portal-api.digitransit.fi)")

    infos = hsl_stations(key, args.refresh)
    if args.only:
        wanted = [w.lower() for w in args.only]
        infos = [i for i in infos if any(w in i["name"].lower() for w in wanted)]
    print(f"{len(infos)} stations/terminals")

    stations = []
    for n, info in enumerate(infos, 1):
        pts = [info["center"]] + [[s["lat"], s["lon"]] for s in info["stops"]]
        bbox = bbox_around(pts, 150)
        try:
            osm = fetch_osm(info, bbox, args.refresh)
        except Exception as e:  # noqa: BLE001
            print(f"[{n}/{len(infos)}] {info['name']}: Overpass failed ({e}); skipping", file=sys.stderr)
            continue
        st = build_station(info, osm)
        stations.append(st)
        print(f"[{n}/{len(infos)}] {st.name:32} {st.kind:6} {st.status:8} score {st.score:.2f}")

    counts = write_outputs(stations, out_json=OUT_JSON, out_docs=OUT_DOCS)
    print("\nWrote", os.path.relpath(OUT_JSON, ROOT), "and docs/stations/coverage.md")
    for kind, c in counts.items():
        print(f"  {kind:6} complete {c['complete']:3}  partial {c['partial']:3}  empty {c['empty']:3}")


if __name__ == "__main__":
    main()
