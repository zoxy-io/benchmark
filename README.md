# proxy-bench

Compares **zoxy** against **HAProxy** and **Pingora**: every proxy gets the
*identical* linearly-growing **open-loop** load ramp until it stops keeping up,
and the output is one self-contained HTML report overlaying **latency, CPU,
memory and achieved req/s against offered load**.

It runs **unattended every night** ([`.github/workflows/nightly.yml`](.github/workflows/nightly.yml)):
CI creates a throwaway three-VM fleet with no public addresses, the loadgen
drives the whole suite itself, results come back through Object Storage, the
fleet is destroyed, and the summary is posted to Discord and published to Pages.
Envoy, Traefik and nginx were part of an earlier comparison and have been
removed; `git log` restores any of them exactly, which is a better starting
point than a config that has sat unexercised.

zoxy's phase-1 build adds an **HTTP (L7)** listener, so every proxy runs as an
**HTTP/1.1 reverse proxy** (`mode http`, `http_connection_manager`, HTTP router,
nginx `proxy_pass`, and a small Rust binary on Cloudflare's Pingora framework) —
the same job for everyone: parse each request, forward it to the origin over a
pooled keep-alive upstream, stream the response back. The generator speaks HTTP
end-to-end and the origin nginx is the HTTP endpoint, as before — now the
proxies parse it too instead of tunnelling bytes.

```
             0 ──────── linear ramp ────────► MAX_RATE (50k)
        zrk ───────► proxy-under-test ───────────► nginx origin
 (open loop, CO-     (pinned core, 512 MiB,        (canned 64B..100k
  corrected)          ONE at a time)                bodies, 2x cpus)
      │                       │
      │                       └── cAdvisor :8081 ── sampled at 1Hz
      │                            (cpu + working-set, into the run's
      └── per-1s NDJSON             own artifacts — no Prometheus)
        + HdrHistogram
             │
             └─► bench report ── report.json + report.html
```

All of that happens **inside the VPC**. The three VMs have no public IPs; the
only things that cross the boundary are the payload going in and the results
coming out, both through Object Storage.

## The design in five sentences

**Containers are the deploy spec.** Each proxy is a compose service with a
static config and the *same* enforced cpu/memory limits (service-level `cpus` /
`mem_limit` — compose applies these without swarm); locally the whole stack is
one compose project, in the cloud the very same `compose.yaml` runs across three
VMs with a small overlay (`compose.cloud.yaml`: host networking, cpuset, peer
IPs). **The measurement is one deterministic open-loop ramp** —
`bench` (wrk2-lineage, HdrHistogram, calling zrk's `runner.run` in-process) offers `START_RATE → MAX_RATE`
over `RAMP_SECONDS`, and keeps offering at the scheduled rate even when the proxy
falls behind (coordinated-omission corrected), so the offered axis is analytic
(`offered = start_rate + slope·t`) and the saturation knee is exact and sharp.
**One loadgen is enough**: a single 4-core box saturates a 1-CPU proxy well
under its own limit (it hits the proxy's concurrency-collapse wall first), so
there is no second loadgen and no VU/goroutine-heavy generator. **Runs are
guarded**: `CONNECTIONS` caps in-flight concurrency (zrk keeps one request in
flight per connection — too high and past saturation it piles connections and
collapses the path), and a `direct` pseudo-proxy calibrates that the origin
itself saturates above the proxies. **Local = plumbing, cloud = numbers**: quote the 3-VM cloud
runs.

## Running it

The nightly runs itself. One-time cloud setup — service accounts, the OIDC
federation, the results bucket — is in [docs/SETUP.md](docs/SETUP.md); after
that, use `workflow_dispatch` to trigger a run by hand.

Two ramp profiles run in sequence, both across `direct, zoxy, haproxy, pingora`:

| profile | connections | deadline | what it answers |
|---|---|---|---|
| `c1k` | 1 000 | — | how fast is each proxy at a healthy concurrency |
| `c10k` | 10 000 | 1 s | how much of a 10k-connection schedule can each serve *within an SLO* |

Locally you can work on everything except the load generation itself:

```sh
make build     # the bench binary (static musl)
make test      # unit tests
make local     # a whole run on THIS machine — see the caveat below
make report    # re-render a run dir:  make report RUN=results/latest PROFILE=c1k
make up/down   # the backend origin, for poking at a proxy by hand
```

`make local` drives the same suite against your own docker daemon, with no
cloud and no ssh — a ~6 minute loop for working on the harness, a proxy config
or the report. **It is not a benchmark result**: the load generator shares CPU,
cache and memory bandwidth with the proxy it is measuring, and the fleet's
network is replaced by loopback, which removes a ceiling the real `direct`
baseline demonstrably sits near. That is enforced rather than documented — the
run records `fleet: local`, the report carries a banner, and the trend chart
refuses the data.

**Ramp parameters are not knobs.** They are compiled into
[`bench/src/profile.zig`](bench/src/profile.zig), because the previous
environment-variable plumbing had eleven values with silent fallbacks — which is
how a real run executed with `TIMEOUT_S=0` against a documented `1` and nothing
noticed.

## Fairness rules (what makes the numbers comparable)

- **Same job for every proxy**: all are HTTP/1.1 reverse proxies — HAProxy
  `mode http`, Envoy `http_connection_manager`, Traefik HTTP router, nginx
  `proxy_pass` (stock official image, no custom build), Pingora (a ~90-line Rust
  binary on Cloudflare's framework — `proxies/pingora`), zoxy's phase-1 `http`
  listener. Everyone parses each request and keeps both the client and the
  pooled upstream connection alive — nobody skips HTTP parsing that others pay.
- **Same box for every proxy**: hard-capped to **1 CPU** / `PROXY_MEM` by
  cgroups, identical per proxy; thread counts hardcoded to 1 (`nbthread 1`,
  `--concurrency 1`, `GOMAXPROCS=1`, `worker_processes 1`, pingora `threads=1`).
  **zoxy has no thread knob** — one event loop per process — so it runs a single
  process. The proxy VM is 2 cores; the container is pinned to core `0` (cloud
  overlay `cpuset`), leaving core `1` for the OS/monitoring (a saturated
  all-cores box starved the single-loop proxy).
- **Same ramp for every proxy**: never compare runs with different `MAX_RATE`,
  `RAMP_SECONDS` or `CONNECTIONS` — the shared offered axis depends on it.
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
- **zoxy caps admitted connections per process**: on the phase-1 L7 path the
  bound is a configurable `limits.conn_slots` (default 1386, tuned to a ~32 MiB
  footprint — zoxy prints the exact figure at startup; we don't set this, so it
  runs on the default) up to a comptime ceiling of 11464 (the io_uring
  completion-queue c10k budget), plus a shared upstream keep-alive pool of
  `upstream_slots_max`=11464 — pinned equal to the conn-slot ceiling as of
  zoxy #108, since an upstream is leased for a whole client exchange (one
  slot per admitted connection at saturation, not per in-flight request), so
  a higher conn ceiling than upstream ceiling was admission capacity that
  couldn't be served. Connections beyond the admission ceiling get a static
  shed response. `CONNECTIONS` (zrk's in-flight cap) defaults to 500,
  comfortably under the 1386 default. That's not chased up against zoxy's
  ceiling — past a proxy's sweet-spot concurrency *every* proxy
  congestion-collapses (throughput falls as latency climbs), so `CONNECTIONS`
  is set at the plateau every proxy shares. Every other proxy has no such
  per-process cap.
- **Pin the zoxy build**: the Dockerfile caches its `git clone`, so `ZOXY_REF=main`
  can silently be a stale commit. Pin a SHA for anything version-sensitive.
- **Origin headroom**: backend gets several times the proxy's cores; `direct`
  (in `PROXIES`) proves the origin saturates well above the proxies.

## Layout

```
bench/CONTRACT.md         the interfaces terraform, cloud-init and CI code against
bench/src/profile.zig     c1k and c10k — the ramp parameters, compiled in
bench/src/suite.zig       the per-proxy loop; the only place an error is caught
bench/src/ramp.zig        one ramp, embedding zrk's runner.run in-process
bench/src/cadvisor.zig    1Hz container sampling + the identity witness
bench/src/analysis.zig    the measurement math (ported from the old report.py)
bench/src/{svg,html}.zig  inline-SVG charts -> a self-contained report.html
bench/src/{ycs,commands}  Object Storage, the compute sweep, the CLI
compose.yaml              every service, proxies behind profiles, limits enforced
compose.cloud.yaml        host networking + cpuset + peer-IP overlay
proxies/<p>/              one static config per proxy (upstream is always `backend`)
backend/                  nginx origin, canned bodies generated at start
cloud/                    terraform: VPC + 3 ephemeral VMs, no public IPs
docs/SETUP.md             the one-time cloud setup CI cannot do for you
.github/workflows/        the nightly
```
