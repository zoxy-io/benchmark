#!/usr/bin/env python3
"""Render a report from vegeta-ramp CSVs (loadgen/vegeta-ramp) — the open-loop
linear-ramp analogue of report.py.

Unlike report.py (which reads k6 series from Prometheus), the throughput/latency
here come straight from the harness's per-1s-window CSV, whose offered-rate axis
is ANALYTIC (offered = start_rate + slope*t). Proxy CPU is still joined from
Prometheus (cAdvisor) by mapping each sample's wall-clock time -> elapsed ->
offered, so every curve shares one exact offered-load x-axis.

Layout of a run dir (see scripts/vegeta-bench.sh):
  <dir>/meta.json                 {"prom": "...", "runid": "...", "runs": {proxy: {...}}}
     runs[proxy] = {start, end (ISO Z), max_rate, ramp_seconds, start_rate, loadgens:[tag,...]}
  <dir>/<proxy>.<tag>.csv         one per loadgen tag (merged here)

Usage: python3 report/report_vegeta.py <dir>   (PROM_URL overrides meta.prom)
"""
import csv
import glob
import html
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report import (  # noqa: E402
    PALETTE, PROXY_ORDER, CSS, JS, chart_card, prom_query_range,
    iso_to_epoch, fmt_si,
)


def load_merged(run_dir, proxy, tags):
    """Merge per-loadgen CSVs into one window series keyed by elapsed_s.
    Combined offered/achieved are SUMS; latency is the max across loadgens (a
    conservative tail — they hit the same proxy, so distributions track)."""
    per = {}  # elapsed -> [offered, total, ok, p50max, p99max]
    for tag in tags:
        path = os.path.join(run_dir, f"{proxy}.{tag}.csv")
        if not os.path.exists(path):
            continue
        for r in csv.DictReader(open(path)):
            t = int(r["elapsed_s"])
            row = per.setdefault(t, [0.0, 0, 0, 0.0, 0.0])
            row[0] += float(r["offered_rps"])
            row[1] += int(r["total"])
            row[2] += int(r["ok"])
            row[3] = max(row[3], float(r["p50_ms"]))
            row[4] = max(row[4], float(r["p99_ms"]))
    out = []
    for t in sorted(per):
        offered, total, ok, p50, p99 = per[t]
        err = (total - ok) / total if total else 0.0
        out.append({"t": t, "offered": offered, "achieved": ok,
                    "err": err, "p50": p50, "p99": p99})
    return out


def knee(rows):
    """First offered where achieved drops below 95% of offered (the tipping
    point), ignoring the first few noisy warmup seconds."""
    for r in rows:
        if r["t"] >= 3 and r["achieved"] < 0.95 * r["offered"] and r["offered"] > 0:
            return r["offered"]
    return None


def cpu_vs_offered(prom, proxy, run):
    """Proxy container cores over the run, each sample mapped to the offered
    rate it was under: offered(t) = start_rate + slope*(ts - start)."""
    s, e = iso_to_epoch(run["start"]), iso_to_epoch(run["end"])
    slope = (run["max_rate"] - run["start_rate"]) / run["ramp_seconds"]
    q = f'sum(rate(container_cpu_usage_seconds_total{{name="{proxy}"}}[10s]))'
    pts = []
    for ts, cores in prom_query_range(prom, q, s, e):
        offered = run["start_rate"] + slope * (ts - s)
        if offered >= 0:
            pts.append((offered, cores))
    return pts


def build(meta, run_dir, prom):
    runs = meta["runs"]
    present = [p for p in PROXY_ORDER if p in runs] + [p for p in runs if p not in PROXY_ORDER]
    data = {}
    for p in present:
        rows = load_merged(run_dir, p, runs[p].get("loadgens", ["lg1"]))
        data[p] = {"rows": rows, "knee": knee(rows)}

    def line(key):
        out = []
        for p in present:
            pts = [(r["offered"], r[key]) for r in data[p]["rows"]]
            if pts:
                out.append((p, PALETTE.get(p, ("#898781", "#898781")), pts, p == "direct"))
        return out

    sat = [(p, data[p]["knee"]) for p in present if data[p]["knee"]]

    achieved = line("achieved")
    xmax = max((x for _, _, pts, _ in achieved for x, _ in pts), default=1)
    achieved.append(("offered", ("#c3c2b7", "#383835"), [(0, 0), (xmax, xmax)], True))

    cpu = []
    for p in present:
        if p == "direct":
            continue
        pts = cpu_vs_offered(prom, p, runs[p])
        if pts:
            cpu.append((p, PALETTE.get(p, ("#898781", "#898781")), pts, False))

    cards = [
        chart_card("Successful req/s vs offered",
                   "open-loop ramp; dashed gray = perfect keep-up; knee (dotted) = tipping point",
                   "rps", achieved, present, "si", "req/s", sat),
        chart_card("p99 latency vs offered", "tail — explodes at the tipping point",
                   "p99", line("p99"), present, "ms", "ms", sat),
        chart_card("p50 latency vs offered", "median request duration",
                   "p50", line("p50"), present, "ms", "ms", sat),
        chart_card("Proxy CPU vs offered", "container cores (cAdvisor), mapped onto the offered axis",
                   "cpu", cpu, [p for p in present if p != "direct"], "si", "cores", sat),
        chart_card("Error ratio vs offered", "non-2xx / timeouts (shedding or collapse)",
                   "err", line("err"), present, "pct", "", sat),
    ]

    # summary table
    rows_html = ""
    for p in present:
        rows = data[p]["rows"]
        peak = max((r["achieved"] for r in rows), default=0)
        k = data[p]["knee"]
        rows_html += (f"<tr><td>{html.escape(p)}</td><td>{fmt_si(peak)}</td>"
                      f"<td>{fmt_si(k) if k else '—'}</td></tr>")

    legend = "".join(f'<span class="chip"><span class="swatch s-{p}"></span>{p}</span>' for p in present)
    return f"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>vegeta-ramp {html.escape(meta.get('runid',''))}</title><style>{CSS}</style></head>
<body><h1>vegeta-ramp report · {html.escape(meta.get('runid',''))}</h1>
<p class="meta">open-loop linear ramp (Vegeta LinearPacer) · throughput/latency from the harness CSV,
CPU from Prometheus on a shared analytic offered-load axis</p>
<div class="legend">{legend}</div>
<div class="tablewrap"><table><tr><th>proxy</th><th>peak achieved</th><th>knee (tipping point)</th></tr>
{rows_html}</table></div>
<div class="grid2">{''.join(cards)}</div>
<script>{JS}</script></body></html>"""


def main():
    if len(sys.argv) < 2:
        print("usage: report_vegeta.py <run-dir>", file=sys.stderr)
        sys.exit(2)
    run_dir = sys.argv[1]
    meta = json.load(open(os.path.join(run_dir, "meta.json")))
    prom = os.environ.get("PROM_URL", meta.get("prom", "http://localhost:9090"))
    out = build(meta, run_dir, prom)
    dest = os.path.join(run_dir, "report.html")
    open(dest, "w").write(out)
    print(f"wrote {os.path.abspath(dest)}")


if __name__ == "__main__":
    main()
