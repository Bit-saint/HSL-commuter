"""Offline tests for build_stations.py with a synthetic two-level metro station.

Run: python3 -m unittest discover tools/stations
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import build_stations as b  # noqa: E402

LAT, LON = 60.1690, 24.9310
D = 0.0001  # ~11 m north / ~5.5 m east


def node(i, dlat, dlon, **tags):
    return {"type": "node", "id": i, "lat": LAT + dlat * D, "lon": LON + dlon * D, **({"tags": tags} if tags else {})}


def way(i, nodes, **tags):
    return {"type": "way", "id": i, "nodes": nodes, "tags": tags}


def synthetic_osm(connected=True, with_lift=True):
    """
    Street footway (level 0) ─ entrance(1) ─ escalator (0;-1) ─ corridor (-1) ─ platform 1 & 2 (-1)
    """
    elements = [
        node(1, 0, 0, railway="subway_entrance", ref="A", name="Kamppi A"),
        node(2, 0, -3), node(3, 0, 3),
        node(4, 3, 0),       # bottom of escalator
        node(5, 6, 0),       # corridor junction
        node(10, 8, -2), node(11, 8, 6),   # platform 1 edge
        node(12, 10, -2), node(13, 10, 6), # platform 2 edge
    ]
    elements += [
        way(100, [2, 1, 3], highway="footway"),
        way(101, [1, 4], highway="steps", conveying="reversible", level="0;-1"),
        way(102, [4, 5] if connected else [5], highway="corridor", level="-1", indoor="corridor"),
        way(103, [5, 10], highway="footway", level="-1"),
        way(104, [5, 12], highway="footway", level="-1"),
        way(110, [10, 11], railway="platform", ref="1", level="-1"),
        way(111, [12, 13], railway="platform", ref="2", level="-1"),
    ]
    if with_lift:
        elements.append(node(20, 0, 1, highway="elevator", level="0;-1"))
    return {"elements": elements}


def info():
    return {
        "id": "HSL:1000005", "name": "Kamppi", "kind": "metro", "center": [LAT, LON],
        "stops": [
            {"gtfsId": "HSL:1040601", "name": "Kamppi", "code": "H0011", "platformCode": "1",
             "lat": LAT + 8 * D, "lon": LON + 2 * D},
            {"gtfsId": "HSL:1040602", "name": "Kamppi", "code": "H0012", "platformCode": "2",
             "lat": LAT + 10 * D, "lon": LON + 2 * D},
        ],
    }


class LevelTests(unittest.TestCase):
    def test_parse_levels(self):
        self.assertEqual(b.parse_levels("0;-1"), [-1.0, 0.0])
        self.assertEqual(b.parse_levels("-2--1"), [-2.0, -1.0])
        self.assertEqual(b.parse_levels("1.5"), [1.5])
        self.assertEqual(b.parse_levels(None), [])
        self.assertEqual(b.parse_levels("roof"), [])


class StationTests(unittest.TestCase):
    def test_complete_station(self):
        st = b.build_station(info(), synthetic_osm())
        self.assertEqual(st.levels, [-1.0, 0.0])
        self.assertEqual(len(st.entrances), 1)
        self.assertEqual(st.stats["matchedPlatforms"], 2)
        self.assertEqual(st.stats["escalators"], 1)
        self.assertEqual(st.stats["elevators"], 1)
        self.assertEqual(st.stats["connectedPlatforms"], 2)
        self.assertEqual(st.status, "complete", st.missing)
        self.assertEqual(st.missing, [])

    def test_gap_is_reported(self):
        st = b.build_station(info(), synthetic_osm(connected=False, with_lift=False))
        self.assertEqual(st.status, "partial")
        self.assertTrue(any("not reachable" in m for m in st.missing), st.missing)
        self.assertTrue(any("No lift" in m for m in st.missing), st.missing)

    def test_empty_station(self):
        st = b.build_station(info(), {"elements": []})
        self.assertEqual(st.status, "empty")
        self.assertTrue(any("No entrances" in m for m in st.missing))

    def test_outputs(self):
        st = b.build_station(info(), synthetic_osm())
        with tempfile.TemporaryDirectory() as tmp:
            out_json = os.path.join(tmp, "stations.json")
            b.write_outputs([st], out_json=out_json, out_docs=tmp)
            with open(out_json, encoding="utf-8") as f:
                data = json.load(f)
            s = data["stations"][0]
            self.assertEqual(s["name"], "Kamppi")
            self.assertEqual(s["status"], "complete")
            self.assertGreater(len(s["graph"]["nodes"]), 5)
            self.assertIn("graphNode", s["entrances"][0])
            kinds = {e[3] for e in s["graph"]["edges"]}
            self.assertTrue({"walk", "escalator", "platform"} <= kinds)
            with open(os.path.join(tmp, "coverage.md"), encoding="utf-8") as f:
                md = f.read()
            self.assertIn("| metro | 1 | 0 | 0 |", md)


if __name__ == "__main__":
    unittest.main()


class PipelineTests(unittest.TestCase):
    def test_main_with_stubbed_network(self):
        """Runs main() end to end with the two network calls replaced."""
        orig = (b.hsl_stations, b.fetch_osm, b.OUT_JSON, b.OUT_DOCS, os.environ.get("DIGITRANSIT_API_KEY"))
        with tempfile.TemporaryDirectory() as tmp:
            try:
                b.hsl_stations = lambda key, refresh: [info(), {**info(), "id": "x", "name": "Empty", "stops": []}]
                b.fetch_osm = lambda st, bbox, refresh: synthetic_osm() if st["name"] == "Kamppi" else {"elements": []}
                b.OUT_JSON = os.path.join(tmp, "stations.json")
                b.OUT_DOCS = tmp
                os.environ["DIGITRANSIT_API_KEY"] = "test"
                b.main([])
                with open(b.OUT_JSON, encoding="utf-8") as f:
                    data = json.load(f)
                self.assertEqual([s["status"] for s in data["stations"]], ["complete", "empty"])
            finally:
                b.hsl_stations, b.fetch_osm, b.OUT_JSON, b.OUT_DOCS, key = orig
                if key is None:
                    os.environ.pop("DIGITRANSIT_API_KEY", None)
                else:
                    os.environ["DIGITRANSIT_API_KEY"] = key
