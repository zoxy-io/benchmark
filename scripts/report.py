#!/usr/bin/env python3
"""Render a benchmark report from a results/<run>/ directory.

Reads cells.jsonl + each cell's per-generator summaries (k6 or wrk2), aggregates
peak req/s and latency percentiles across generators and repeats, and writes
report.md (+ PNG bar charts if matplotlib is present).

CPU/mem enrichment: if PROM_URL is set and reachable (e.g. an SSH tunnel to the
control node's :9090), the proxy's busy fraction and RSS over each peak window
are added. Prometheus isn't reachable externally by default, so this degrades
gracefully when unset.

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


def load_cells():
    peaks, measures = {}, defaultdict(list)
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
        else:
            measures[(key, c["fraction"])].append(c)
    return peaks, measures


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def fmt(x, unit=""):
    return f"{x:,.1f}{unit}" if isinstance(x, (int, float)) else "-"


def main():
    peaks, measures = load_cells()
    proxies = sorted({k[0] for k in peaks})
    combos = sorted({(k[1], k[2], k[3]) for k in peaks})  # proto, body, backends

    out = [f"# zoxy-benchmark report — {RUN.name}", ""]
    inv = RUN / "inventory.json"
    if inv.exists():
        hosts = json.loads(inv.read_text())["inventory"]["value"]["hosts"]
        roles = defaultdict(int)
        for h in hosts.values():
            roles[h["role"]] += 1
        out.append("Fleet: " + ", ".join(f"{n}×{r}" for r, n in sorted(roles.items())) + ".")
        out.append("")

    out += ["## Peak req/s (higher is better)", ""]
    for proto, body, nb in combos:
        out.append(f"### {proto} · body={body} · {nb} backend(s)")
        out.append("")
        out.append("| proxy | peak req/s |")
        out.append("|---|---|")
        for px in proxies:
            out.append(f"| {px} | {fmt(peaks.get((px, proto, body, nb)))} |")
        out.append("")

    # latency at each fraction, plus voids
    voids = []
    for frac in sorted({f for (_, f) in measures}):
        out += [f"## Latency at {int(frac*100)}% of peak (ms)", "",
                "_Aggregate is the conservative max across generators; median over repeats._", "",
                "| proxy | proto | body | be | p50 | p99 | p99.9 | runs | voided |",
                "|---|---|---|---|---|---|---|---|---|"]
        for px in proxies:
            for proto, body, nb in combos:
                cells = measures.get(((px, proto, body, nb), frac), [])
                if not cells:
                    continue
                ok = [c for c in cells if c["check"] == "ok"]
                bad = len(cells) - len(ok)
                p50 = median([cell_latency(c["tag"])[0] for c in ok if c["tag"]])
                p99 = median([cell_latency(c["tag"])[1] for c in ok if c["tag"]])
                p999 = median([cell_latency(c["tag"])[2] for c in ok if c["tag"]])
                out.append(f"| {px} | {proto} | {body} | {nb} | {fmt(p50)} | {fmt(p99)} "
                           f"| {fmt(p999)} | {len(ok)} | {bad or ''} |")
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
        out += ["## Voided cells (excluded — generator/backend was the bottleneck)", ""]
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
