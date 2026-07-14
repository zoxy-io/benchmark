# proxy-bench

Compares **zoxy** against **HAProxy**, **Envoy**, **Traefik**, **nginx** and
**Pingora**: every proxy gets the *identical* linearly-growing **open-loop** load
ramp until it stops keeping up, and the output is one HTML report overlaying
**latency, CPU, memory and achieved req/s against offered load** — plus a live
Grafana view while a run is in flight.

zoxy's libxev build is **L4-only**, so every proxy runs as an **L4 TCP
passthrough** (`mode tcp`, `tcp_proxy`, TCP router, nginx `stream`, and a small
Rust binary on Cloudflare's Pingora framework) — the same job for everyone:
relay bytes, parse nothing. The generator still speaks HTTP end-to-end; the
origin nginx is the HTTP endpoint and the proxies are transparent tunnels.

```
             0 ──────── linear ramp ────────► MAX_RATE
 vegeta-ramp ───────► proxy-under-test ───────────► nginx origin
 (open loop,          (pinned cores, 512 MiB,       (canned 64B..100k
  LinearPacer)         ONE at a time)                bodies, 8x cpus)
      │                       │ cAdvisor: cpu/mem per container
      ├── /metrics ──► Prometheus ◄── scrape ───────┘
      │  (scraped)         │
      └── per-1s CSV       └─► Grafana (live)
             │
             └─► report/report_vegeta.py  ── the artifact (report.html)
```

## The design in five sentences

**Containers are the deploy spec.** Each proxy is a compose service with a
static config and the *same* enforced cpu/memory limits (service-level `cpus` /
`mem_limit` — compose applies these without swarm); locally the whole stack is
one compose project, in the cloud the very same `compose.yaml` runs across three
VMs with a small overlay (`compose.cloud.yaml`: host networking, cpuset, peer
IPs). **The measurement is one deterministic open-loop ramp** —
`loadgen/vegeta-ramp` (built on Vegeta's `LinearPacer`) offers `0 → MAX_RATE`
over `RAMP_SECONDS`, and keeps offering at the scheduled rate even when the proxy
falls behind (coordinated-omission safe), so the offered axis is analytic
(`offered = start_rate + slope·t`) and the saturation knee is exact and sharp.
**One loadgen is enough**: a single 16-core box saturates any proxy at ~25% CPU
(it hits the proxy's concurrency-collapse wall long before its own limit), so
there is no second loadgen and no VU/goroutine-heavy generator. **Runs are
guarded**: `MAX_WORKERS` caps in-flight concurrency (the open-loop analogue of a
VU pool — too high and past saturation it piles connections and collapses the
path), and a `direct` pseudo-proxy calibrates that the origin itself saturates
above the proxies. **Local = plumbing, cloud = numbers**: quote the 3-VM cloud
runs.

## Run it in Yandex Cloud

```sh
cd cloud && cp terraform.tfvars.example terraform.tfvars   # fill in creds
make cloud-up              # 3 VMs: loadgen 16c / proxy 8c / backend 8c, core_fraction=100
make cloud-bench           # build vegeta-ramp, ramp every proxy, write CSVs + meta.json
make report                # -> results/latest/report.html
make cloud-down
```

`cloud-bench` (`scripts/vegeta-bench.sh`) reads the terraform inventory, ships
the repo, brings up backend + monitoring, and for each proxy: brings it up,
ramps it with `vegeta-ramp` on the loadgen, pulls the per-1s CSV, tears it down.
Live Grafana: **http://\<loadgen-ip\>:3000** → "Proxy bench — live run (vegeta
open-loop)". Run a subset with `make cloud-bench PROXIES="direct zoxy haproxy"`.

Local `make up` / `make down` start/stop backend + prometheus + grafana for
poking at the stack; the load driver itself is cloud-only.

## Fairness rules (what makes the numbers comparable)

- **Same job for every proxy**: all are L4 TCP passthroughs — HAProxy
  `mode tcp`, Envoy `tcp_proxy`, Traefik TCP router, nginx `stream` (the
  official image ships the stream module — no custom build), Pingora (a ~60-line
  Rust binary on Cloudflare's framework — `proxies/pingora`), zoxy natively.
  Nobody pays for HTTP parsing that others skip.
- **Same box for every proxy**: `PROXY_CPUS` / `PROXY_MEM` enforced by cgroups,
  identical per proxy; thread counts set *explicitly* to match (`nbthread`,
  `--concurrency`, `GOMAXPROCS`, `worker_processes`, pingora `threads`).
  **zoxy has no thread knob** — one event loop per process — so to spend a
  multi-core box it runs `PROXY_CPUS` worker processes sharing `:8080` via
  `SO_REUSEPORT`, each `taskset`-pinned to its own core (`ZOXY_WORKERS`). The
  proxy VM is 8 cores so `PROXY_CPUS=4` pins to cores `0–3` with `4–7` free for
  the OS/monitoring (a saturated all-cores box starved the single-loop proxies).
- **Same ramp for every proxy**: never compare runs with different `MAX_RATE`,
  `RAMP_SECONDS` or `MAX_WORKERS` — the shared offered axis depends on it.
  Recorded per run in `results/<runid>/meta.json`.
- **zoxy runs io_uring**: Docker's default seccomp has denied `io_uring_*` since
  engine 25.0. `proxies/zoxy/seccomp-iouring.json` is the default profile *plus*
  those three syscalls — not `unconfined`. If io_uring init fails zoxy exits at
  startup and the driver fails the run loudly. (The libxev rewrite dropped the
  vendored OpenSSL, so zoxy builds and runs on ARM natively — io_uring just
  can't be *emulated*.)
- **zoxy does no DNS**: endpoints must be IP literals. The entrypoint resolves
  `backend` once at start (compose DNS locally, `extra_hosts` in cloud) and
  renders the literal into the config.
- **zoxy holds one relay buffer per open tunnel, pool = 1024 per process,
  compile-time**: connections beyond it get an immediate close. With N worker
  processes the cap is N×1024, so keep `MAX_WORKERS` under it. Past a proxy's
  sweet-spot concurrency (~2000 connections) *every* proxy congestion-collapses
  — throughput falls as latency climbs — so `MAX_WORKERS` is set at the plateau,
  not maxed.
- **Pin the zoxy build**: the Dockerfile caches its `git clone`, so `ZOXY_REF=main`
  can silently be a stale commit. Pin a SHA for anything version-sensitive.
- **Origin headroom**: backend gets several times the proxy's cores; `direct`
  (in `PROXIES`) proves the origin saturates well above the proxies.

## Layout

```
compose.yaml              every service, proxies behind profiles, limits enforced
compose.cloud.yaml        host networking + cpuset + peer-IP overlay
proxies/<p>/              one static config per proxy (upstream is always `backend`)
backend/                  nginx origin, canned bodies generated at start
loadgen/vegeta-ramp/      open-loop linear-ramp generator (Vegeta LinearPacer) + /metrics
scripts/vegeta-bench.sh   the driver: build -> per-proxy up/probe/ramp/CSV/down
monitoring/               prometheus (+file_sd targets), grafana (2 dashboards)
report/charts.py          shared inline-SVG chart engine + prometheus helpers
report/report_vegeta.py   CSVs + meta.json + prometheus CPU -> self-contained report.html
cloud/                    terraform: VPC + 3 VMs + pinned-docker cloud-init
```
