# vegeta-ramp

An **open-loop, linear-ramp** HTTP load generator built on Vegeta's library
`LinearPacer` (the Vegeta CLI only does constant `-rate`). It offers a rate that
climbs `0 → MAX_RATE` over `RAMP_SECONDS` and keeps offering at the scheduled
rate even when the target falls behind — a true open loop, coordinated-omission
safe — so a proxy's saturation shows up as a sharp latency/throughput knee
instead of the generator quietly throttling (k6's `maxVUs` failure mode).

Its offered-rate column is **analytic** (`offered = START + SLOPE·t`), so the
tipping point on the offered-load axis is exact.

## Build & run

Static binary (CGO-free), runs in any container:

```sh
docker run --rm -v "$PWD":/src -w /src golang:1.23 \
  sh -c 'CGO_ENABLED=0 go build -o vegeta-ramp .'

# run with a high fd ulimit — it opens up to MAX_WORKERS sockets
docker run --rm --network host --ulimit nofile=1048576 \
  -v "$PWD":/w -w /w \
  -e TARGET=http://10.10.0.34:8080/1k \
  -e MAX_RATE=160000 -e RAMP_SECONDS=90 \
  -e CONNECTIONS=2000 -e MAX_WORKERS=2000 \
  -e OUT=/w/zoxy.csv -e NAME=zoxy \
  alpine:3 /w/vegeta-ramp
```

## Config (env)

| var | default | meaning |
|-----|---------|---------|
| `TARGET` | (required) | full URL, e.g. `http://host:8080/1k` |
| `MAX_RATE` | 200000 | req/s at the end of the ramp |
| `RAMP_SECONDS` | 120 | ramp length |
| `START_RATE` | 200 | req/s at t=0 |
| `CONNECTIONS` | 20000 | keep-alive pool (`MaxIdleConnsPerHost`) |
| `MAX_WORKERS` | 20000 | in-flight cap — the open-loop guard |
| `TIMEOUT_S` | 5 | per-request response timeout |
| `OUT` | /results/ramp.csv | per-1s-window CSV |
| `NAME` | ramp | label for logs |

## `MAX_WORKERS` matters

It caps in-flight concurrency. Set it too high and past saturation the generator
piles unbounded connections and *collapses* the path (DoS, not measurement); set
it to a realistic max concurrency (~2000 here) and past saturation throughput
**plateaus** cleanly at `MAX_WORKERS / latency` while latency climbs — the useful
regime. It's the open-loop analogue of k6's `maxVUs`.

## Output

Per-1s-window CSV: `elapsed_s, offered_rps, total, ok, achieved_rps, err_ratio,
p50_ms, p99_ms, bytes_in`. Join with cAdvisor/node_exporter CPU from Prometheus
by timestamp for the full picture (as `report.py` does).
