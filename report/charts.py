#!/usr/bin/env python3
"""Shared inline-SVG chart engine + Prometheus helpers for the report scripts.
Extracted so report_vegeta.py (the vegeta open-loop report) has the charting
without pulling in any k6-specific logic. Stdlib only."""
import html
import json
import math
import urllib.parse
import urllib.request
from datetime import datetime, timezone

STEP = 5


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


W, H = 720, 380


ML, MR, MT, MB = 62, 16, 14, 40


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

    # latency series are in SECONDS; "ms" scales the tick labels to milliseconds
    # (the tick POSITIONS stay in seconds, so nice round seconds like 0.01 map to
    # nice round ms like 10 — no tiny 0.0050-style labels).
    fmt = fmt_bytes if yfmt == "bytes" else (lambda v: f"{v * 100:g}%") if yfmt == "pct" \
        else (lambda v: fmt_si(v * 1000)) if yfmt == "ms" else fmt_si
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


