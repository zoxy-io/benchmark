#!/usr/bin/env python3
"""Render the benchmark report from vegeta-ramp CSVs (loadgen/vegeta-ramp).

Throughput/latency come straight from the harness's per-1s-window CSV, whose
offered-rate axis is ANALYTIC (offered = start_rate + slope*t). Proxy CPU is
joined from
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
from charts import (  # noqa: E402
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
        # charts.py's yfmt="ms" formatter expects the latency series in SECONDS
        # (it scales x1000 for display); the harness CSV is in ms, so convert here.
        out.append({"t": t, "offered": offered, "achieved": ok,
                    "err": err, "p50": p50 / 1000.0, "p99": p99 / 1000.0})
    return out


KEEPUP = 0.90  # "keeping up" = achieved >= KEEPUP * offered


def knee(rows):
    """Offered rate at the tipping point: the first window (after warmup) where
    the proxy stops keeping up (achieved < KEEPUP*offered) AND stays below for
    the next window too — so a single transient dip doesn't trip it. This is the
    x-axis marker; the headline number is `sustained()`."""
    good = [r for r in rows if r["t"] >= 3 and r["offered"] > 0]
    for i, r in enumerate(good):
        if r["achieved"] < KEEPUP * r["offered"]:
            nxt = good[i + 1] if i + 1 < len(good) else r
            if nxt["achieved"] < KEEPUP * nxt["offered"]:
                return r["offered"]
    return None


def sustained(rows):
    """Max SUSTAINABLE throughput: the highest achieved rate while the proxy is
    still delivering >= KEEPUP of what's offered. This is the real "how fast can
    it go" number — it excludes both the pre-knee ramp (achieved==offered, not a
    limit) and the post-knee thrash (bursts of high achieved while badly behind
    offered, which the old max-achieved 'peak' wrongly caught)."""
    best = 0
    for r in rows:
        if r["t"] >= 3 and r["offered"] > 0 and r["achieved"] >= KEEPUP * r["offered"]:
            best = max(best, r["achieved"])
    return best


def _expand_cpuset(cpuset):
    """"0-3,6" -> "0|1|2|3|6" for a prometheus cpu=~ regex."""
    out = []
    for part in cpuset.split(","):
        if "-" in part:
            a, b = part.split("-")
            out += [str(i) for i in range(int(a), int(b) + 1)]
        elif part:
            out.append(part)
    return "|".join(out)


def cpu_vs_offered(prom, proxy, run):
    """Proxy cores over the run, each sample mapped to the offered rate it was
    under: offered(t) = start_rate + slope*(ts - start).

    PRIMARY = the cAdvisor CONTAINER metric — the proxy PROCESS's CPU, which is
    what Grafana shows and the honest "proxy CPU" (it excludes the loopback
    softirq that runs on the same cores). FALLBACK, only when cadvisor dropped
    the container's `name` label (it does that once a container exits, so some
    runs are missing it), = node_exporter per-core busy time on the recorded
    `proxy_cpuset`; that reads a bit HIGH because it includes that softirq."""
    s, e = iso_to_epoch(run["start"]), iso_to_epoch(run["end"])
    slope = (run["max_rate"] - run["start_rate"]) / run["ramp_seconds"]

    def series(q):
        return [(run["start_rate"] + slope * (ts - s), cores)
                for ts, cores in prom_query_range(prom, q, s, e)
                if run["start_rate"] + slope * (ts - s) >= 0]

    pts = series(f'sum(rate(container_cpu_usage_seconds_total{{name="{proxy}"}}[10s]))')
    if pts:
        return pts
    cpuset = run.get("proxy_cpuset")
    if cpuset:
        cpus = _expand_cpuset(cpuset)
        pts = series(f'sum(rate(node_cpu_seconds_total{{cpu=~"{cpus}"}}[10s])) '
                     f'- sum(rate(node_cpu_seconds_total{{cpu=~"{cpus}",mode="idle"}}[10s]))')
    return pts


def build(meta, run_dir, prom):
    runs = meta["runs"]
    present = [p for p in PROXY_ORDER if p in runs] + [p for p in runs if p not in PROXY_ORDER]
    data = {}
    for p in present:
        rows = load_merged(run_dir, p, runs[p].get("loadgens", ["lg1"]))
        data[p] = {"rows": rows, "knee": knee(rows), "sustained": sustained(rows)}

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
    for p in sorted(present, key=lambda p: data[p]["sustained"], reverse=True):
        s = data[p]["sustained"]
        k = data[p]["knee"]
        cls = ' class="baseline"' if p == "direct" else ""
        rows_html += (f"<tr{cls}><td>{html.escape(p)}</td><td>{fmt_si(s)}</td>"
                      f"<td>{fmt_si(k) if k else '—'}</td></tr>")

    legend = "".join(f'<span class="chip"><span class="swatch s-{p}"></span>{p}</span>' for p in present)
    rid = html.escape(meta.get("runid", ""))
    return f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0e1016">
<title>zoxy bench · {rid}</title><style>{CSS}</style></head>
<body>
<div class="eyebrow">L4 proxy benchmark · open-loop ramp</div>
<h1>relay throughput <span class="rid">{rid}</span></h1>
<p class="meta">Every proxy driven through the identical linear ramp (Vegeta LinearPacer, coordinated-omission safe).
Throughput &amp; latency from the harness CSV, proxy CPU from Prometheus — all on one analytic offered-load axis.</p>
<div class="legend">{legend}</div>
<div class="tablewrap"><table><tr><th>proxy</th><th>max sustained req/s</th><th>knee @ offered</th></tr>
{rows_html}</table></div>
<div class="grid2">{''.join(cards)}</div>
<footer>generated by report/report_vegeta.py — <a href="https://zoxy.io">zoxy.io</a></footer>
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
