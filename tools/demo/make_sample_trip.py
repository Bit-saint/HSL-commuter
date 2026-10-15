#!/usr/bin/env python3
"""Writes App/Resources/Demo/sample-trip.json: a synthetic but realistic recorded commute
(Kallio -> Keilaniemi by metro M1) in the app's TripRecording format, for the demo mode.

Times are seconds since 1970. Positions are approximate. Run: python3 tools/demo/make_sample_trip.py
"""
import json, math, os, random
from datetime import datetime, timezone, timedelta

random.seed(7)
HEL = timezone(timedelta(hours=3))           # EEST on 2026-10-16
def t(hhmmss):
    h, m, s = map(int, hhmmss.split(":"))
    return datetime(2026, 10, 16, h, m, s, tzinfo=HEL).timestamp()

def dist(a, b):
    R = 6371008.8
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    dla, dlo = la2 - la1, math.radians(b[1] - a[1])
    h = math.sin(dla / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dlo / 2) ** 2
    return 2 * R * math.atan2(math.sqrt(h), math.sqrt(1 - h))

def bearing(a, b):
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    dlo = math.radians(b[1] - a[1])
    y = math.sin(dlo) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dlo)
    return (math.degrees(math.atan2(y, x)) + 360) % 360

def cumulative(path):
    c = [0.0]
    for a, b in zip(path, path[1:]):
        c.append(c[-1] + dist(a, b))
    return c

def at(path, cum, d):
    d = max(0, min(d, cum[-1]))
    for i in range(1, len(path)):
        if cum[i] >= d:
            f = (d - cum[i - 1]) / max(cum[i] - cum[i - 1], 1e-9)
            a, b = path[i - 1], path[i]
            return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f), bearing(a, b)
    return path[-1], 0.0

def gp(p): return {"latitude": round(p[0], 6), "longitude": round(p[1], 6)}

# --- Metro M1, Kulosaari -> Aalto-yliopisto (departure times; 20 s dwell)
STATIONS = [
    ("kulo", "Kulosaari",           (60.18870, 25.00720), "07:53:30"),
    ("kala", "Kalasatama",          (60.18748, 24.97727), "07:56:00"),
    ("sorn", "Sörnäinen",           (60.18723, 24.96007), "07:58:00"),
    ("haka", "Hakaniemi",           (60.17919, 24.95127), "08:00:00"),
    ("yli",  "Helsingin yliopisto", (60.17085, 24.94713), "08:01:30"),
    ("rtt",  "Rautatientori",       (60.16995, 24.94055), "08:03:00"),
    ("kamp", "Kamppi",              (60.16916, 24.93184), "08:04:30"),
    ("ruo",  "Ruoholahti",          (60.16339, 24.91519), "08:06:30"),
    ("lsa",  "Lauttasaari",         (60.15893, 24.87915), "08:09:00"),
    ("koi",  "Koivusaari",          (60.16337, 24.85623), "08:11:00"),
    ("kei",  "Keilaniemi",          (60.17580, 24.83010), "08:14:00"),
    ("aalto","Aalto-yliopisto",     (60.18450, 24.82500), "08:15:30"),
]
DWELL, DELAY = 20, 40
shape = []
for i, (_, _, p, _) in enumerate(STATIONS):
    if i:
        a = STATIONS[i - 1][2]
        # A gentle bend between stations so the line isn't stop-to-stop straight.
        for f in (0.33, 0.66):
            bend = 0.00025 * math.sin(f * math.pi) * (1 if i % 2 else -1)
            shape.append((a[0] + (p[0] - a[0]) * f + bend, a[1] + (p[1] - a[1]) * f - bend))
    shape.append(p)
cum = cumulative(shape)
stop_d = []
for _, _, p, _ in STATIONS:
    stop_d.append(min(range(len(shape)), key=lambda k: dist(shape[k], p)))
stop_d = [cum[k] for k in stop_d]

trip_id = "HSL:31M1_20261016_Pe_1_0730"
route = {"id": "HSL:31M1", "shortName": "M1", "longName": "Vuosaari - Kivenlahti", "mode": "metro"}
stops = []
for (sid, name, p, dep), d in zip(STATIONS, stop_d):
    stops.append({"id": f"HSL:demo-{sid}", "name": name, "location": gp(p), "distanceAlong": round(d, 1),
                  "scheduledArrival": t(dep) - DWELL, "scheduledDeparture": t(dep), "isTimingPoint": False})
details = {"tripId": trip_id, "route": route, "directionId": 1, "headsign": "Kivenlahti",
           "serviceDate": "20261016", "shape": [gp(p) for p in shape], "stops": stops,
           "firstDepartureSeconds": 27000}

def vehicle(time):
    """(position, heading, speed, dwelling stop index or None) of the metro at `time`."""
    for i, (_, _, _, dep) in enumerate(STATIONS):
        arr = t(dep) - DWELL + DELAY
        dep_t = t(dep) + DELAY
        if time <= dep_t and (i == 0 or time >= arr):
            p, h = at(shape, cum, stop_d[i] + 0.1)
            return p, h, 0.0, i, stop_d[i]
        if i + 1 < len(STATIONS):
            nxt_arr = t(STATIONS[i + 1][3]) - DWELL + DELAY
            if dep_t < time < nxt_arr:
                f = (time - dep_t) / (nxt_arr - dep_t)
                s = f * f * (3 - 2 * f)                     # accelerate, cruise, brake
                d = stop_d[i] + (stop_d[i + 1] - stop_d[i]) * s
                v = (stop_d[i + 1] - stop_d[i]) * 6 * f * (1 - f) / (nxt_arr - dep_t)
                p, h = at(shape, cum, d)
                return p, h, v, None, d
    p, h = at(shape, cum, stop_d[-1])
    return p, h, 0.0, len(STATIONS) - 1, stop_d[-1]

T0, T_END = t("07:47:00"), t("08:20:00")
vehicles = []
tt = T0
while tt <= t("08:16:30"):
    p, h, v, dwell, d = vehicle(tt)
    if dwell is not None:
        nxt = min(dwell + 1, len(STATIONS) - 1)
    else:
        nxt = next(k for k, sd in enumerate(stop_d) if sd > d)
    o = {"vehicleId": "50/131", "timestamp": tt, "event": "vp", "location": gp(p), "speed": round(v, 2),
         "heading": round(h, 1), "scheduleOffset": -DELAY, "doorsOpen": dwell is not None,
         "occupancyPercent": 38, "nextStopId": stops[nxt]["id"].split(":")[1], "locationSource": "GPS"}
    if dwell is not None:
        o["stopId"] = stops[dwell]["id"].split(":")[1]
    vehicles.append({"tripId": trip_id, "observation": o})
    tt += 2

# --- You: home in Kallio, walk to Sörnäinen, ride to Keilaniemi, walk to work.
HOME, WORK = (60.18395, 24.95325), (60.17720, 24.82720)
walk1 = [HOME, (60.18440, 24.95560), (60.18560, 24.95830), (60.18690, 24.95985), STATIONS[2][2]]
walk2 = [STATIONS[10][2], (60.17650, 24.82850), WORK]
c1, c2 = cumulative(walk1), cumulative(walk2)
LEAVE, PACE = t("07:51:15"), 1.55
at_station = LEAVE + c1[-1] / PACE
board = t(STATIONS[2][3]) + DELAY - 5
alight = t(STATIONS[10][3]) - DWELL + DELAY + 10
at_work = alight + c2[-1] / 1.4

locations = []
tt = T0
while tt <= T_END:
    jitter = lambda: (random.gauss(0, 0.00003), random.gauss(0, 0.00005))
    if tt < LEAVE:
        j = jitter(); p, speed, course, acc = (HOME[0] + j[0], HOME[1] + j[1]), 0.0, -1.0, 12.0
    elif tt < at_station:
        p, course = at(walk1, c1, (tt - LEAVE) * PACE); speed, acc = PACE, 8.0
    elif tt < board:
        j = jitter(); p, speed, course, acc = (STATIONS[2][2][0] + j[0] / 3, STATIONS[2][2][1] + j[1] / 3), 0.0, -1.0, 15.0
    elif tt < alight:
        p, course, speed, _, _ = vehicle(tt); acc = 30.0
    elif tt < at_work:
        p, course = at(walk2, c2, (tt - alight) * 1.4); speed, acc = 1.4, 8.0
    else:
        j = jitter(); p, speed, course, acc = (WORK[0] + j[0], WORK[1] + j[1]), 0.0, -1.0, 10.0
    locations.append({"time": tt, "latitude": round(p[0], 6), "longitude": round(p[1], 6),
                      "accuracy": acc, "speed": round(speed, 2), "course": round(course, 1)})
    tt += 1

def place(name, p, stop=None):
    out = {"name": name, "location": gp(p)}
    if stop: out["stop"] = stop
    return out

def stopref(k):
    sid, name, p, _ = STATIONS[k]
    return {"id": f"HSL:demo-{sid}", "name": name, "location": gp(p), "mode": "metro", "zone": "A" if k < 9 else "B"}

b, a = 2, 10
i0 = min(range(len(shape)), key=lambda k: dist(shape[k], STATIONS[b][2]))
i1 = min(range(len(shape)), key=lambda k: dist(shape[k], STATIONS[a][2]))
legs = [
    {"mode": "walk", "scheduledStart": LEAVE, "scheduledEnd": LEAVE + 360, "distance": round(c1[-1]),
     "from": place("Home", HOME), "to": place(STATIONS[b][1], STATIONS[b][2], stopref(b)),
     "geometry": [gp(p) for p in walk1], "isRealtime": False},
    {"mode": "metro", "scheduledStart": t(STATIONS[b][3]), "scheduledEnd": t(STATIONS[a][3]) - DWELL,
     "estimatedStart": t(STATIONS[b][3]) + DELAY, "estimatedEnd": t(STATIONS[a][3]) - DWELL + DELAY,
     "distance": round(stop_d[a] - stop_d[b]),
     "from": place(STATIONS[b][1], STATIONS[b][2], stopref(b)), "to": place(STATIONS[a][1], STATIONS[a][2], stopref(a)),
     "geometry": [gp(p) for p in shape[i0:i1 + 1]], "route": route,
     "trip": {"tripId": trip_id, "directionId": 1, "serviceDate": "20261016", "headsign": "Kivenlahti",
              "firstDepartureSeconds": 27000},
     "headsign": "Kivenlahti", "isRealtime": True},
    {"mode": "walk", "scheduledStart": t(STATIONS[a][3]) - DWELL + DELAY, "scheduledEnd": t(STATIONS[a][3]) - DWELL + DELAY + 200,
     "distance": round(c2[-1]), "from": place(STATIONS[a][1], STATIONS[a][2], stopref(a)), "to": place("Work", WORK),
     "geometry": [gp(p) for p in walk2], "isRealtime": False},
]
itinerary = {"start": legs[0]["scheduledStart"], "end": legs[-1]["scheduledEnd"], "legs": legs,
             "walkDistance": round(c1[-1] + c2[-1]), "fare": {"name": "AB", "price": 3.2, "currency": "EUR"}}

recording = {"version": 1, "name": "Demo: Kallio → Keilaniemi (M1)", "destinationName": "Work · Keilaniemi",
             "startedAt": T0, "endedAt": T_END, "itinerary": itinerary, "trips": [details],
             "vehicles": vehicles, "locations": locations}
out = os.path.join(os.path.dirname(__file__), "..", "..", "App", "Resources", "Demo", "sample-trip.json")
with open(out, "w") as f:
    json.dump(recording, f, ensure_ascii=False, separators=(",", ":"))
print(f"wrote {os.path.normpath(out)}: {len(vehicles)} vehicle fixes, {len(locations)} locations, "
      f"walk {c1[-1]:.0f} m, at station {datetime.fromtimestamp(at_station, HEL):%H:%M:%S}, "
      f"metro dep {datetime.fromtimestamp(t(STATIONS[b][3]) + DELAY, HEL):%H:%M:%S}")
