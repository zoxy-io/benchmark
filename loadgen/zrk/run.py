#!/usr/bin/env python3
"""zrk load-gen orchestrator for the proxy benchmark (stdlib only).

Runs ONE open-loop linear ramp with zrk (github.com/floatdrop/zrk) and, while it
runs, re-exports zrk's live per-interval stats as a Prometheus /metrics endpoint
so the Grafana "live run" dashboard keeps working — zrk speaks NDJSON + a TUI,
not Prometheus, so this process is the bridge.

zrk writes the source-of-record artifacts the report reads:
  $OUT.ndjson  one JSON object per --interval: offered/achieved/errors + latency
               percentiles (p50,p90,p99,p99.9,max) AND that interval's full
               HdrHistogram blob (--timeseries-histogram), losslessly mergeable.
  $OUT.json    whole-run summary incl. p99.99 and the full HdrHistogram blob.
  $OUT.hgrm    whole-run percentile distribution (HdrHistogram-plotter format).

Config via env (same contract the old vegeta-ramp used, so the drivers barely
change):
  TARGET        full URL, e.g. http://10.0.0.5:8080/1k             (required)
  MAX_RATE      req/s at the end of the ramp                       (default 200000)
  RAMP_SECONDS  ramp length / run duration                         (default 120)
  START_RATE    req/s at t=0                                        (default 200)
  CONNECTIONS   open connections = in-flight cap (open-loop guard)  (default 2000)
  THREADS       OS threads driving zrk's coroutine io engine (zio,  (default 4)
                since v1.0.0; connections are multiplexed across
                them, not one-thread-per-connection) — match the
                loadgen's core count, not CONNECTIONS
  TIMEOUT_S     per-request WIRE timeout, s (hung-conn guard, NOT a
                CO-tail bound — see the --timeout note in main())       (default 1)
  OUT           output BASE path, no extension                     (default /w/ramp)
  NAME          proxy label (logs + `proxy` metric label)          (default ramp)
  RUNID         `testid` metric label                              (default adhoc)
  METRICS_ADDR  Prometheus /metrics listen addr                    (default :8090)
  ZRK           zrk binary path                                    (default /w/zrk)
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def env(k, d):
    v = os.getenv(k)
    return v if v not in (None, "") else d


def envi(k, d):
    try:
        return int(env(k, str(d)))
    except (TypeError, ValueError):
        return d


TARGET = env("TARGET", "")
if not TARGET:
    print("zrk/run.py: TARGET is required", file=sys.stderr)
    sys.exit(2)
MAX_RATE = envi("MAX_RATE", 200000)
RAMP_SECONDS = envi("RAMP_SECONDS", 120)
START_RATE = envi("START_RATE", 200)
CONNECTIONS = envi("CONNECTIONS", 2000)
THREADS = envi("THREADS", 4)
TIMEOUT_S = envi("TIMEOUT_S", 1)
OUT = env("OUT", "/w/ramp")
NAME = env("NAME", "ramp")
RUNID = env("RUNID", "adhoc")
METRICS_ADDR = env("METRICS_ADDR", ":8090")
ZRK = env("ZRK", "/w/zrk")

ND, JSONP, HGRM = OUT + ".ndjson", OUT + ".json", OUT + ".hgrm"

# --- live Prometheus /metrics bridge -----------------------------------------
# Current-window gauges, proxy+testid labels — same shape the old vegeta-ramp
# exported, renamed vegeta_* -> zrk_* (see monitoring/grafana/dashboards).
_lock = threading.Lock()
_cur = {"offered": 0.0, "achieved": 0.0, "err": 0.0,
        "p50": 0.0, "p90": 0.0, "p99": 0.0, "p999": 0.0}
_LBL = f'proxy="{NAME}",testid="{RUNID}"'


def render_metrics():
    with _lock:
        c = dict(_cur)
    lines = [
        "# TYPE zrk_offered_rps gauge",
        f'zrk_offered_rps{{{_LBL}}} {c["offered"]:.3f}',
        "# TYPE zrk_achieved_rps gauge",
        f'zrk_achieved_rps{{{_LBL}}} {c["achieved"]:.3f}',
        "# TYPE zrk_errors_ratio gauge",
        f'zrk_errors_ratio{{{_LBL}}} {c["err"]:.6f}',
        "# TYPE zrk_latency_seconds gauge",
        f'zrk_latency_seconds{{{_LBL},quantile="0.5"}} {c["p50"]:.6f}',
        f'zrk_latency_seconds{{{_LBL},quantile="0.9"}} {c["p90"]:.6f}',
        f'zrk_latency_seconds{{{_LBL},quantile="0.99"}} {c["p99"]:.6f}',
        f'zrk_latency_seconds{{{_LBL},quantile="0.999"}} {c["p999"]:.6f}',
    ]
    return ("\n".join(lines) + "\n").encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") not in ("/metrics", ""):
            self.send_response(404)
            self.end_headers()
            return
        body = render_metrics()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # silence per-request logging
        pass


def serve_metrics():
    host, _, port = METRICS_ADDR.rpartition(":")
    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.serve_forever()


def apply_window(row):
    """Update the live gauges from one NDJSON window (zrk latency is in µs)."""
    lat = row.get("latency_us", {})
    req = row.get("requests", 0) or 0
    err = row.get("errors", 0) or 0
    with _lock:
        _cur["offered"] = float(row.get("target_rate", 0.0))
        _cur["achieved"] = float(row.get("achieved_rate", 0.0))
        _cur["err"] = (err / req) if req else 0.0
        _cur["p50"] = lat.get("p50", 0) / 1e6
        _cur["p90"] = lat.get("p90", 0) / 1e6
        _cur["p99"] = lat.get("p99", 0) / 1e6
        _cur["p999"] = lat.get("p99_9", 0) / 1e6


def summarize(rows):
    """peak SUSTAINED (achieved >= 90% offered) + knee (two windows behind),
    printed so the driver's `grep -E 'peak|knee'` shows live progress."""
    keep = 0.90
    sustained, knee = 0.0, None
    good = [r for r in rows if r["t"] >= 3 and r["offered"] > 0]
    for i, r in enumerate(good):
        if r["achieved"] >= keep * r["offered"]:
            sustained = max(sustained, r["achieved"])
        elif knee is None:
            nxt = good[i + 1] if i + 1 < len(good) else r
            if nxt["achieved"] < keep * nxt["offered"]:
                knee = r["offered"]
    return sustained, knee


def main():
    threading.Thread(target=serve_metrics, daemon=True).start()

    cmd = [
        ZRK,
        "-R", f"{START_RATE}:{MAX_RATE}",
        "-d", f"{RAMP_SECONDS}s",
        "-c", str(CONNECTIONS),
        "-t", str(THREADS),
        # zrk's --timeout is a per-request WIRE timeout (bytes-out -> bytes-in on
        # the socket), NOT a scheduled-latency timeout — it does NOT bound the
        # CO-corrected tail. Past saturation a request waits for a free connection
        # (open-loop backlog), but once it gets one it completes fast on the wire,
        # so it never trips the timeout while its scheduled->response latency
        # balloons to tens of seconds. So this only kills a genuinely HUNG
        # connection; --no-record-timeouts drops those stalls from the histogram.
        # Latency fairness is handled in the REPORT instead, by reading each
        # proxy's p50/p99 at a common sub-knee reference rate (report REF_RATE);
        # overload shows as achieved-shortfall (the shed pane), not as errors.
        "--timeout", f"{TIMEOUT_S}s",
        "--no-record-timeouts",
        "--interval", "1s",
        "--timeseries", ND, "--timeseries-histogram",
        "--hdr", HGRM,
        "--format", "json", "-o", JSONP,
        "--plain",
        TARGET,
    ]
    # start fresh so we only tail this run's windows
    try:
        os.remove(ND)
    except FileNotFoundError:
        pass
    print(f"zrk[{NAME}]: {TARGET}  {START_RATE}..{MAX_RATE} rps over {RAMP_SECONDS}s, "
          f"conns={CONNECTIONS}, threads={THREADS}, metrics {METRICS_ADDR}", file=sys.stderr)
    proc = subprocess.Popen(cmd, stdout=sys.stderr, stderr=sys.stderr)

    # Tail the NDJSON as zrk flushes each line; keep the last gauge live.
    rows = []
    while not os.path.exists(ND) and proc.poll() is None:
        time.sleep(0.05)
    try:
        f = open(ND)
    except FileNotFoundError:
        f = None
    buf = ""
    while f is not None:
        chunk = f.readline()
        if chunk:
            buf += chunk
            if buf.endswith("\n"):
                line, buf = buf.strip(), ""
                if line:
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    rec = {"t": float(row.get("t", 0)),
                           "offered": float(row.get("target_rate", 0.0)),
                           "achieved": float(row.get("achieved_rate", 0.0))}
                    rows.append(rec)
                    apply_window(row)
            continue
        if proc.poll() is not None:
            time.sleep(0.1)  # let the final flush land
            rest = f.read()
            if not rest:
                break
            for line in (buf + rest).splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                rows.append({"t": float(row.get("t", 0)),
                             "offered": float(row.get("target_rate", 0.0)),
                             "achieved": float(row.get("achieved_rate", 0.0))})
                apply_window(row)
            break
        time.sleep(0.1)
    if f is not None:
        f.close()

    rc = proc.wait()
    sustained, knee = summarize(rows)
    print(f"zrk[{NAME}]: peak sustained={sustained:.0f} ok/s; "
          f"knee (achieved<90% offered) at offered={0 if knee is None else knee:.0f}",
          file=sys.stderr)
    print(f"zrk[{NAME}]: wrote {ND}, {JSONP}, {HGRM} ({len(rows)} windows)", file=sys.stderr)
    sys.exit(rc)


if __name__ == "__main__":
    main()
