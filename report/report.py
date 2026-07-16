#!/usr/bin/env python3
"""Render the benchmark report from zrk per-interval NDJSON (loadgen/zrk).

Throughput/latency come straight from zrk's per-1s-window NDJSON, whose
offered-rate axis is the ramp's analytic target rate. Latency is
coordinated-omission-corrected and carries the full HdrHistogram tail
(p50/p90/p99/p99.9/max per window; p99.99 + a mergeable blob for the whole run).
Proxy CPU is joined from Prometheus (cAdvisor) by mapping each sample's
wall-clock time -> elapsed -> offered, so every curve shares one offered-load axis.

Layout of a run dir (see scripts/zrk-bench.sh):
  <dir>/meta.json                 {"prom": "...", "runid": "...", "runs": {proxy: {...}}}
     runs[proxy] = {start, end (ISO Z), max_rate, ramp_seconds, start_rate, loadgens:[tag,...]}
  <dir>/<proxy>.<tag>.ndjson      per-interval NDJSON, one per loadgen tag (merged here)
  <dir>/<proxy>.<tag>.json        whole-run summary (latency_us incl. p99.99, max)

Usage: python3 report/report.py <dir>   (PROM_URL overrides meta.prom)
"""
import html
import json
import math
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from charts import (  # noqa: E402
    PALETTE, PROXY_ORDER, CSS, JS, chart_card, prom_query_range,
    iso_to_epoch, fmt_si, fmt_bytes, nice_ticks,
)
import hdr  # noqa: E402


def read_ndjson(path):
    """Parse an NDJSON file into a list of dicts in emission order (skip junk)."""
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path) as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                rows.append(json.loads(raw))
            except json.JSONDecodeError:
                continue
    return rows


def full_windows(rows):
    """The measurement windows worth trusting, dropping zrk's end-of-run PARTIAL
    flush. zrk closes a run with a final sub-interval window (dt << the ~1s grid)
    whose achieved_rate is a handful of requests over a sliver of wall-clock — a
    backlog-drain burst, not steady state. Its rate lands anywhere (a collapsed
    proxy's hit 0.94x offered, sneaking past the keep-up band to fake a 62k
    'sustained'), so exclude any window narrower than half the run's median window.
    `rows` are parsed NDJSON dicts in emission order; window width = gap to the
    prior row's timestamp (first row: from t=0)."""
    ts = [float(r.get("t", 0)) for r in rows]
    dts = [ts[k] - (ts[k - 1] if k else 0.0) for k in range(len(ts))]
    nominal = sorted(dts)[len(dts) // 2] if dts else 0.0
    return [r for r, dt in zip(rows, dts) if not (nominal > 0 and dt < 0.5 * nominal)]


def load_merged(run_dir, proxy, tags):
    """Merge per-loadgen NDJSON into one window series, ALIGNED BY INTERVAL INDEX.
    Combined offered/achieved are SUMS ACROSS LOADGENS (each loadgen emits one row
    per interval); latency is the max across loadgens (a conservative tail — they
    hit the same proxy, so distributions track). zrk latency is in microseconds;
    charts want seconds, so divide by 1e6.

    We bucket by each loadgen's interval SEQUENCE INDEX, not by rounded wall-clock
    seconds. zrk's ~1s grid drifts, so a single loadgen can emit two rows that
    round to the same integer second (notably the last on-grid window plus the
    end-of-run flush row at t≈duration+ε). Rounding-then-summing fused those two
    windows and DOUBLED that point's offered/achieved — a phantom spike at the
    right edge of every chart. Index alignment sums only matching intervals across
    loadgens and never fuses a loadgen's own adjacent windows. The end-of-run
    partial flush is dropped up front (see full_windows)."""
    per = {}  # interval_idx -> [offered, achieved, req, err, p50us, p99us, p999us, maxus, elapsed_s]
    for tag in tags:
        rows = full_windows(read_ndjson(os.path.join(run_dir, f"{proxy}.{tag}.ndjson")))
        for i, r in enumerate(rows):
            lat = r.get("latency_us", {})
            row = per.setdefault(i, [0.0, 0.0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0.0])
            row[0] += float(r.get("target_rate", 0.0))     # offered
            row[1] += float(r.get("achieved_rate", 0.0))   # achieved (req/s)
            row[2] += int(r.get("requests", 0))            # window req count
            row[3] += int(r.get("errors", 0))              # window err count
            row[4] = max(row[4], float(lat.get("p50", 0)))
            row[5] = max(row[5], float(lat.get("p99", 0)))
            row[6] = max(row[6], float(lat.get("p99_9", 0)))
            row[7] = max(row[7], float(lat.get("max", 0)))
            row[8] = max(row[8], float(r.get("t", 0)))     # elapsed (warmup filter)
    out = []
    for i in sorted(per):
        offered, achieved, total, errs, p50, p99, p999, mx, t = per[i]
        err = errs / total if total else 0.0
        # shed = fraction of OFFERED load the proxy never served. L4 passthroughs
        # don't reject or time out under overload (err stays ~0) — they just can't
        # keep up, so the shortfall (achieved < offered) is the real "shedding".
        shed = max(0.0, 1.0 - achieved / offered) if offered else 0.0
        # latency series are handed to charts in SECONDS (yfmt="ms" scales x1000).
        out.append({"t": t, "offered": offered, "achieved": achieved, "err": err,
                    "shed": shed, "p50": p50 / 1e6, "p99": p99 / 1e6,
                    "p999": p999 / 1e6, "max": mx / 1e6})
    return out


def capped_hist(run_dir, proxy, tags):
    """Merge the per-window HdrHistogram blobs (zrk --timeseries-histogram) for
    the windows where THIS proxy has near-zero backlog (achieved >= LAT_KEEPUP*
    offered = 99%, after warmup) — its latency at HEALTHY load, PER PROXY,
    excluding the near-saturation/post-collapse edge where the CO-corrected tail
    balloons. hdr.Hdr or None."""
    for tag in tags:
        path = os.path.join(run_dir, f"{proxy}.{tag}.ndjson")
        if not os.path.exists(path):
            continue
        blobs = []
        for r in full_windows(read_ndjson(path)):
            off, ach = float(r.get("target_rate", 0)), float(r.get("achieved_rate", 0))
            # Same keep-up BAND as sustained(): near-zero backlog means achieved
            # tracks offered from BOTH sides. A catch-up burst (achieved >> offered)
            # carries balloon latencies and must not pollute the healthy histogram.
            if r.get("t", 0) >= 3 and off > 0 and r.get("latency_histogram") and \
                    LAT_KEEPUP * off <= ach <= off / LAT_KEEPUP:
                blobs.append(r["latency_histogram"])
        return hdr.merge(blobs)
    return None


def hgrm_filename(run_dir, proxy, tags):
    """Basename of the whole-run .hgrm (for a relative download link), or ''."""
    for tag in tags:
        f = f"{proxy}.{tag}.hgrm"
        if os.path.exists(os.path.join(run_dir, f)):
            return f
    return ""


def hdr_points(h):
    """(n = 1/(1-percentile), latency_ms) points across the range for hist_svg."""
    if h is None or h.total() == 0:
        return []
    total = h.total()
    pts, n = [], 1.0
    while n < total:
        pts.append((n, h.value_at_percentile(100.0 * (1.0 - 1.0 / n)) / 1000.0))
        n *= 10 ** 0.1                               # ~10 points per decade
    pts.append((float(total), h.max() / 1000.0))     # true max at the far right
    return pts


KEEPUP = 0.90  # throughput: "keeping up" = achieved >= KEEPUP * offered
LAT_KEEPUP = 0.99  # latency DISTRIBUTION (capped_hist): stricter — only near-zero-
# backlog windows count, so the tail isn't inflated by the 90%-keeping-up
# (already-queuing) edge.
P99_KEEPUP = 0.95  # p99-vs-offered CURVE only: looser than the histogram so the
# line isn't starved — 0.99 drops ~78% of windows, leaving a sparse, low-res
# curve; <=5% backlog is still a fair per-window p99 reading and ~triples points.


def sustained(rows):
    """Max SUSTAINABLE throughput: the highest achieved rate while the proxy is
    still delivering >= KEEPUP of what's offered. This is the real "how fast can
    it go" number — it excludes both the pre-knee ramp (achieved==offered, not a
    limit) and the post-knee thrash (bursts of high achieved while badly behind
    offered, which the old max-achieved 'peak' wrongly caught)."""
    best = 0
    for r in rows:
        # Keep-up is a BAND, not a floor. A window whose achieved massively
        # OVERSHOOTS offered isn't sustained throughput — it's zrk's open-loop
        # catch-up draining backlog after a stall (CO correction). Bounding above
        # by offered/KEEPUP rejects that post-knee thrash, the very burst the old
        # one-sided `achieved >= KEEPUP*offered` wrongly counted as a new peak.
        if r["t"] >= 3 and r["offered"] > 0 and \
                KEEPUP * r["offered"] <= r["achieved"] <= r["offered"] / KEEPUP:
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

    # [8s] over 1s cadvisor scrapes: cadvisor's counter ticks at housekeeping
    # cadence (~1-1.5s effective), so a tighter window catches duplicate samples
    # at its edges and rate() dips spuriously; 8s covers ~6 ticks — smooth, and
    # still one point per 1s step (vs the old 10s window on a 5s step). The node
    # fallback keeps [10s]: that job scrapes at 5s and needs two samples.
    pts = series(f'sum(rate(container_cpu_usage_seconds_total{{name="{proxy}"}}[8s]))')
    if pts:
        return pts
    cpuset = run.get("proxy_cpuset")
    if cpuset:
        cpus = _expand_cpuset(cpuset)
        pts = series(f'sum(rate(node_cpu_seconds_total{{cpu=~"{cpus}"}}[10s])) '
                     f'- sum(rate(node_cpu_seconds_total{{cpu=~"{cpus}",mode="idle"}}[10s]))')
    return pts


def _ms(v):
    return "—" if v is None else (f"{v:.0f}ms" if v >= 10 else f"{v:.1f}ms")


def hist_svg(proxy, pts):
    """A latency-by-percentile SVG from hdr_points() (the merged live histogram,
    NOT the .hgrm file — that's only the download link): log x = 1/(1-percentile)
    (so p0/p90/p99/p99.9… are evenly spaced), linear y = latency ms."""
    if not pts:
        return "<p class='empty'>no histogram</p>"
    W, H, ML, MR, MT, MB = 720, 300, 62, 16, 22, 44
    yticks = nice_ticks(0, max(v for _, v in pts))
    ymaxt = yticks[-1]
    xmax = max((math.log10(n) for n, _ in pts), default=1) or 1.0

    def X(lx):
        return ML + (W - ML - MR) * lx / xmax

    def Y(v):
        return H - MB - (H - MB - MT) * min(v, ymaxt) / ymaxt

    def fms(v):
        return f"{v:.0f}" if v >= 10 else (f"{v:.1f}" if v >= 1 else f"{v:.2g}")

    out = [f'<svg viewBox="0 0 {W} {H}" role="img">']
    for t in yticks:
        out.append(f'<line class="grid" x1="{ML}" y1="{Y(t):.1f}" x2="{W-MR}" y2="{Y(t):.1f}"/>')
        out.append(f'<text class="tick" x="{ML-8}" y="{Y(t)+4:.1f}" text-anchor="end">{fms(t)}</text>')
    k = 0
    while k <= xmax + 1e-9:                              # decade gridlines = percentiles
        lx = float(k)
        lbl = "0%" if k == 0 else f"{(1 - 10.0 ** (-k)) * 100:g}%"
        out.append(f'<line class="grid" x1="{X(lx):.1f}" y1="{MT}" x2="{X(lx):.1f}" y2="{H-MB}"/>')
        out.append(f'<text class="tick" x="{X(lx):.1f}" y="{H-MB+18}" text-anchor="middle">{lbl}</text>')
        k += 1
    out.append(f'<line class="axis" x1="{ML}" y1="{H-MB}" x2="{W-MR}" y2="{H-MB}"/>')
    out.append(f'<text class="axis-label" x="{(ML+W-MR)/2}" y="{H-6}" text-anchor="middle">percentile</text>')
    out.append(f'<text class="axis-label" x="14" y="10" text-anchor="start">ms</text>')
    d = " ".join(f"{X(math.log10(n)):.1f},{Y(v):.1f}" for n, v in pts)
    out.append(f'<polyline class="line s-{proxy}" points="{d}" fill="none" stroke-width="2"/>')
    out.append('</svg>')
    return "".join(out)


def peak_mem(prom, proxy, run):
    """Peak proxy-container working-set bytes over the run (cAdvisor)."""
    s, e = iso_to_epoch(run["start"]), iso_to_epoch(run["end"])
    pts = prom_query_range(prom, f'max(container_memory_working_set_bytes{{name="{proxy}"}})', s, e)
    return max((v for _, v in pts), default=None)


def _series(present, data, key, keepup=False, keep_ratio=LAT_KEEPUP):
    """One chart's series list: [(proxy, colors, [(offered, y)...], dashed)]. With
    keepup, keep only windows within keep_ratio of offered (latency at healthy
    load); a looser keep_ratio yields a denser, higher-resolution curve."""
    out = []
    for p in present:
        pts = [(r["offered"], r[key]) for r in data[p]["rows"]
               if not keepup or (r["t"] >= 3 and r["offered"] > 0
                                 and r["achieved"] >= keep_ratio * r["offered"])]
        if pts:
            out.append((p, PALETTE.get(p, ("#898781", "#898781")), pts, p == "direct"))
    return out


def smooth_median(pts, w=7):
    """Rolling-median (odd window) over x-sorted points — damps per-window jitter
    and lone spikes (e.g. shed-ratio blowing up in a low-offered warmup window
    where the tiny denominator makes a small dip read as a huge fraction) while
    keeping the trend."""
    if len(pts) < w:
        return sorted(pts)
    s = sorted(pts)
    h = w // 2
    out = []
    for i in range(len(s)):
        ys = sorted(y for _, y in s[max(0, i - h):i + h + 1])
        out.append((s[i][0], ys[len(ys) // 2]))
    return out


def p99_curve(run_dir, proxy, tags, keep_ratio=P99_KEEPUP, win=9):
    """Dense, low-noise p99-vs-offered curve: one point per keep-up window (full
    x-resolution), but each p99 is read from the MERGED per-window HdrHistograms of
    a win-wide neighborhood — many windows' samples instead of one ~1s window's few
    tail samples — so the estimate is stable rather than sawtooth. Median-smoothing
    the raw per-window p99 couldn't fix that; merging the actual sample counts does.
    Rebuilt from the live blobs zrk streams (no .hgrm needed). Returns
    [(offered, p99_seconds)] in window order."""
    rows = full_windows(read_ndjson(os.path.join(run_dir, f"{proxy}.{tags[0]}.ndjson")))
    keep = [r for r in rows
            if r.get("t", 0) >= 3 and float(r.get("target_rate", 0)) > 0
            and float(r.get("achieved_rate", 0)) >= keep_ratio * float(r.get("target_rate", 0))
            and r.get("latency_histogram")]
    if not keep:
        return []
    hdrs = [hdr.decode(r["latency_histogram"]) for r in keep]
    # nonzero (bucket, count) per window: merging a neighborhood is then a few
    # hundred ops per window, not a walk of the full ~10k-bucket counts array.
    nz = [[(i, c) for i, c in enumerate(hd.counts) if c] for hd in hdrs]
    offs = [float(r["target_rate"]) for r in keep]
    geo, h, out = hdrs[0], win // 2, []
    for i in range(len(hdrs)):
        acc, tot = {}, 0
        for j in range(max(0, i - h), min(len(hdrs), i + h + 1)):
            for idx, c in nz[j]:
                acc[idx] = acc.get(idx, 0) + c
                tot += c
        wanted = max(1, int(0.99 * tot + 0.5))   # matches hdr.value_at_percentile rounding
        run = 0
        for idx in sorted(acc):
            run += acc[idx]
            if run >= wanted:
                out.append((offs[i], geo._median_equiv(geo._value_from_index(idx)) / 1e6))
                break
    return out


def gather(meta, run_dir, prom):
    """Compute every measured curve/summary once, generator-agnostic, so the HTML
    and the JSON render from the SAME numbers. Returns (present, data, series)."""
    runs = meta["runs"]
    present = [p for p in PROXY_ORDER if p in runs] + [p for p in runs if p not in PROXY_ORDER]
    data = {}
    for p in present:
        tags = runs[p].get("loadgens", ["lg1"])
        rows = load_merged(run_dir, p, tags)
        data[p] = {"rows": rows, "sustained": sustained(rows),
                   "hist": capped_hist(run_dir, p, tags),
                   "hgrm_file": hgrm_filename(run_dir, p, tags),
                   "mem": None if p == "direct" else peak_mem(prom, p, runs[p])}

    achieved = _series(present, data, "achieved")
    xmax = max((x for _, _, pts, _ in achieved for x, _ in pts), default=1)
    achieved.append(("offered", ("#c3c2b7", "#383835"), [(0, 0), (xmax, xmax)], True))

    cpu = []
    for p in present:
        if p == "direct":
            continue
        pts = cpu_vs_offered(prom, p, runs[p])
        if pts:
            # median over 7 points (7s at STEP=1): cadvisor's housekeeping thread
            # stalls under host load, gapping counter updates 2-4s, and rate()
            # dips spuriously at the gaps — 1-2 sample spikes the median erases
            # without the systematic lag a wider rate window would add.
            cpu.append((p, PALETTE.get(p, ("#898781", "#898781")), smooth_median(pts), False))

    p99 = []
    for p in present:
        pts = p99_curve(run_dir, p, runs[p].get("loadgens", ["lg1"]))
        if pts:
            p99.append((p, PALETTE.get(p, ("#898781", "#898781")), pts, p == "direct"))
    # shed only means something once offered is non-trivial: below ~2k req/s the
    # ratio is warmup jitter (a small dip on a tiny denominator reads as a big
    # fraction), so floor it, then smooth to expose the collapse trend.
    shed = []
    for p in present:
        pts = [(r["offered"], r["shed"]) for r in data[p]["rows"]
               if r["t"] >= 3 and r["offered"] >= 2000]
        if pts:
            shed.append((p, PALETTE.get(p, ("#898781", "#898781")),
                         smooth_median(pts, 15), p == "direct"))
    series = {"rps": achieved, "cpu": cpu, "p99": p99, "shed": shed}
    return present, data, series


def build(meta, present, data, series):
    # Crop every chart's offered axis to where the LAST real proxy stops keeping
    # up (the p99 curves are keep-up-filtered, so their rightmost offered is that
    # knee — zoxy's). Past it only the direct baseline has data, so the full ramp
    # wasted half the width on empty space; direct's tail is clipped at the edge.
    crop = max((x for n, _, pts, _ in series["p99"] if n != "direct" for x, _ in pts),
               default=None)
    cards = [
        chart_card("Successful req/s vs offered",
                   "open-loop ramp; dashed gray = perfect keep-up",
                   "rps", series["rps"], "si", "req/s", xmax=crop),
        chart_card("Proxy CPU vs offered", "container cores (cAdvisor), mapped onto the offered axis",
                   "cpu", series["cpu"], "si", "cores", xmax=crop),
        chart_card("p99 latency vs offered (while keeping up)",
                   "per-window tail (log scale); each line stops where that proxy stops keeping up",
                   "p99", series["p99"], "ms", "ms", ylog=True, xmax=crop),
        chart_card("Load shed vs offered", "offered load the proxy couldn't serve (1 − achieved/offered); HTTP errors/timeouts were ~0",
                   "shed", series["shed"], "pct", "", xmax=crop),
    ]

    # summary table — max sustained throughput + median/max latency (per-proxy,
    # healthy-load window; the full percentile curve is in the distribution below)
    rows_html = ""
    for p in sorted(present, key=lambda p: data[p]["sustained"], reverse=True):
        s = data[p]["sustained"]
        h = data[p]["hist"]
        has_h = bool(h) and h.total() > 0
        p50 = h.value_at_percentile(50) / 1000.0 if has_h else None
        mx = h.max() / 1000.0 if has_h else None
        mem = data[p]["mem"]
        cls = ' class="baseline"' if p == "direct" else ""
        # color swatch (the report's only legend) + proxy name; the name links
        # to its latency distribution below when there's a histogram to jump to.
        sw = f'<span class="swatch s-{p}"></span>'
        name = (f'<a class="proxycell" href="#hist-{p}">{sw}{html.escape(p)}</a>' if has_h
                else f'<span class="proxycell">{sw}{html.escape(p)}</span>')
        rows_html += (f"<tr{cls}><td>{name}</td><td>{fmt_si(s)}</td>"
                      f"<td>{_ms(p50)}</td>"
                      f"<td>{_ms(mx)}</td>"
                      f"<td>{fmt_bytes(mem) if mem else '—'}</td></tr>")

    # per-proxy latency-by-percentile distributions (from the .hgrm files),
    # anchored so the table's proxy names jump to them
    dist_cards = "".join(
        f'<section class="card" id="hist-{p}"><h2>{html.escape(p)}</h2>'
        f'<p class="sub">latency by percentile — while keeping up · '
        f'raw <a href="{html.escape(data[p]["hgrm_file"])}" download>{html.escape(data[p]["hgrm_file"])}</a> = whole run</p>'
        f'<div class="chartwrap">{hist_svg(p, hdr_points(data[p]["hist"]))}</div></section>'
        for p in present if data[p]["hist"] and data[p]["hist"].total() > 0
    )
    dist = (f'<h2 class="dist-h">Latency distribution · HdrHistogram (while keeping up)</h2>'
            f'<div class="grid2">{dist_cards}</div>') if dist_cards else ""

    rid = html.escape(meta.get("runid", ""))
    return f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0e1016">
<title>zoxy bench · {rid}</title><style>{CSS}</style></head>
<body>
<div class="eyebrow">L4 proxy benchmark · open-loop ramp</div>
<h1>relay throughput <span class="rid">{rid}</span></h1>
<p class="meta">Every proxy driven through the identical linear ramp (zrk, open-loop, coordinated-omission corrected).
Throughput &amp; CPU span the full ramp; latency (table, p99 pane, distributions) is computed per-proxy over the windows where that proxy is
keeping up (achieved &ge; 99% offered, near-zero backlog) — its latency at healthy load, since near/past its own ceiling the CO-corrected tail balloons.</p>
<div class="tablewrap"><table><tr><th>proxy</th><th>max sustained req/s</th>
<th>median</th><th>max</th><th>peak mem</th></tr>
{rows_html}</table></div>
<div class="grid2">{''.join(cards)}</div>
{dist}
<footer>generated by report/report.py — <a href="https://zoxy.io">zoxy.io</a></footer>
<script>{JS}</script></body></html>"""


def build_json(meta, present, data, series, generated):
    """The canonical MEASURED-data artifact — the exact numbers the HTML renders,
    as JSON, so downstream consumers (the site) never parse HTML. Editorial copy
    (version strings, prose, notes) is NOT here; it belongs to the consumer. All
    units are declared in `units`. Latency is milliseconds; the hist x-axis is
    n = 1/(1-percentile) so p0/p90/p99/p99.9… land on even decades."""
    runs = meta["runs"]
    # the ramp is identical across proxies — read it off any present run
    ramp_src = next((runs[p] for p in present if p in runs), {})

    def proxy_row(p):
        h = data[p]["hist"]
        has_h = bool(h) and h.total() > 0
        return {
            "name": p,
            "self": p == "zoxy",           # the subject of the benchmark
            "baseline": p == "direct",     # no-proxy origin calibration, not a competitor
            "sustained": round(data[p]["sustained"]),          # req/s
            "mem": data[p]["mem"],                             # peak working-set bytes | null
            "latency_ms": {
                "p50": round(h.value_at_percentile(50) / 1000.0, 4) if has_h else None,
                "max": round(h.max() / 1000.0, 4) if has_h else None,
            },
            "hgrm_file": data[p]["hgrm_file"] or None,         # raw whole-run histogram
        }

    def ser(lst, yfn):
        out = []
        for n, _, pts, dashed in lst:
            if not pts:
                continue
            row = {"name": n, "pts": [[round(x, 1), yfn(y)] for x, y in sorted(pts)]}
            if n == "offered":
                row["ref"] = True          # synthetic y=x perfect-keep-up diagonal
            if n == "direct":
                row["baseline"] = True
            out.append(row)
        return out

    return {
        "schema": 1,
        "runid": meta.get("runid", ""),
        "generated": generated,
        "units": {"rps": "req/s", "cpu": "cores", "p99_ms": "ms", "shed": "ratio",
                  "mem": "bytes", "latency_ms": "ms", "hist": "[1/(1-percentile), ms]"},
        "ramp": {"start_rate": ramp_src.get("start_rate"),
                 "max_rate": ramp_src.get("max_rate"),
                 "ramp_seconds": ramp_src.get("ramp_seconds")},
        "keepup": {"throughput": KEEPUP, "latency": LAT_KEEPUP},
        "palette": {p: PALETTE[p][0] for p in present if p in PALETTE},
        # ordered by max sustained throughput, same as the HTML summary table
        "proxies": [proxy_row(p) for p in
                    sorted(present, key=lambda p: data[p]["sustained"], reverse=True)],
        "series": {
            "rps": ser(series["rps"], lambda y: round(y, 1)),
            "cpu": ser(series["cpu"], lambda y: round(y, 6)),
            "p99_ms": ser(series["p99"], lambda y: round(y * 1000.0, 4)),
            "shed": ser(series["shed"], lambda y: round(y, 6)),
        },
        "hist": {
            p: {"pts": [[round(n, 4), round(v, 4)] for n, v in hdr_points(data[p]["hist"])]}
            for p in present if data[p]["hist"] and data[p]["hist"].total() > 0
        },
    }


def main():
    if len(sys.argv) < 2:
        print("usage: report.py <run-dir>", file=sys.stderr)
        sys.exit(2)
    run_dir = sys.argv[1]
    meta = json.load(open(os.path.join(run_dir, "meta.json")))
    prom = os.environ.get("PROM_URL", meta.get("prom", "http://localhost:9090"))

    present, data, series = gather(meta, run_dir, prom)
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    rj = build_json(meta, present, data, series, generated)
    json_dest = os.path.join(run_dir, "report.json")
    open(json_dest, "w").write(json.dumps(rj, separators=(",", ":")))
    print(f"wrote {os.path.abspath(json_dest)}")

    out = build(meta, present, data, series)
    dest = os.path.join(run_dir, "report.html")
    open(dest, "w").write(out)
    print(f"wrote {os.path.abspath(dest)}")


if __name__ == "__main__":
    main()
