#!/usr/bin/env python3
"""Render a benchmark report from a results/<run>/ directory.

Reads cells.jsonl + each cell's per-generator summaries (k6 or wrk2), aggregates
peak req/s and latency percentiles across generators and repeats, and writes
report.md (+ PNG bar charts if matplotlib is present).

Prometheus enrichment: if PROM_URL is set and reachable (e.g. an SSH tunnel to
the control node's :9090, or a loaded TSDB snapshot), latency percentiles for
k6-driven cells are aggregated across generators from the remote-written native
histograms, and the proxy's CPU/mem over each window is added. Without PROM_URL
everything degrades gracefully to the per-generator local summaries.

    scripts/report.py results/latest
"""
import json
import os
import re
import statistics
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

RUN = Path(sys.argv[1] if len(sys.argv) > 1 else "results/latest").resolve()
PROM = os.environ.get("PROM_URL")  # optional, e.g. http://localhost:9090


def parse_dur_ms(v):
    """k6 gives float milliseconds; wrk2 gives strings like '1.23ms'/'850us'/'1.05s'."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    m = re.match(r"([\d.]+)\s*(us|ms|s|m)?", str(v).strip())
    if not m:
        return None
    x = float(m.group(1))
    return {"us": x / 1000, "ms": x, "s": x * 1000, "m": x * 60000, None: x}[m.group(2)]


def gen_latency(path):
    """Return (p50, p99, p999) ms and dropped-iteration count from one gen summary."""
    try:
        d = json.loads(Path(path).read_text())
    except Exception:
        return None
    if d.get("tool") == "wrk2":
        lat = d.get("latency", {})
        return (parse_dur_ms(lat.get("p50")), parse_dur_ms(lat.get("p99")),
                parse_dur_ms(lat.get("p999")), 0)
    m = d.get("metrics", {})
    hd = m.get("http_req_duration", {})
    dropped = m.get("dropped_iterations", {}).get("count", 0)
    return (parse_dur_ms(hd.get("med")), parse_dur_ms(hd.get("p(99)")),
            parse_dur_ms(hd.get("p(99.9)")), dropped)


def cell_latency(tag):
    """Aggregate one measured run across generators: conservative max of each pct."""
    d = RUN / "cells" / tag
    p50s, p99s, p999s, dropped = [], [], [], 0
    for g in sorted(d.glob("gen_*.json")):
        r = gen_latency(g)
        if not r:
            continue
        if r[0] is not None: p50s.append(r[0])
        if r[1] is not None: p99s.append(r[1])
        if r[2] is not None: p999s.append(r[2])
        dropped += r[3] or 0
    agg = lambda xs: max(xs) if xs else None
    return agg(p50s), agg(p99s), agg(p999s), dropped


def prom(query, when):
    if not PROM:
        return None
    try:
        u = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": query, "time": int(when)})
        with urllib.request.urlopen(u, timeout=5) as r:
            res = json.load(r)["data"]["result"]
        return float(res[0]["value"][1]) if res else None
    except Exception:
        return None


def prom_latency(c):
    """True cross-generator percentiles from k6's remote-written native
    histograms, scoped to the cell's window. Returns (p50, p99, p999) in ms, or
    None when PROM is unset, the query fails (e.g. metric name drift), or the
    cell was driven by wrk2 (which doesn't remote-write) — callers fall back to
    the conservative max across the generators' local summaries."""
    if not PROM or c.get("proto") == "h1-tls":
        return None
    win = max(1, int(c["end"]) - int(c["start"]))
    out = []
    for qt in (0.5, 0.99, 0.999):
        v = prom(f"histogram_quantile({qt}, sum(rate(k6_http_req_duration_seconds[{win}s])))", c["end"])
        if v is None:
            return None
        out.append(v * 1000)
    return tuple(out)


def cell_lat_any(c):
    """Latency for one measured cell: Prometheus aggregation when available,
    else local summaries. Returns (p50, p99, p999, source)."""
    lat = prom_latency(c)
    if lat:
        return lat[0], lat[1], lat[2], "prom"
    if c.get("tag"):
        loc = cell_latency(c["tag"])
        return loc[0], loc[1], loc[2], "local"
    return None, None, None, "none"


def load_cells():
    peaks, measures, crosschecks = {}, defaultdict(list), {}
    f = RUN / "cells.jsonl"
    if not f.exists():
        sys.exit(f"no cells.jsonl in {RUN}")
    for line in f.read_text().splitlines():
        if not line.strip():
            continue
        c = json.loads(line)
        key = (c["proxy"], c["proto"], c["body"], c["backends"])
        if c["kind"] == "peak":
            peaks[key] = c["achieved_rps"]
        elif c["kind"] == "crosscheck":
            crosschecks[key] = c
        else:
            measures[(key, c["fraction"])].append(c)
    return peaks, measures, crosschecks


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def fmt(x, unit=""):
    return f"{x:,.1f}{unit}" if isinstance(x, (int, float)) else "-"


def main():
    peaks, measures, crosschecks = load_cells()
    proxies = sorted({k[0] for k in peaks})
    combos = sorted({(k[1], k[2], k[3]) for k in peaks})  # proto, body, backends

    out = [f"# zoxy-benchmark report — {RUN.name}", ""]
    out += ["_h1 and h2 cells are driven by k6, h1-tls cells by wrk2 (k6 would negotiate"
            " h2 over TLS). Compare proxies **within** a protocol; deltas **across**"
            " protocols also include tool differences. The cross-check table below"
            " replays each k6-found h1 peak with wrk2 so tool disagreement is visible._", ""]
    inv = RUN / "inventory.json"
    if inv.exists():
        hosts = json.loads(inv.read_text())["inventory"]["value"]["hosts"]
        roles = defaultdict(int)
        for h in hosts.values():
            roles[h["role"]] += 1
        out.append("Fleet: " + ", ".join(f"{n}×{r}" for r, n in sorted(roles.items())) + ".")
        out.append("")
    ver = RUN / "versions.txt"
    if ver.exists():
        out += ["## Versions under test", "", "```", ver.read_text().rstrip(), "```", ""]

    out += ["## Peak req/s (higher is better)", ""]
    for proto, body, nb in combos:
        out.append(f"### {proto} · body={body} · {nb} backend(s)")
        out.append("")
        out.append("| proxy | peak req/s |")
        out.append("|---|---|")
        for px in proxies:
            out.append(f"| {px} | {fmt(peaks.get((px, proto, body, nb)))} |")
        out.append("")

    if crosschecks:
        out += ["## wrk2 cross-check of k6-found h1 peaks", "",
                "_wrk2 held at the k6 peak rate for one measure window; a large shortfall"
                " means the k6 peak is tool-inflated (or the check column names the culprit)._", "",
                "| proxy | body | be | k6 peak | wrk2 achieved | ratio | check |",
                "|---|---|---|---|---|---|---|"]
        for key in sorted(crosschecks):
            c = crosschecks[key]
            px, proto, body, nb = key
            k6p = peaks.get(key)
            ratio = f"{c['achieved_rps'] / k6p:.2f}" if k6p else "-"
            out.append(f"| {px} | {body} | {nb} | {fmt(k6p)} | {fmt(c['achieved_rps'])} "
                       f"| {ratio} | {c['check']} |")
        out.append("")

    # latency at each fraction, plus voids
    voids = []
    for frac in sorted({f for (_, f) in measures}):
        out += [f"## Latency at {int(frac*100)}% of peak (ms)", "",
                "_Median over repeats; spread is min–max of p99 across repeats. Source"
                " `prom` = cross-generator native histograms; `local` = conservative max"
                " of per-generator summaries._", "",
                "| proxy | proto | body | be | p50 | p99 | p99 spread | p99.9 | src | runs | voided |",
                "|---|---|---|---|---|---|---|---|---|---|---|"]
        for px in proxies:
            for proto, body, nb in combos:
                cells = measures.get(((px, proto, body, nb), frac), [])
                if not cells:
                    continue
                ok = [c for c in cells if c["check"] == "ok"]
                bad = len(cells) - len(ok)
                rows = [cell_lat_any(c) for c in ok]
                p50 = median([r[0] for r in rows])
                p99 = median([r[1] for r in rows])
                p999 = median([r[2] for r in rows])
                p99s = [r[1] for r in rows if r[1] is not None]
                spread = f"{min(p99s):,.1f}–{max(p99s):,.1f}" if len(p99s) > 1 else "-"
                src = ",".join(sorted({r[3] for r in rows if r[3] != "none"})) or "-"
                out.append(f"| {px} | {proto} | {body} | {nb} | {fmt(p50)} | {fmt(p99)} "
                           f"| {spread} | {fmt(p999)} | {src} | {len(ok)} | {bad or ''} |")
                for c in cells:
                    if c["check"] != "ok":
                        voids.append(f"{px}/{proto}/{body}/{nb}b @{frac}: {c['check']}")
        out.append("")

    if PROM:
        pi = px_ip()  # only the one proxy is active during its run, so host-scoped node_exporter is fine
        top_frac = max({f for (_, f) in measures})
        out += ["## Proxy host resource use (near peak load)", "",
                "_Host-scoped node_exporter on the proxy VM; only the proxy runs during its window._", "",
                "| proxy | proto | body | be | CPU busy | host mem used (MB) |",
                "|---|---|---|---|---|---|"]
        for px in proxies:
            for proto, body, nb in combos:
                cells = measures.get(((px, proto, body, nb), top_frac), [])
                if not cells:
                    continue
                end = max(c["end"] for c in cells)
                cpu = prom(f'1 - avg(rate(node_cpu_seconds_total{{mode="idle",instance=~"{pi}:9100"}}[30s]))', end)
                mem = prom(f'(node_memory_MemTotal_bytes{{instance=~"{pi}:9100"}} '
                           f'- node_memory_MemAvailable_bytes{{instance=~"{pi}:9100"}}) / 1e6', end)
                out.append(f"| {px} | {proto} | {body} | {nb} | {fmt(cpu)} | {fmt(mem)} |")
        out.append("")

    if voids:
        out += ["## Voided cells (excluded — saturation, errors, drops, or no self-check data)", ""]
        out += [f"- {v}" for v in voids] + [""]

    (RUN / "report.md").write_text("\n".join(out))
    print(f"wrote {RUN/'report.md'}")
    make_plots(peaks, proxies, combos)


def px_ip():
    # best-effort: proxy internal IP from inventory, for Prometheus instance match
    inv = RUN / "inventory.json"
    if inv.exists():
        h = json.loads(inv.read_text())["inventory"]["value"]["hosts"]
        return h.get("proxy", {}).get("internal_ip", "")
    return ""


def make_plots(peaks, proxies, combos):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        print("matplotlib not available; skipping plots")
        return
    protos = sorted({c[0] for c in combos})
    for proto in protos:
        bodies = sorted({c[1] for c in combos if c[0] == proto},
                        key=lambda b: {"64": 0, "1k": 1, "10k": 2, "100k": 3}.get(b, 9))
        nb = max({c[2] for c in combos if c[0] == proto})
        fig, ax = plt.subplots(figsize=(9, 5))
        width = 0.8 / max(1, len(proxies))
        for i, px in enumerate(proxies):
            vals = [peaks.get((px, proto, b, nb), 0) for b in bodies]
            ax.bar([x + i * width for x in range(len(bodies))], vals, width, label=px)
        ax.set_xticks([x + 0.4 for x in range(len(bodies))])
        ax.set_xticklabels(bodies)
        ax.set_ylabel("peak req/s")
        ax.set_title(f"Peak req/s — {proto} ({nb} backends)")
        ax.legend()
        fig.tight_layout()
        p = RUN / f"peak_{proto}.png"
        fig.savefig(p)
        print(f"wrote {p}")


if __name__ == "__main__":
    main()
