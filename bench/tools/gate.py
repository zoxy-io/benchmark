#!/usr/bin/env python3
"""Phase 0 gate: prove bench/src/analysis.zig reproduces report/report.py.

The Zig rewrite replaces ~1100 lines of Python that encode a series of
hard-won corrections — dropping zrk's end-of-run partial flush, referencing
offered at the window midpoint, the keep-up BAND that rejects post-knee
catch-up bursts, the neighborhood-merged p99. A transliteration of that is easy
to get subtly wrong in a way no unit test catches, so the gate is a numeric diff
of the two implementations' report.json over REAL run directories.

Usage:
    python3 bench/tools/gate.py results/<rundir> [...]

Runs report.py (against a stub Prometheus, see below) and `bench report` over
each directory and compares the results field by field.

Two intentional exemptions:

  * `mem` and `series.cpu` came from Prometheus, which this rewrite removes in
    favour of the Zig driver polling cAdvisor directly into per-run artifacts.
    Historical runs have no such artifacts, so both sides are empty here and the
    comparison is vacuous. They are covered by Phase 4's live smoke test instead.

  * Floats may differ by one unit in the last emitted decimal. Python's round()
    is half-to-even on the exact binary value; the Zig writer rounds the shortest
    round-tripping repr instead (see bench/src/jsonw.zig for why). That is a
    rendering difference, never a measurement one, so the tolerance is one unit
    in the last place of whatever precision the field is emitted at.
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

# Decimal places each numeric field is emitted at, mirroring report.py's
# build_json. Tolerance for a field is one unit in its last place.
PRECISION = {
    "series.rps.x": 1, "series.rps.y": 1,
    "series.cpu.x": 1, "series.cpu.y": 6,
    "series.p99_ms.x": 1, "series.p99_ms.y": 4,
    "series.shed.x": 1, "series.shed.y": 6,
    "hist.x": 4, "hist.y": 4,
    "latency_ms": 4,
}

EMPTY = json.dumps(
    {"status": "success", "data": {"resultType": "matrix", "result": []}}
).encode()


class StubProm(BaseHTTPRequestHandler):
    """report.py hard-crashes if Prometheus is unreachable (no try/except round
    urlopen), and the fleet whose Prometheus it recorded is long destroyed. A
    successful-but-empty query_range makes it take its own graceful-degradation
    path, leaving every NDJSON-derived number — the set under test — intact."""

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(EMPTY)))
        self.end_headers()
        self.wfile.write(EMPTY)

    def log_message(self, *a):
        pass


def close(a, b, digits):
    if a is None or b is None:
        return a == b
    return abs(a - b) <= 1.01 * 10 ** -digits


def cmp_pts(path, x, y, out):
    if len(x) != len(y):
        out.append(f"{path}: point count {len(x)} != {len(y)}")
        return
    xd = PRECISION.get(path + ".x", 4)
    yd = PRECISION.get(path + ".y", 4)
    for i, (p, q) in enumerate(zip(x, y)):
        if not close(p[0], q[0], xd) or not close(p[1], q[1], yd):
            out.append(f"{path}[{i}]: {p} != {q}")
            if len([o for o in out if o.startswith(path)]) > 3:
                return


def compare(py, zg):
    out = []

    for k in ("schema", "runid"):
        if py.get(k) != zg.get(k):
            out.append(f"{k}: {py.get(k)!r} != {zg.get(k)!r}")

    if py.get("ramp") != zg.get("ramp"):
        out.append(f"ramp: {py.get('ramp')} != {zg.get('ramp')}")
    if py.get("palette") != zg.get("palette"):
        out.append(f"palette: {py.get('palette')} != {zg.get('palette')}")
    if py.get("units") != zg.get("units"):
        out.append("units differ")

    # proxies: order matters (sustained-descending drives the summary table)
    pp, zp = py.get("proxies", []), zg.get("proxies", [])
    if [p["name"] for p in pp] != [p["name"] for p in zp]:
        out.append(f"proxy order: {[p['name'] for p in pp]} != {[p['name'] for p in zp]}")
    else:
        for a, b in zip(pp, zp):
            n = a["name"]
            for k in ("self", "baseline", "sustained", "hgrm_file"):
                if a[k] != b[k]:
                    out.append(f"proxies[{n}].{k}: {a[k]!r} != {b[k]!r}")
            la, lb = a["latency_ms"], b["latency_ms"]
            if la["source"] != lb["source"]:
                out.append(f"proxies[{n}].latency.source: {la['source']} != {lb['source']}")
            for k in ("p50", "p99"):
                if not close(la[k], lb[k], PRECISION["latency_ms"]):
                    out.append(f"proxies[{n}].latency.{k}: {la[k]} != {lb[k]}")

    for key in ("rps", "p99_ms", "shed"):
        a = {s["name"]: s for s in py.get("series", {}).get(key, [])}
        b = {s["name"]: s for s in zg.get("series", {}).get(key, [])}
        if set(a) != set(b):
            out.append(f"series.{key}: names {sorted(a)} != {sorted(b)}")
            continue
        for n in a:
            for flag in ("ref", "baseline"):
                if a[n].get(flag) != b[n].get(flag):
                    out.append(f"series.{key}[{n}].{flag}: {a[n].get(flag)} != {b[n].get(flag)}")
            cmp_pts(f"series.{key}", a[n]["pts"], b[n]["pts"], out)

    ah, bh = py.get("hist", {}), zg.get("hist", {})
    if set(ah) != set(bh):
        out.append(f"hist: proxies {sorted(ah)} != {sorted(bh)}")
    else:
        for n in ah:
            cmp_pts("hist", ah[n]["pts"], bh[n]["pts"], out)

    return out


def main():
    dirs = sys.argv[1:]
    if not dirs:
        print(__doc__)
        return 2

    srv = HTTPServer(("127.0.0.1", 9099), StubProm)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    failed = 0
    for d in dirs:
        # Both generators write report.json INTO the run dir, so work on a copy
        # of the inputs. Overwriting the originals would destroy the recorded
        # `mem` and `series.cpu` — the one thing in an archived run that cannot
        # be regenerated, since the Prometheus that produced it is long gone.
        with tempfile.TemporaryDirectory(prefix="bench-gate-") as tmp:
            work = os.path.join(tmp, os.path.basename(d.rstrip("/")))
            os.makedirs(work)
            for pat in ("*.ndjson", "*.hgrm", "meta.json"):
                for f in glob.glob(os.path.join(d, pat)):
                    shutil.copy2(f, work)

            subprocess.run(
                [sys.executable, "report/report.py", work],
                check=True, capture_output=True,
                env={"PATH": "/usr/bin:/bin", "PROM_URL": "http://127.0.0.1:9099"},
            )
            py = json.load(open(f"{work}/report.json"))

            subprocess.run(
                ["bench/zig-out/bin/bench", "report", work, "--generated", py["generated"]],
                check=True, capture_output=True,
            )
            zg = json.load(open(f"{work}/report.json"))

        diffs = compare(py, zg)
        if diffs:
            failed += 1
            print(f"FAIL {d}")
            for line in diffs[:25]:
                print(f"     {line}")
            if len(diffs) > 25:
                print(f"     ... and {len(diffs) - 25} more")
        else:
            n = len(py.get("proxies", []))
            print(f"ok   {d}  ({n} proxies)")

    srv.shutdown()
    print(f"\n{len(dirs) - failed}/{len(dirs)} run dirs match")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
