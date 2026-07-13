#!/usr/bin/env python3
"""The shareable artifact: one self-contained HTML comparing every proxy's
latency / CPU / memory / achieved-RPS against the SAME offered-load x-axis.

Reads results/<runid>/runs.json (written by scripts/run-all.sh), queries the
Prometheus HTTP API for each proxy's run window, re-bases each run from
wall-clock time to offered rate (exact, because every proxy got the identical
linear ramp — the hard invariant), detects the saturation knee post-hoc, and
renders inline-SVG charts. Stdlib only.

Usage: report/report.py results/<runid>|results/latest [--prom http://localhost:9090]
"""
import argparse
import html
import json
import math
import os
import statistics
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

STEP = 5  # query_range resolution, seconds
WINDOW = "15s"  # rate() window
SAT_WINDOW = 15  # saturation-check bucket, seconds
ERR_MAX = 0.01  # error ratio above this => the knee reason is "errors", not a plateau
KNEE_FRAC = 0.97  # achieved within this fraction of its OWN peak => on the plateau (knee)
PLATEAU_MARGIN = 0.90  # peak sustained achieved below this fraction of max_rate => saturated

# k6 experimental-prometheus-rw naming (k6 auto-tags `scenario`; ours is "ramp")
M_REQS = "k6_http_reqs_total"
M_FAILED = "k6_http_req_failed_rate"
M_DROPPED = "k6_dropped_iterations_total"
M_CHECKS = "k6_checks_rate"  # fraction of `status is 200` checks passing (0..1)
M_DUR = "k6_http_req_duration_p{q}"  # via K6_PROMETHEUS_RW_TREND_STATS; SECONDS

# dataviz reference palette, fixed slot per entity (never re-assigned by rank).
# "direct" is the backend-calibration baseline, not a competitor => muted.
PALETTE = {
    "zoxy": ("#2a78d6", "#3987e5"),
    "haproxy": ("#1baf7a", "#199e70"),
    "envoy": ("#eda100", "#c98500"),
    "traefik": ("#008300", "#008300"),
    "nginx": ("#4a3aa7", "#9085e9"),
    "pingora": ("#d9481f", "#e2662c"),  # Cloudflare-ish orange, clear of envoy amber
    "direct": ("#898781", "#898781"),
}
PROXY_ORDER = ["zoxy", "haproxy", "envoy", "traefik", "nginx", "pingora", "direct"]


def prom_query_range(prom, query, start, end):
    """GET /api/v1/query_range -> list of (ts, float) for the FIRST series."""
    q = urllib.parse.urlencode(
        {"query": query, "start": start, "end": end, "step": STEP}
    )
    with urllib.request.urlopen(f"{prom}/api/v1/query_range?{q}", timeout=30) as r:
        body = json.load(r)
    if body.get("status") != "success":
        raise RuntimeError(f"prometheus error for {query}: {body}")
    result = body["data"]["result"]
    if not result:
        return []
    values = result[0]["values"]
    return [(float(ts), float(v)) for ts, v in values if v != "NaN"]


def iso_to_epoch(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def duration_to_seconds(d):
    units = {"s": 1, "m": 60, "h": 3600}
    total, num = 0, ""
    for ch in d:
        if ch.isdigit():
            num += ch
        else:
            total += int(num) * units[ch]
            num = ""
    return total or int(d)


def sel(runid, proxy, extra=""):
    return f'testid="{runid}", proxy="{proxy}", scenario="ramp"{extra}'


def fetch_run(prom, runid, proxy, start, end, meta):
    """All series for one proxy's window, re-based to offered rate."""
    s = sel(runid, proxy)
    # Offered axis from RAW request rate (total, incl. failures): even a proxy
    # rejecting most connections has k6 churning attempts at ~the offered rate,
    # so raw tracks offered and anchors t0 correctly. Displayed throughput is
    # SUCCESSFUL rps (raw x 2xx-check fraction) so a fast-rejecting proxy isn't
    # credited with work it never served; "shed" (raw x non-2xx) is the rejected
    # load. Clean proxies: raw == successful, shed == 0.
    raw = prom_query_range(prom, f"sum(rate({M_REQS}{{{s}}}[{WINDOW}]))", start, end)
    if not raw or all(v == 0 for _, v in raw):
        return None

    # Ramp origin from the data itself. Two systematic offsets make naive
    # "first nonzero sample" wrong: k6 init time AND the ~WINDOW/2 lag baked
    # into rate() (each point averages the previous WINDOW). At steep slopes
    # (100k over 8m ≈ 208 rps/s) those add up to >2% of offered at low rates
    # and fake a knee. Fitting t0 against the KNOWN slope on raw (which tracks
    # offered) absorbs both: raw(ts) = slope * (ts - t0), so t0 = ts - raw/slope.
    ramp_s = duration_to_seconds(meta["ramp_duration"])
    max_rate = meta["max_rate"]
    slope = max_rate / ramp_s
    # Fit on the RISING EDGE only. A proxy that plateaus at a rate inside the
    # [5%,30%] band (e.g. envoy tops out ~22k of a 100k ramp) would otherwise
    # flood the fit with plateau samples whose (ts - v/slope) drifts ever later,
    # dragging the median t0 into the plateau and collapsing the offered axis to
    # a flat line. Excluding v > 0.9*peak keeps the clean segment raw≈offered.
    peak = max((v for _, v in raw), default=0)
    # Fit only the RISING EDGE — samples up to the first time achieved reaches
    # its peak. After that it's a plateau (envoy) or a collapse/oscillation
    # (traefik under overload drops 14k->~300; zoxy congestion-collapses),
    # whose samples fall back into the fit band at LATE timestamps and drag the
    # median t0 off, shifting/compressing the whole offered axis.
    t_peak = next((ts for ts, v in raw if v >= 0.95 * peak), None)
    fit = [ts - v / slope for ts, v in raw
           if (t_peak is None or ts <= t_peak)
           and 0.05 * max_rate <= v <= 0.30 * max_rate]
    if fit:
        t0 = statistics.median(fit)
    else:  # saturated almost immediately — fall back to the first sample
        t0 = next(ts for ts, v in raw if v > 0) - STEP

    def offered(ts):
        return max_rate * (ts - t0) / ramp_s

    def series(q):
        return [(offered(ts), v) for ts, v in prom_query_range(prom, q, start, end) if ts >= t0]

    # Success/failure come from the request COUNTER, split by k6's
    # expected_response tag ("true" = got the expected 2xx/3xx; "false" = a
    # transport error or bad status). Do NOT use k6_http_req_failed_rate: k6
    # remote-writes it as one series PER error type (EOF, reset, timeout, ...),
    # each trivially =1.0, so max()/avg() of it reads ~100% the instant a single
    # request fails — not weighted by volume/offered load. Count-based is exact.
    tot = f"sum(rate({M_REQS}{{{s}}}[{WINDOW}]))"
    ok = f"sum(rate({M_REQS}{{{s}, expected_response=\"true\"}}[{WINDOW}]))"
    data = {
        # successful (2xx) throughput — what the proxy actually served
        "achieved": series(ok),
        # shed/failed req/s: transport errors or non-2xx — load thrown away
        "shed": series(f"({tot}) - ({ok})"),
        # volume-weighted failure fraction: failed requests / all requests
        "errors": series(f"1 - ({ok}) / ({tot})"),
        "dropped": series(f"sum(rate({M_DROPPED}{{{s}}}[{WINDOW}]))"),
        "p50": series(f"max({M_DUR.format(q=50)}{{{s}}})"),
        "p95": series(f"max({M_DUR.format(q=95)}{{{s}}})"),
        "p99": series(f"max({M_DUR.format(q=99)}{{{s}}})"),
    }
    if proxy != "direct":
        cname = f'name="{proxy}"'
        data["cpu"] = series(f"sum(rate(container_cpu_usage_seconds_total{{{cname}}}[{WINDOW}]))")
        data["mem"] = series(f"max(container_memory_working_set_bytes{{{cname}}})")
    else:
        data["cpu"], data["mem"] = [], []

    data["saturation"] = detect_saturation(data, max_rate)
    data["hostcpu_flags"] = validity_flags(prom, start, end)
    return data


def detect_saturation(data, max_rate):
    """max sustained = the proxy's PEAK 15s-sustained achieved throughput (its
    real ceiling); knee = the offered rate where achieved first reaches that
    peak and plateaus. A proxy is "saturated" only if the plateau sits
    materially (>PLATEAU_MARGIN) below the offered ceiling — i.e. it could NOT
    follow the ramp to the top; one that tracks the ramp to ~max_rate has no
    knee.

    Why plateau, not the old "achieved<98% of offered / dropped>0" triggers:
    k6's open-loop arrival-rate executor drops a few percent of arrivals at
    cloud RTT (~10ms) from LOW load onward — a loadgen artifact, not proxy
    saturation. That baseline (measured 7-9% early in cloud runs) tripped both
    old triggers and pinned the reported knee far below the true ceiling. The
    achieved-plateau is immune to it: it reads where the proxy's own served
    throughput stops rising, wherever the loadgen's drop baseline sits.
    Errors>ERR_MAX still override the reason (a proxy failing, not just
    topping out)."""
    slice_w = max_rate * SAT_WINDOW / _ramp_len(data)
    grouped = {}
    for key in ("achieved", "errors"):
        for x, v in data[key]:
            grouped.setdefault(int(x // slice_w), {}).setdefault(key, []).append(v)

    buckets = []
    for i in sorted(grouped):
        b = grouped[i]
        offered_mid = (i + 0.5) * slice_w
        ach = sum(b.get("achieved", [0])) / max(len(b.get("achieved", [1])), 1)
        err = max(b.get("errors", [0]))
        buckets.append((offered_mid, ach, err))

    if not buckets:
        return {"saturated": False, "offered": None, "reason": None, "max_sustained": 0}

    peak_ach = max(ach for _, ach, _ in buckets)
    # knee = first offered slice where achieved reaches the top of its own curve
    # (the plateau's leading edge). achieved climbs with offered until the proxy
    # tops out, so this is where it stops keeping pace.
    knee_off = next((off for off, ach, _ in buckets if ach >= KNEE_FRAC * peak_ach), None)
    # Saturated only if that ceiling is well under the offered ramp's top — else
    # it kept up (its peak IS ~the offered ceiling) and there's no knee.
    saturated = peak_ach < PLATEAU_MARGIN * max_rate
    reason = None
    if saturated:
        post = [err for off, _, err in buckets if knee_off is None or off >= knee_off]
        reason = f"errors>{ERR_MAX:.0%}" if post and max(post) > ERR_MAX else "throughput plateau"
    return {"saturated": saturated, "offered": knee_off if saturated else None,
            "reason": reason, "max_sustained": peak_ach}


def _ramp_len(data):
    xs = [x for x, _ in data["achieved"]]
    return max(xs) - min(xs) if len(xs) > 1 else 1


def validity_flags(prom, start, end):
    """Roles whose HOST cpu had <10% headroom during the window (contaminated)."""
    q = '100 * (1 - avg by (role) (rate(node_cpu_seconds_total{mode="idle"}[30s])))'
    flags = []
    qs = urllib.parse.urlencode({"query": q, "start": start, "end": end, "step": STEP})
    try:
        with urllib.request.urlopen(f"{prom}/api/v1/query_range?{qs}", timeout=30) as r:
            body = json.load(r)
        for series in body["data"]["result"]:
            role = series["metric"].get("role", "?")
            peak = max(float(v) for _, v in series["values"])
            if role in ("loadgen", "backend", "all") and peak > 90:
                flags.append(f"{role} host CPU peaked at {peak:.0f}%")
    except Exception:
        flags.append("host CPU check unavailable")
    return flags


# ---------------------------------------------------------------- rendering --
def nice_ticks(lo, hi, n=5):
    if hi <= lo:
        hi = lo + 1
    raw = (hi - lo) / n
    mag = 10 ** math.floor(math.log10(raw))
    step = min(s for s in (1 * mag, 2 * mag, 2.5 * mag, 5 * mag, 10 * mag) if s >= raw)
    start = math.floor(lo / step) * step
    ticks = []
    t = start
    while t <= hi + step * 0.001:
        ticks.append(round(t, 10))
        t += step
    return ticks


def fmt_si(v):
    if v >= 1e9:
        return f"{v / 1e9:g}G"
    if v >= 1e6:
        return f"{v / 1e6:g}M"
    if v >= 1e3:
        return f"{v / 1e3:g}k"
    if v >= 10 or v == int(v):
        return f"{v:.0f}"
    return f"{v:.2g}"


def fmt_bytes(v):
    for unit, div in (("GiB", 2**30), ("MiB", 2**20), ("KiB", 2**10)):
        if v >= div:
            return f"{v / div:.1f}{unit}"
    return f"{v:.0f}B"


W, H = 720, 380
ML, MR, MT, MB = 62, 16, 14, 40


def svg_chart(chart_id, series_list, yfmt="si", y_unit="", sat_marks=None):
    """series_list: [(name, colors(light,dark), [(x,y)...], dashed)]"""
    pts_all = [p for _, _, pts, _ in series_list for p in pts]
    if not pts_all:
        return "<p class='empty'>no data</p>"
    xmax = max(x for x, _ in pts_all)
    ymax = max(y for _, y in pts_all)
    xticks = nice_ticks(0, xmax)
    yticks = nice_ticks(0, ymax * 1.05)
    xmaxt, ymaxt = xticks[-1], yticks[-1]

    def X(x):
        return ML + (W - ML - MR) * x / xmaxt

    def Y(y):
        return H - MB - (H - MB - MT) * y / ymaxt

    fmt = fmt_bytes if yfmt == "bytes" else (lambda v: f"{v * 100:g}%") if yfmt == "pct" else fmt_si
    out = [f'<svg viewBox="0 0 {W} {H}" role="img">']
    for t in yticks:
        out.append(f'<line class="grid" x1="{ML}" y1="{Y(t):.1f}" x2="{W - MR}" y2="{Y(t):.1f}"/>')
        out.append(f'<text class="tick" x="{ML - 8}" y="{Y(t) + 4:.1f}" text-anchor="end">{fmt(t)}</text>')
    for t in xticks:
        out.append(f'<text class="tick" x="{X(t):.1f}" y="{H - MB + 18}" text-anchor="middle">{fmt_si(t)}</text>')
    out.append(f'<line class="axis" x1="{ML}" y1="{H - MB}" x2="{W - MR}" y2="{H - MB}"/>')
    out.append(f'<text class="axis-label" x="{(ML + W - MR) / 2}" y="{H - 6}" text-anchor="middle">offered load (req/s)</text>')
    if y_unit:
        out.append(f'<text class="axis-label" x="14" y="{MT + 2}" text-anchor="start">{y_unit}</text>')

    for name, _, pts, dashed in series_list:
        if not pts:
            continue
        d = " ".join(f"{X(x):.1f},{Y(min(y, ymaxt)):.1f}" for x, y in sorted(pts))
        dash = ' stroke-dasharray="6 4"' if dashed else ""
        out.append(f'<polyline class="line s-{name}" points="{d}" fill="none" stroke-width="2"{dash}/>')

    # saturation knee markers (status "serious" is reserved for state, ok here)
    for name, x in (sat_marks or []):
        if x is not None and x <= xmaxt:
            out.append(
                f'<line class="satmark s-{name}" x1="{X(x):.1f}" y1="{MT}" x2="{X(x):.1f}" y2="{H - MB}" '
                f'stroke-width="1" stroke-dasharray="2 3" opacity="0.6"/>'
            )
    out.append(f'<rect class="hover-capture" data-chart="{chart_id}" x="{ML}" y="{MT}" '
               f'width="{W - ML - MR}" height="{H - MT - MB}" fill="transparent"/>')
    out.append('</svg>')
    return "".join(out)


def chart_card(title, subtitle, chart_id, series_list, present, yfmt="si", y_unit="", sat_marks=None):
    legend = "".join(
        f'<span class="chip"><span class="swatch s-{p}"></span>{p}</span>'
        for p in present
    )
    # hover-layer data: resample every series onto a shared x grid
    data = {
        "series": [
            {"name": n, "pts": [[round(x, 1), y] for x, y in sorted(pts)]}
            for n, _, pts, _ in series_list if pts
        ],
        "yfmt": yfmt,
        "xmax": max((x for _, _, pts, _ in series_list for x, _ in pts), default=1),
        "geom": [W, H, ML, MR, MT, MB],
    }
    return f"""
<section class="card">
  <h2>{html.escape(title)}</h2>
  <p class="sub">{html.escape(subtitle)}</p>
  <div class="legend">{legend}</div>
  <div class="chartwrap" id="wrap-{chart_id}">
    {svg_chart(chart_id, series_list, yfmt, y_unit, sat_marks)}
    <div class="tooltip" id="tip-{chart_id}" hidden></div>
  </div>
  <script type="application/json" id="data-{chart_id}">{json.dumps(data)}</script>
</section>"""


CSS = """
:root {
  --surface-1:#fcfcfb; --page:#f9f9f7; --ink:#0b0b0b; --ink-2:#52514e;
  --muted:#898781; --grid:#e1e0d9; --axis:#c3c2b7; --ring:rgba(11,11,11,.10);
  --c-zoxy:#2a78d6; --c-haproxy:#1baf7a; --c-envoy:#eda100;
  --c-traefik:#008300; --c-nginx:#4a3aa7; --c-pingora:#d9481f; --c-direct:#898781;
}
@media (prefers-color-scheme: dark) { :root {
  --surface-1:#1a1a19; --page:#0d0d0d; --ink:#ffffff; --ink-2:#c3c2b7;
  --muted:#898781; --grid:#2c2c2a; --axis:#383835; --ring:rgba(255,255,255,.10);
  --c-zoxy:#3987e5; --c-haproxy:#199e70; --c-envoy:#c98500;
  --c-traefik:#008300; --c-nginx:#9085e9; --c-pingora:#e2662c; --c-direct:#898781;
} }
/* explicit theme toggles (e.g. hosted viewers) must beat the media query */
:root[data-theme="dark"] {
  --surface-1:#1a1a19; --page:#0d0d0d; --ink:#ffffff; --ink-2:#c3c2b7;
  --muted:#898781; --grid:#2c2c2a; --axis:#383835; --ring:rgba(255,255,255,.10);
  --c-zoxy:#3987e5; --c-haproxy:#199e70; --c-envoy:#c98500;
  --c-traefik:#008300; --c-nginx:#9085e9; --c-pingora:#e2662c; --c-direct:#898781;
}
:root[data-theme="light"] {
  --surface-1:#fcfcfb; --page:#f9f9f7; --ink:#0b0b0b; --ink-2:#52514e;
  --muted:#898781; --grid:#e1e0d9; --axis:#c3c2b7; --ring:rgba(11,11,11,.10);
  --c-zoxy:#2a78d6; --c-haproxy:#1baf7a; --c-envoy:#eda100;
  --c-traefik:#008300; --c-nginx:#4a3aa7; --c-pingora:#d9481f; --c-direct:#898781;
}
* { box-sizing:border-box; margin:0 }
body { background:var(--page); color:var(--ink);
  font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif; padding:28px; }
@media (max-width: 480px) { body { padding:12px } .card { padding:12px } }
h1 { font-size:22px; margin-bottom:4px }
.meta { color:var(--ink-2); margin-bottom:24px; font-size:13px }
/* min(420px, 100%) — a hard 420px minimum would overflow phone viewports */
.grid2 { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(420px,100%),1fr)); gap:20px }
.card { background:var(--surface-1); border:1px solid var(--ring); border-radius:10px; padding:18px }
.card h2 { font-size:15px; font-weight:600 }
.card .sub { color:var(--muted); font-size:12.5px; margin-bottom:8px }
.legend { display:flex; flex-wrap:wrap; gap:10px; margin-bottom:6px }
.chip { display:inline-flex; align-items:center; gap:6px; font-size:12.5px; color:var(--ink-2) }
.swatch { width:10px; height:10px; border-radius:3px; display:inline-block }
svg { width:100%; height:auto; display:block }
.grid { stroke:var(--grid); stroke-width:1 }
.axis { stroke:var(--axis); stroke-width:1 }
.tick { fill:var(--muted); font-size:11px; font-variant-numeric:tabular-nums }
.axis-label { fill:var(--muted); font-size:11px }
.line.s-zoxy,.satmark.s-zoxy { stroke:var(--c-zoxy) } .swatch.s-zoxy { background:var(--c-zoxy) }
.line.s-haproxy,.satmark.s-haproxy { stroke:var(--c-haproxy) } .swatch.s-haproxy { background:var(--c-haproxy) }
.line.s-envoy,.satmark.s-envoy { stroke:var(--c-envoy) } .swatch.s-envoy { background:var(--c-envoy) }
.line.s-traefik,.satmark.s-traefik { stroke:var(--c-traefik) } .swatch.s-traefik { background:var(--c-traefik) }
.line.s-nginx,.satmark.s-nginx { stroke:var(--c-nginx) } .swatch.s-nginx { background:var(--c-nginx) }
.line.s-pingora,.satmark.s-pingora { stroke:var(--c-pingora) } .swatch.s-pingora { background:var(--c-pingora) }
.line.s-direct,.satmark.s-direct { stroke:var(--c-direct) } .swatch.s-direct { background:var(--c-direct) }
.line.s-offered { stroke:var(--axis) }
.chartwrap { position:relative }
.tooltip { position:absolute; pointer-events:none; background:var(--surface-1);
  border:1px solid var(--ring); border-radius:8px; padding:8px 10px; font-size:12px;
  box-shadow:0 4px 14px rgba(0,0,0,.18); min-width:150px; z-index:2 }
.tooltip .trow { display:flex; justify-content:space-between; gap:14px }
.tooltip .tname { display:flex; align-items:center; gap:6px; color:var(--ink-2) }
.tooltip .tval { font-variant-numeric:tabular-nums }
/* the 8-column summary scrolls inside its card; the page never scrolls sideways */
.tablewrap { overflow-x:auto }
table { border-collapse:collapse; width:100%; min-width:640px; font-size:13.5px }
th,td { text-align:right; padding:7px 12px; border-bottom:1px solid var(--grid);
  font-variant-numeric:tabular-nums }
th:first-child,td:first-child { text-align:left }
th { color:var(--ink-2); font-weight:600 }
.flag { color:#d03b3b; font-size:12.5px }
.ok { color:#0ca30c }
.empty { color:var(--muted) }
footer { color:var(--muted); font-size:12px; margin-top:22px }
"""

JS = """
// crosshair + tooltip on every chart (hover layer, dataviz interaction spec)
function fmt(v, kind) {
  if (kind === 'bytes') { const u=[['GiB',2**30],['MiB',2**20],['KiB',1024]];
    for (const [n,d] of u) if (v>=d) return (v/d).toFixed(1)+n; return v.toFixed(0)+'B'; }
  if (kind === 'pct') return (v*100).toFixed(2)+'%';
  if (v>=1e6) return (v/1e6).toFixed(2)+'M';
  if (v>=1e3) return (v/1e3).toFixed(1)+'k';
  return v>=10 ? v.toFixed(0) : v.toFixed(2);
}
document.querySelectorAll('.hover-capture').forEach(cap => {
  const id = cap.dataset.chart;
  const data = JSON.parse(document.getElementById('data-'+id).textContent);
  const wrap = document.getElementById('wrap-'+id);
  const tip = document.getElementById('tip-'+id);
  const svg = cap.ownerSVGElement;
  const [W,H,ML,MR,MT,MB] = data.geom;
  const cross = document.createElementNS('http://www.w3.org/2000/svg','line');
  cross.setAttribute('class','axis'); cross.setAttribute('y1',MT); cross.setAttribute('y2',H-MB);
  cross.setAttribute('hidden',''); svg.insertBefore(cross, cap);
  cap.addEventListener('mousemove', e => {
    const r = svg.getBoundingClientRect();
    const px = (e.clientX - r.left) * (W / r.width);
    const x = (px - ML) / (W - ML - MR) * data.xmax;
    cross.removeAttribute('hidden');
    cross.setAttribute('x1', px); cross.setAttribute('x2', px);
    let rows = '';
    for (const s of data.series) {
      let best = null, bd = Infinity;
      for (const [sx, sy] of s.pts) { const d = Math.abs(sx-x); if (d<bd) { bd=d; best=sy; } }
      if (best === null) continue;
      rows += `<div class="trow"><span class="tname"><span class="swatch s-${s.name}"></span>${s.name}</span>` +
              `<span class="tval">${fmt(best, data.yfmt)}</span></div>`;
    }
    tip.innerHTML = `<div class="trow"><span class="tname">offered</span><span class="tval">${fmt(x)} req/s</span></div>` + rows;
    tip.hidden = false;
    const wr = wrap.getBoundingClientRect();
    let lx = e.clientX - wr.left + 14;
    if (lx + tip.offsetWidth > wr.width - 8) lx = e.clientX - wr.left - tip.offsetWidth - 14;
    tip.style.left = lx + 'px';
    tip.style.top = Math.min(e.clientY - wr.top + 12, wr.height - tip.offsetHeight - 8) + 'px';
  });
  cap.addEventListener('mouseleave', () => { tip.hidden = true; cross.setAttribute('hidden',''); });
});
"""


def value_at(pts, x_target):
    best, bd = None, math.inf
    for x, v in pts:
        d = abs(x - x_target)
        if d < bd:
            bd, best = d, v
    return best


def build_html(meta, runs):
    present = [p for p in PROXY_ORDER if p in runs] + [p for p in runs if p not in PROXY_ORDER]

    def serieses(key, include_direct=True):
        return [
            (p, PALETTE.get(p, ("#898781", "#898781")), runs[p][key], p == "direct")
            for p in present
            if runs[p][key] and (include_direct or p != "direct")
        ]

    sat_marks = [(p, runs[p]["saturation"]["offered"]) for p in present
                 if runs[p]["saturation"]["saturated"]]

    achieved = serieses("achieved")
    # y=x reference: what a perfect proxy would achieve
    xmax = max(x for _, _, pts, _ in achieved for x, _ in pts)
    achieved.append(("offered", ("#c3c2b7", "#383835"), [(0, 0), (xmax, xmax)], True))

    shed = serieses("shed")
    if shed:
        shed.append(("offered", ("#c3c2b7", "#383835"), [(0, 0), (xmax, xmax)], True))

    cards = [
        chart_card("Successful req/s vs offered", "2xx only (failures/rejections excluded); knee = saturation; dashed gray = perfect keep-up",
                   "rps", achieved, present, "si", "req/s", sat_marks),
        chart_card("Shed (rejected) req/s vs offered", "non-2xx / reset responses — load the proxy rejects under overload (flat ~0 = sheds via client backpressure instead; climbing toward the dashed line = rejecting nearly everything)",
                   "shed", shed, present, "si", "req/s", sat_marks),
        chart_card("p50 latency", "median request duration through the proxy",
                   "p50", serieses("p50"), present, "si", "s", sat_marks),
        chart_card("p99 latency", "tail — where saturation shows first",
                   "p99", serieses("p99"), present, "si", "s", sat_marks),
        chart_card("Proxy CPU", "container cores consumed (cAdvisor working counter)",
                   "cpu", serieses("cpu", False), [p for p in present if p != "direct"],
                   "si", "cores", sat_marks),
        chart_card("Proxy memory", "container working set",
                   "mem", serieses("mem", False), [p for p in present if p != "direct"],
                   "bytes", "", sat_marks),
        chart_card("Error ratio", "non-2xx + transport errors (saturation trigger at 1%)",
                   "err", serieses("errors"), present, "pct", "", sat_marks),
    ]

    rows = []
    for p in present:
        r, sat = runs[p], runs[p]["saturation"]
        peak = sat["max_sustained"]
        p99_50 = value_at(r["p99"], peak * 0.5) if peak else None
        p99_80 = value_at(r["p99"], peak * 0.8) if peak else None
        mem_peak = value_at(r["mem"], peak) if (peak and r["mem"]) else None
        cpus = float(meta.get("proxy_cpus", 0) or 0)
        rows.append(f"""<tr>
  <td><span class="swatch s-{p}"></span> {p}</td>
  <td>{fmt_si(peak)}</td>
  <td>{html.escape(sat["reason"] or "not saturated (raise MAX_RATE)")}</td>
  <td>{f"{p99_50 * 1000:.1f}" if p99_50 is not None else "—"}</td>
  <td>{f"{p99_80 * 1000:.1f}" if p99_80 is not None else "—"}</td>
  <td>{fmt_si(peak / cpus) if cpus and peak else "—"}</td>
  <td>{fmt_bytes(mem_peak) if mem_peak is not None else "—"}</td>
  <td>{'<span class="flag">' + "; ".join(r["hostcpu_flags"]) + "</span>" if r["hostcpu_flags"] else '<span class="ok">clean</span>'}</td>
</tr>""")

    mode_note = ("local run: all roles share one docker host — treat as smoke test, "
                 "not quotable numbers" if meta.get("mode") == "local" else
                 "cloud run: disjoint hosts, host networking")

    return f"""<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>proxy bench {html.escape(meta["runid"])}</title>
<style>{CSS}</style>
<h1>Proxy benchmark — linear ramp to {fmt_si(meta["max_rate"])} req/s</h1>
<p class="meta">run {html.escape(meta["runid"])} · {html.escape(meta["mode"])} mode ·
ramp 0→{fmt_si(meta["max_rate"])} req/s over {html.escape(meta["ramp_duration"])} ·
body {html.escape(meta["req_path"])} · proxy box: {html.escape(str(meta["proxy_cpus"]))} cpus /
{html.escape(meta["proxy_mem"])} · {html.escape(mode_note)}</p>
<section class="card" style="margin-bottom:20px">
  <h2>Summary — peak sustained successful req/s (throughput ceiling)</h2>
  <p class="sub">max sustained = peak 15s-averaged 2xx throughput; knee = where achieved plateaus below the offered ramp (loadgen dropped-iteration baseline ignored); errors&gt;{ERR_MAX:.0%} flagged as the reason when present</p>
  <div class="tablewrap">
  <table>
    <tr><th>proxy</th><th>max sustained</th><th>saturated by</th><th>p99@50% (ms)</th>
        <th>p99@80% (ms)</th><th>req/s per core</th><th>mem @ peak</th><th>validity</th></tr>
    {"".join(rows)}
  </table>
  </div>
</section>
<div class="grid2">{"".join(cards)}</div>
<footer>Vertical dashed lines mark each proxy's saturation point. All proxies ran the identical
ramp sequentially; the shared offered-rate axis is exact because offered(t) is the same affine
function of elapsed ramp time for every run. Generated by report/report.py.</footer>
<script>{JS}</script>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir")
    ap.add_argument("--prom", default=os.environ.get("PROM_URL", "http://localhost:9090"))
    args = ap.parse_args()

    rdir = os.path.realpath(args.results_dir)
    with open(os.path.join(rdir, "runs.json")) as f:
        meta = json.load(f)

    runs = {}
    for proxy, w in meta["runs"].items():
        start, end = iso_to_epoch(w["start"]), iso_to_epoch(w["end"])
        data = fetch_run(args.prom, meta["runid"], proxy, start, end, meta)
        if data is None:
            print(f"warning: no data in prometheus for {proxy}, skipping", file=sys.stderr)
            continue
        runs[proxy] = data
        sat = data["saturation"]
        knee = f"knee at ~{fmt_si(sat['offered'])} req/s ({sat['reason']})" if sat["saturated"] else "no knee found"
        print(f"{proxy:10s} max sustained {fmt_si(sat['max_sustained']):>8s} req/s   {knee}")

    if not runs:
        sys.exit("no runs had data — is Prometheus reachable and did k6 remote-write succeed?")

    out = os.path.join(rdir, "report.html")
    with open(out, "w") as f:
        f.write(build_html(meta, runs))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
