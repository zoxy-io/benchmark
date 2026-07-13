#!/usr/bin/env python3
"""Closed-loop concurrency-sweep report: throughput / latency / CPU as a
FUNCTION of concurrency (N connections), one line per proxy — plus an N
selector that snapshots every proxy at the chosen concurrency.

Reads results/<runid>/runs.json written by scripts/sweep.sh (sweep[proxy][N] =
{start,end}), queries Prometheus for each point's steady state (the last 15s of
its window), and renders a self-contained HTML. Stdlib only; reuses the pure
render helpers from report.py.

Usage: report/sweep.py results/<runid>|results/latest [--prom URL]
"""
import argparse
import html
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report import PALETTE, PROXY_ORDER, CSS, nice_ticks, fmt_si, fmt_bytes  # noqa: E402

STEADY = "15s"  # measure the last 15s of each point's window (skip ramp-up)


def iso_to_epoch(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def prom_instant(prom, query, at):
    q = urllib.parse.urlencode({"query": query, "time": at})
    with urllib.request.urlopen(f"{prom}/api/v1/query?{q}", timeout=30) as r:
        body = json.load(r)
    res = body.get("data", {}).get("result", [])
    return float(res[0]["value"][1]) if res else None


def point_metrics(prom, runid, proxy, n, w):
    """Steady-state metrics for one (proxy, N) point, evaluated at window end."""
    at = int(iso_to_epoch(w["end"]))
    s = f'testid="{runid}", proxy="{proxy}", n="{n}", scenario="saturate"'
    reqs = "k6_http_reqs_total"

    def avg(expr):  # mean over the last STEADY of the point
        return prom_instant(prom, f"avg_over_time(({expr})[{STEADY}:5s])", at)

    tot = f'sum(rate({reqs}{{{s}}}[10s]))'
    ok = f'sum(rate({reqs}{{{s}, expected_response="true"}}[10s]))'
    # Latency MUST filter to expected_response="true": k6 splits
    # http_req_duration by tag too, and the failed/timed-out sub-series reads
    # ~5s (the connect timeout), which max() would grab — reporting the
    # timeout as the proxy's latency. Filter to served requests.
    okd = f'{s}, expected_response="true"'
    m = {
        "throughput": avg(ok) or 0.0,               # successful req/s
        # k6 remote-writes durations in SECONDS (prometheus convention); the
        # charts/JS convert to ms.
        "p50": avg(f'max(k6_http_req_duration_p50{{{okd}}})') or 0.0,
        "p99": avg(f'max(k6_http_req_duration_p99{{{okd}}})') or 0.0,
        "err": avg(f'1 - ({ok}) / ({tot})') or 0.0,  # volume-weighted failure fraction
    }
    if proxy != "direct":
        cn = f'name="{proxy}"'
        m["cpu"] = avg(f'sum(rate(container_cpu_usage_seconds_total{{{cn}}}[10s]))') or 0.0
        m["mem"] = avg(f'max(container_memory_working_set_bytes{{{cn}}})') or 0.0
    else:
        m["cpu"], m["mem"] = 0.0, 0.0
    return m


# ------------------------------------------------------------------ render --
W, H, ML, MR, MT, MB = 720, 340, 64, 16, 16, 44


def line_chart(chart_id, ns, series, yfmt="si", y_unit=""):
    """series: [(proxy, [y per N])]; x-axis = N (concurrency)."""
    pts = [y for _, ys in series for y in ys if y is not None]
    if not pts:
        return "<p class='empty'>no data</p>"
    xmax = max(ns)
    ymax = max(pts)
    xticks = [n for n in ns]
    yticks = nice_ticks(0, ymax * 1.05)
    xmaxt, ymaxt = xmax, yticks[-1]
    fmt = fmt_bytes if yfmt == "bytes" else (lambda v: f"{v*1000:g}ms") if yfmt == "ms" else \
        (lambda v: f"{v*100:g}%") if yfmt == "pct" else fmt_si

    def X(x): return ML + (W - ML - MR) * x / xmaxt
    def Y(y): return H - MB - (H - MB - MT) * y / (ymaxt or 1)

    out = [f'<svg viewBox="0 0 {W} {H}" role="img">']
    for t in yticks:
        out.append(f'<line class="grid" x1="{ML}" y1="{Y(t):.1f}" x2="{W-MR}" y2="{Y(t):.1f}"/>')
        out.append(f'<text class="tick" x="{ML-8}" y="{Y(t)+4:.1f}" text-anchor="end">{fmt(t)}</text>')
    for t in xticks:
        out.append(f'<text class="tick" x="{X(t):.1f}" y="{H-MB+18}" text-anchor="middle">{t}</text>')
    out.append(f'<line class="axis" x1="{ML}" y1="{H-MB}" x2="{W-MR}" y2="{H-MB}"/>')
    out.append(f'<text class="axis-label" x="{(ML+W-MR)/2}" y="{H-6}" text-anchor="middle">concurrency (open connections)</text>')
    if y_unit:
        out.append(f'<text class="axis-label" x="14" y="{MT+2}" text-anchor="start">{y_unit}</text>')
    for proxy, ys in series:
        d = " ".join(f"{X(n):.1f},{Y(min(y, ymaxt)):.1f}" for n, y in zip(ns, ys) if y is not None)
        if not d:
            continue
        out.append(f'<polyline class="line s-{proxy}" points="{d}" fill="none" stroke-width="2"/>')
        for n, y in zip(ns, ys):
            if y is not None:
                out.append(f'<circle class="dot s-{proxy}" cx="{X(n):.1f}" cy="{Y(min(y,ymaxt)):.1f}" r="2.5"/>')
    out.append('</svg>')
    return "".join(out)


def card(title, sub, svg):
    return f"""<section class="card"><h2>{html.escape(title)}</h2>
<p class="sub">{html.escape(sub)}</p>{svg}</section>"""


def build_html(meta, ns, data, present):
    def legend():
        return "".join(f'<span class="chip"><span class="swatch s-{p}"></span>{p}</span>' for p in present)

    def serieses(key):
        return [(p, [data[p][n].get(key) for n in ns]) for p in present if any(data[p][n].get(key) for n in ns)]

    charts = [
        card("Throughput vs concurrency", "successful req/s at each fixed connection count — the peak is each proxy's sweet spot",
             line_chart("tput", ns, serieses("throughput"), "si", "req/s")),
        card("p99 latency vs concurrency", "tail latency climbs as a proxy is pushed past its sweet spot",
             line_chart("p99", ns, serieses("p99"), "ms", "s")),
        card("Proxy CPU vs concurrency", "cores consumed; flat-below-1.0 = not CPU-bound (loop/serialization limited)",
             line_chart("cpu", ns, [(p, [data[p][n].get("cpu") for n in ns]) for p in present if p != "direct"], "si", "cores")),
        card("Error ratio vs concurrency", "volume-weighted failed/total (e.g. connection shedding past a cap)",
             line_chart("err", ns, serieses("err"), "pct", "")),
    ]

    # snapshot payload for the N selector: per N, per proxy metrics
    snap = {str(n): [{"proxy": p, **{k: data[p][n].get(k) for k in ("throughput", "p50", "p99", "cpu", "err")}}
                     for p in present] for n in ns}
    cpus = float(meta.get("proxy_cpus", 1) or 1)
    default_n = str(ns[len(ns) // 2])

    return f"""<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>proxy sweep {html.escape(meta['runid'])}</title>
<style>{CSS}
.selrow{{display:flex;align-items:center;gap:10px;margin-bottom:12px;flex-wrap:wrap}}
select{{font:inherit;padding:4px 8px;border-radius:6px;border:1px solid var(--ring);background:var(--surface-1);color:var(--ink)}}
.dot{{fill:currentColor}}
{"".join(f'.dot.s-{p}{{color:var(--c-{p})}} ' for p in PALETTE)}
</style>
<h1>Concurrency sweep — throughput vs open connections</h1>
<p class="meta">run {html.escape(meta['runid'])} · {html.escape(meta['mode'])} mode ·
closed-loop {html.escape(meta.get('sweep_duration','?'))}/point · body {html.escape(meta['req_path'])} ·
proxy box: {html.escape(str(meta['proxy_cpus']))} cpu · N ∈ {{{", ".join(map(str, ns))}}}</p>

<section class="card" style="margin-bottom:20px">
  <h2>Snapshot at a chosen concurrency</h2>
  <div class="selrow"><label for="nsel">concurrency N =</label>
    <select id="nsel">{"".join(f'<option value="{n}"{" selected" if str(n)==default_n else ""}>{n} connections</option>' for n in ns)}</select>
    <span class="sub">closed-loop: N connections each looping request→response</span></div>
  <div class="tablewrap"><table id="snaptab">
    <tr><th>proxy</th><th>throughput</th><th>p50 (ms)</th><th>p99 (ms)</th>
        <th>CPU (cores)</th><th>req/s per core used</th><th>errors</th></tr>
  </table></div>
</section>

<div class="legend" style="margin-bottom:10px">{legend()}</div>
<div class="grid2">{"".join(charts)}</div>
<footer>Each point holds N connections open for the whole measurement, so concurrency is the controlled
input (a fixed client population) rather than the runaway pile-up an open-loop ramp drives at saturation.
Generated by report/sweep.py.</footer>
<script id="snapdata" type="application/json">{json.dumps(snap)}</script>
<script>
const SNAP = JSON.parse(document.getElementById('snapdata').textContent);
const CPUS = {cpus};
function si(v){{ if(v==null) return '—'; if(v>=1e6)return (v/1e6).toFixed(2)+'M'; if(v>=1e3)return (v/1e3).toFixed(1)+'k'; return v>=10?v.toFixed(0):v.toFixed(2); }}
function render(n){{
  const rows = SNAP[n].slice().sort((a,b)=>(b.throughput||0)-(a.throughput||0));
  let h = '<tr><th>proxy</th><th>throughput</th><th>p50 (ms)</th><th>p99 (ms)</th><th>CPU (cores)</th><th>req/s per core used</th><th>errors</th></tr>';
  for(const r of rows){{
    const eff = (r.cpu&&r.throughput)?si(r.throughput/r.cpu):'—';
    h += `<tr><td><span class="swatch s-${{r.proxy}}"></span> ${{r.proxy}}</td>`+
         `<td>${{si(r.throughput)}}</td><td>${{r.p50!=null?(r.p50*1000).toFixed(1):'—'}}</td>`+
         `<td>${{r.p99!=null?(r.p99*1000).toFixed(1):'—'}}</td>`+
         `<td>${{r.cpu!=null&&r.proxy!='direct'?r.cpu.toFixed(2):'—'}}</td><td>${{eff}}</td>`+
         `<td>${{r.err!=null?(r.err*100).toFixed(1)+'%':'—'}}</td></tr>`;
  }}
  document.getElementById('snaptab').innerHTML = h;
}}
const sel = document.getElementById('nsel');
sel.addEventListener('change', e => render(e.target.value));
render(sel.value);
</script>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir")
    ap.add_argument("--prom", default=os.environ.get("PROM_URL", "http://localhost:9090"))
    args = ap.parse_args()

    rdir = os.path.realpath(args.results_dir)
    with open(os.path.join(rdir, "runs.json")) as f:
        meta = json.load(f)
    sweep = meta.get("sweep", {})
    ns = meta["ns"]

    present = [p for p in PROXY_ORDER if p in sweep] + [p for p in sweep if p not in PROXY_ORDER]
    data = {}
    for p in present:
        data[p] = {}
        for n in ns:
            w = sweep.get(p, {}).get(str(n))
            data[p][n] = point_metrics(args.prom, meta["runid"], p, n, w) if w else {}
        peak = max((data[p][n].get("throughput", 0) for n in ns), default=0)
        peak_n = next((n for n in ns if data[p][n].get("throughput", 0) >= 0.99 * peak), None)
        print(f"{p:8s} peak {fmt_si(peak):>8s} req/s @ N={peak_n}")

    if not any(data[p][n] for p in present for n in ns):
        sys.exit("no sweep data in prometheus — reachable? did k6 remote-write succeed?")

    out = os.path.join(rdir, "sweep.html")
    with open(out, "w") as f:
        f.write(build_html(meta, ns, data, present))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
