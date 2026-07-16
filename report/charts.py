#!/usr/bin/env python3
"""Shared inline-SVG chart engine + Prometheus helpers for the report scripts.
Extracted so report.py (the zrk open-loop report) has the charting without
pulling in anything generator-specific. Stdlib only."""
import html
import json
import math
import urllib.parse
import urllib.request
from datetime import datetime, timezone

STEP = 5


# dark-ground hues (zoxy.io palette): zoxy is the amber signal, the rest are
# distinct, legible on ink. Both slots equal — the report is dark-only now.
PALETTE = {
    "zoxy": ("#fb9e0e", "#fb9e0e"),
    "haproxy": ("#38bdf8", "#38bdf8"),
    "envoy": ("#f2705b", "#f2705b"),
    "traefik": ("#a78bfa", "#a78bfa"),
    "nginx": ("#34d399", "#34d399"),
    "pingora": ("#f472b6", "#f472b6"),
    "direct": ("#6d7385", "#6d7385"),
}


PROXY_ORDER = ["zoxy", "haproxy", "envoy", "traefik", "nginx", "pingora", "direct"]


W, H = 720, 380


ML, MR, MT, MB = 62, 16, 22, 40


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


def nice_ticks(lo, hi, n=5):
    if hi <= lo:
        hi = lo + 1
    raw = (hi - lo) / n
    mag = 10 ** math.floor(math.log10(raw))
    step = min(s for s in (1 * mag, 2 * mag, 2.5 * mag, 5 * mag, 10 * mag) if s >= raw)
    start = math.floor(lo / step) * step
    ticks = []
    t = start
    # step up to the first tick at/above hi so the axis always COVERS the data
    # (x is not clamped; y is, but this keeps both exact and avoids overshoot).
    while t < hi - step * 1e-9:
        ticks.append(round(t, 10))
        t += step
    ticks.append(round(t, 10))
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


def svg_chart(chart_id, series_list, yfmt="si", y_unit="", sat_marks=None, ylog=False, xmax=None):
    """series_list: [(name, colors(light,dark), [(x,y)...], dashed)]. xmax crops the
    offered axis (e.g. to where the last real proxy stops keeping up); lines that
    run past it are clipped at the plot edge."""
    pts_all = [p for _, _, pts, _ in series_list for p in pts]
    if not pts_all:
        return "<p class='empty'>no data</p>"
    if xmax is None:
        xmax = max(x for x, _ in pts_all)
    xticks = nice_ticks(0, xmax)
    xmaxt = xticks[-1]

    def X(x):
        return ML + (W - ML - MR) * x / xmaxt

    # y-axis fits the VISIBLE window (points within the cropped x-range) so a
    # cropped-out tail can't inflate the scale.
    vis = [(x, y) for x, y in pts_all if x <= xmaxt] or pts_all
    if ylog:
        # latency spans decades (sub-ms when healthy -> ~half a second at the
        # saturation knee); a linear axis crushes every curve but the tallest into
        # the baseline. Map log10 onto whole-decade gridlines instead.
        pos = [y for _, y in vis if y > 0]
        lo_exp = math.floor(math.log10(min(pos))) if pos else -3
        hi_exp = math.ceil(math.log10(max(pos))) if pos else 0
        if hi_exp <= lo_exp:
            hi_exp = lo_exp + 1
        yticks = [10.0 ** e for e in range(lo_exp, hi_exp + 1)]
        ylo, ymaxt = 10.0 ** lo_exp, 10.0 ** hi_exp

        def Y(y):
            ly = math.log10(min(max(y, ylo), ymaxt))
            return H - MB - (H - MB - MT) * (ly - lo_exp) / (hi_exp - lo_exp)
    else:
        ymax = max(y for _, y in vis)
        yticks = nice_ticks(0, ymax * 1.05)
        ymaxt = yticks[-1]

        def Y(y):
            return H - MB - (H - MB - MT) * y / ymaxt

    # latency series are in SECONDS; "ms" scales the tick labels to milliseconds
    # (the tick POSITIONS stay in seconds, so nice round seconds like 0.01 map to
    # nice round ms like 10 — no tiny 0.0050-style labels).
    fmt = fmt_bytes if yfmt == "bytes" else (lambda v: f"{v * 100:g}%") if yfmt == "pct" \
        else (lambda v: fmt_si(v * 1000)) if yfmt == "ms" else fmt_si
    out = [f'<svg viewBox="0 0 {W} {H}" role="img">',
           f'<clipPath id="clip-{chart_id}"><rect x="{ML}" y="{MT}" '
           f'width="{W - ML - MR}" height="{H - MT - MB}"/></clipPath>']
    for t in yticks:
        out.append(f'<line class="grid" x1="{ML}" y1="{Y(t):.1f}" x2="{W - MR}" y2="{Y(t):.1f}"/>')
        out.append(f'<text class="tick" x="{ML - 8}" y="{Y(t) + 4:.1f}" text-anchor="end">{fmt(t)}</text>')
    for t in xticks:
        out.append(f'<text class="tick" x="{X(t):.1f}" y="{H - MB + 18}" text-anchor="middle">{fmt_si(t)}</text>')
    out.append(f'<line class="axis" x1="{ML}" y1="{H - MB}" x2="{W - MR}" y2="{H - MB}"/>')
    out.append(f'<text class="axis-label" x="{(ML + W - MR) / 2}" y="{H - 6}" text-anchor="middle">offered load (req/s)</text>')
    if y_unit:
        # sit the unit above the top gridline/tick (MT), not level with it
        out.append(f'<text class="axis-label" x="14" y="10" text-anchor="start">{y_unit}</text>')

    out.append(f'<g clip-path="url(#clip-{chart_id})">')
    for name, _, pts, dashed in series_list:
        if not pts:
            continue
        d = " ".join(f"{X(x):.1f},{Y(y):.1f}" for x, y in sorted(pts))
        dash = ' stroke-dasharray="6 4"' if dashed else ""
        out.append(f'<polyline class="line s-{name}" points="{d}" fill="none" stroke-width="2"{dash}/>')
    out.append('</g>')

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


def chart_card(title, subtitle, chart_id, series_list, yfmt="si", y_unit="", sat_marks=None, ylog=False, xmax=None):
    # per-pane legends are gone — the summary table's color swatches are the
    # single key, and each chart's hover tooltip names its own lines.
    # hover-layer data: resample every series onto a shared x grid
    data = {
        # "offered" is the synthetic y=x reference diagonal (2 points), not a
        # data series — exclude it from the hover tooltip (its value at any x is
        # just x, already shown in the header) so it doesn't snap 0/​max or dup.
        "series": [
            {"name": n, "pts": [[round(x, 1), y] for x, y in sorted(pts)]}
            for n, _, pts, _ in series_list if pts and n != "offered"
        ],
        "yfmt": yfmt,
        # match svg_chart's x tick ceiling so the crosshair maps onto the same
        # scale the SVG points are drawn on.
        "xmax": nice_ticks(0, xmax if xmax is not None
                           else max((x for _, _, pts, _ in series_list for x, _ in pts), default=1))[-1],
        "geom": [W, H, ML, MR, MT, MB],
    }
    return f"""
<section class="card">
  <h2>{html.escape(title)}</h2>
  <p class="sub">{html.escape(subtitle)}</p>
  <div class="chartwrap" id="wrap-{chart_id}">
    {svg_chart(chart_id, series_list, yfmt, y_unit, sat_marks, ylog, xmax)}
    <div class="tooltip" id="tip-{chart_id}" hidden></div>
  </div>
  <script type="application/json" id="data-{chart_id}">{json.dumps(data)}</script>
</section>"""


CSS = """
@import url('https://api.fontshare.com/v2/css?f[]=clash-display@600,500&f[]=satoshi@400,500,700&display=swap');
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&display=swap');
:root {
  /* zoxy.io design tokens */
  --ink:#0e1016; --ink-1:#13151c; --ink-2:#191d28;
  --line:rgba(233,239,250,.08); --line-2:rgba(233,239,250,.16);
  --paper:#f1f1f4; --haze:#9aa1b3; --haze-dim:#6d7385;
  --amber:#fb9e0e; --amber-hi:#ffc15c; --alarm:#f2705b;
  --font-display:'Clash Display',system-ui,sans-serif;
  --font-body:'Satoshi',system-ui,-apple-system,BlinkMacSystemFont,sans-serif;
  --font-mono:'JetBrains Mono',ui-monospace,'SF Mono',monospace;
  /* per-proxy line hues on the ink ground — zoxy is the amber signal */
  --c-zoxy:#fb9e0e; --c-haproxy:#38bdf8; --c-envoy:#f2705b;
  --c-traefik:#a78bfa; --c-nginx:#34d399; --c-pingora:#f472b6; --c-direct:#6d7385;
}
* { box-sizing:border-box; margin:0 }
html { -webkit-text-size-adjust:100% }
body { background:var(--ink); color:var(--paper);
  font-family:var(--font-body); font-size:15px; line-height:1.6; letter-spacing:-.005em;
  -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility;
  padding:clamp(1.15rem,4vw,2.75rem); max-width:1200px; margin-inline:auto; }
::selection { background:var(--amber); color:var(--ink) }
.eyebrow { display:inline-flex; align-items:center; gap:.65ch; font-family:var(--font-mono);
  font-size:.72rem; font-weight:500; letter-spacing:.22em; text-transform:uppercase;
  color:var(--amber); margin-bottom:.75rem }
.eyebrow::before { content:''; width:1.8rem; height:1px; background:linear-gradient(90deg,var(--amber),transparent) }
h1 { font-family:var(--font-display); font-weight:600; line-height:1.04; letter-spacing:-.02em;
  font-size:clamp(1.9rem,1.3rem+2.4vw,2.9rem) }
h1 .rid { color:var(--amber) }
.meta { color:var(--haze); margin:.6rem 0 2.2rem; font-family:var(--font-mono);
  font-size:.8rem; letter-spacing:.01em; line-height:1.5 }
.grid2 { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(440px,100%),1fr)); gap:18px }
.card { background:var(--ink-1); border:1px solid var(--line); border-radius:12px; padding:20px 22px }
@media (max-width:480px) { .card { padding:15px } }
.card h2 { font-family:var(--font-display); font-size:1.05rem; font-weight:600; letter-spacing:-.01em }
.card .sub { color:var(--haze-dim); font-size:.8rem; margin:.35rem 0 .95rem; line-height:1.45 }
.swatch { width:9px; height:9px; border-radius:2px; display:inline-block }
svg { width:100%; height:auto; display:block }
.grid { stroke:var(--line); stroke-width:1 }
.axis { stroke:var(--line-2); stroke-width:1 }
.tick { fill:var(--haze-dim); font-family:var(--font-mono); font-size:10.5px }
.axis-label { fill:var(--haze-dim); font-family:var(--font-mono); font-size:10px;
  letter-spacing:.08em; text-transform:uppercase }
.line { fill:none; stroke-width:2 }
.line.s-zoxy,.satmark.s-zoxy { stroke:var(--c-zoxy) } .swatch.s-zoxy { background:var(--c-zoxy) }
.line.s-zoxy { stroke-width:2.6; filter:drop-shadow(0 0 5px rgba(251,158,14,.45)) }
.line.s-haproxy,.satmark.s-haproxy { stroke:var(--c-haproxy) } .swatch.s-haproxy { background:var(--c-haproxy) }
.line.s-envoy,.satmark.s-envoy { stroke:var(--c-envoy) } .swatch.s-envoy { background:var(--c-envoy) }
.line.s-traefik,.satmark.s-traefik { stroke:var(--c-traefik) } .swatch.s-traefik { background:var(--c-traefik) }
.line.s-nginx,.satmark.s-nginx { stroke:var(--c-nginx) } .swatch.s-nginx { background:var(--c-nginx) }
.line.s-pingora,.satmark.s-pingora { stroke:var(--c-pingora) } .swatch.s-pingora { background:var(--c-pingora) }
.line.s-direct,.satmark.s-direct { stroke:var(--c-direct) } .swatch.s-direct { background:var(--c-direct) }
.line.s-direct { stroke-dasharray:5 5; opacity:.85 }
.line.s-offered { stroke:var(--line-2) }
.chartwrap { position:relative }
.tooltip { position:absolute; pointer-events:none; background:var(--ink-2);
  border:1px solid var(--line-2); border-radius:10px; padding:9px 11px; font-size:12px;
  font-family:var(--font-mono); box-shadow:0 8px 26px rgba(0,0,0,.5); min-width:158px; z-index:2 }
.tooltip .trow { display:flex; justify-content:space-between; gap:16px }
.tooltip .tname { display:flex; align-items:center; gap:7px; color:var(--haze) }
.tooltip .tval { color:var(--paper) }
.tablewrap { overflow-x:auto; border:1px solid var(--line); border-radius:12px; margin-bottom:22px }
table { border-collapse:collapse; width:100%; min-width:520px; font-family:var(--font-mono); font-size:13px }
th,td { text-align:right; padding:11px 16px; border-bottom:1px solid var(--line) }
tr:last-child td { border-bottom:none }
th:first-child,td:first-child { text-align:left }
/* table proxy cell: color swatch + name (the report's only legend now) */
.proxycell { display:flex; align-items:center; gap:8px }
.proxycell .swatch { flex:none }
th { color:var(--amber); font-weight:500; font-size:.68rem; letter-spacing:.14em; text-transform:uppercase }
tbody tr:hover td { background:rgba(233,239,250,.02) }
td:first-child { color:var(--paper); font-weight:500 }
/* direct = origin-calibration baseline, not a competitor — muted */
tr.baseline td, tr.baseline td:first-child { color:var(--haze-dim); font-weight:400 }
.flag { color:var(--alarm); font-size:12.5px }
.ok { color:var(--nginx,#34d399) }
.empty { color:var(--haze-dim) }
footer { color:var(--haze-dim); font-family:var(--font-mono); font-size:.72rem;
  letter-spacing:.02em; margin-top:26px; padding-top:16px; border-top:1px solid var(--line) }
footer a { color:var(--amber) }
/* summary-table proxy link -> its latency distribution below */
td a { color:inherit; text-decoration:underline; text-decoration-color:var(--haze-dim); text-underline-offset:2px }
td a:hover { color:var(--amber); text-decoration-color:var(--amber) }
/* latency-distribution section heading */
.dist-h { font-family:var(--font-display); font-weight:600; letter-spacing:-.01em; font-size:1.15rem; margin:30px 0 14px }
/* raw .hgrm link in a card subtitle */
.sub a { color:var(--haze); text-decoration:underline; text-decoration-color:var(--line-2); text-underline-offset:2px }
.sub a:hover { color:var(--amber); text-decoration-color:var(--amber) }
"""


JS = """
// crosshair + tooltip on every chart (hover layer, dataviz interaction spec)
function fmt(v, kind) {
  if (kind === 'bytes') { const u=[['GiB',2**30],['MiB',2**20],['KiB',1024]];
    for (const [n,d] of u) if (v>=d) return (v/d).toFixed(1)+n; return v.toFixed(0)+'B'; }
  if (kind === 'pct') return (v*100).toFixed(2)+'%';
  // latency series carry SECONDS; render the tooltip in ms (or s past 1000ms)
  if (kind === 'ms') { const m=v*1000; return m>=1000 ? (m/1000).toFixed(2)+'s'
    : m>=10 ? m.toFixed(0)+'ms' : m.toFixed(1)+'ms'; }
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


