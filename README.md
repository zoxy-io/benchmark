# benchmark

Compares **zoxy** against **HAProxy**, **nginx**, **Envoy** and **Pingora**: every proxy
gets the *identical* linearly-growing **open-loop** load ramp until it stops
keeping up, and the output is one self-contained HTML report overlaying
**latency, CPU, memory and achieved req/s against offered load**.

It runs **unattended every night** ([`.github/workflows/nightly.yml`](.github/workflows/nightly.yml)):
CI creates a throwaway six-VM fleet with no public addresses, the loadgen
drives the whole suite itself, results come back through Object Storage, the
fleet is destroyed, and the summary is posted to Discord and published to Pages.
Traefik, and a `direct` no-proxy origin baseline, were part of an earlier
comparison and were removed; Envoy and nginx each went through that same removal
and came back. `git log` restores any of them, which is a better starting point
than a config that has sat unexercised.

Every proxy is an **HTTP/1.1 reverse proxy** doing the same job — HAProxy
`mode http`, nginx `proxy_pass`, Envoy `http_connection_manager`, Pingora's
~90-line Rust binary on Cloudflare's framework, zoxy's phase-1 `http`
listener: parse each request,
**pick an origin from a four-node pool**, forward it over a pooled keep-alive
upstream, stream the response back. The generator speaks HTTP end-to-end and
the origins are nginx.

The pool is what makes the job the one a production proxy actually does: a
single origin measures forwarding, and forwarding alone. Balancing across a set
is the other half, and it is the half where proxies differ.

```
             0 ──────── linear ramp ────────► MAX_RATE (100k)
                                                  ┌─► backend0 ─┐
        zrk ───────► proxy-under-test ────────────┼─► backend1  │  nginx origin
 (open loop, CO-     (pinned core, 4 GiB cap,     ├─► backend2  │  pool: canned
  corrected)          ONE at a time)              └─► backend3 ─┘  64B..100k
      │                       │                    round-robin     bodies, 2
      │                       │                                    cpus each
      │                       └── cAdvisor :8081 ── sampled at 1Hz
      │                            (cpu + working-set, into the run's
      └── per-1s NDJSON             own artifacts — no Prometheus)
        + HdrHistogram
             │
             └─► bench report ── report.json + report.html
```

All of that happens **inside the VPC**. The six VMs have no public IPs; the
only things that cross the boundary are the payload going in and the results
coming out, both through Object Storage.

## The design in five sentences

**Containers are the deploy spec.** Each proxy is a compose service with a
static config and the *same* enforced cpu/memory limits (service-level `cpus` /
`mem_limit` — compose applies these without swarm); locally the whole stack is
one compose project, in the cloud the very same `compose.yaml` runs across six
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
collapses the path), and the origin is a four-node pool sized well above what
any 1-CPU proxy can drive. **Local = plumbing, cloud = numbers**: quote the 6-VM cloud
runs.

## Running it

The nightly runs itself. One-time cloud setup — service accounts, the OIDC
federation, the results bucket — is in [docs/SETUP.md](docs/SETUP.md); after
that, use `workflow_dispatch` to trigger a run by hand.

Ramp profiles are compiled into [`bench/src/profile.zig`](bench/src/profile.zig)
and run across `zoxy, haproxy, nginx, pingora, envoy`. Only `c1k` runs on the
schedule; pass `profiles: c1k,c10k` on a manual dispatch to run `c10k` too:

| profile | connections | deadline | runs nightly? | what it answers |
|---|---|---|---|---|
| `c100` | 100 | — | manual only | cheap smoke profile, zoxy's shipped defaults |
| `c1k` | 1 000 | — | yes (default) | how fast is each proxy at a healthy concurrency |
| `c10k` | 10 000 | 1 s | manual only | how much of a 10k-connection schedule can each serve *within an SLO* |

Locally you can work on everything except the load generation itself:

```sh
make build     # the bench binary (static musl)
make test      # unit tests
make local     # a whole run on THIS machine — see the caveat below
make report    # re-render a run dir:  make report RUN=results/latest PROFILE=c1k
make up/down   # the backend origin pool, for poking at a proxy by hand
```

`make local` drives the same suite against your own docker daemon, with no
cloud and no ssh — a ~6 minute loop for working on the harness, a proxy config
or the report. **It is not a benchmark result**: the load generator shares CPU,
cache and memory bandwidth with the proxy it is measuring, and the fleet's
network is replaced by loopback, which removes a network ceiling the cloud path
demonstrably sits near. That is enforced rather than documented — the
run records `fleet: local`, the report carries a banner, and the trend chart
refuses the data.

**Ramp parameters are not knobs.** They are compiled into
[`bench/src/profile.zig`](bench/src/profile.zig), because the previous
environment-variable plumbing had eleven values with silent fallbacks — which is
how a real run executed with `TIMEOUT_S=0` against a documented `1` and nothing
noticed.

## Fairness rules (what makes the numbers comparable)

- **Same job for every proxy**: all are HTTP/1.1 reverse proxies — HAProxy
  `mode http`, nginx `proxy_pass` over an `upstream` block, Envoy
  `http_connection_manager`, Pingora (a ~90-line Rust binary on Cloudflare's
  framework — `proxies/pingora`), zoxy's phase-1 `http` listener. Everyone
  parses each request and keeps both the client and the pooled upstream
  connection alive — nobody skips HTTP parsing that others pay.
- **Same box for every proxy**: hard-capped to **1 CPU** / `PROXY_MEM`
  (default 4 GiB) by cgroups, identical per proxy; thread counts hardcoded to 1
  (`nbthread 1`, `--concurrency 1`, `worker_processes 1`, pingora `threads=1`).
  **zoxy has no thread knob** — one event loop per process — so it runs a single
  process. The container is pinned to core `0` (cloud overlay `cpuset`); the
  proxy VM's spare cores go to the OS/dockerd/cAdvisor and to `docker build`
  (zoxy compiles from source every run), never to the proxy under test.
- **Same ramp for every proxy**: never compare runs with different `MAX_RATE`,
  `RAMP_SECONDS` or `CONNECTIONS` — the shared offered axis depends on it.
  Recorded per run in `results/<runid>/<profile>/profile.json`.
- **zoxy runs io_uring**: Docker's default seccomp has denied `io_uring_*` since
  engine 25.0. `proxies/zoxy/seccomp-iouring.json` is the default profile *plus*
  those three syscalls — not `unconfined`. If io_uring init fails zoxy exits at
  startup and the driver fails the run loudly. (The libxev rewrite dropped the
  vendored OpenSSL, so zoxy builds and runs on ARM natively — io_uring just
  can't be *emulated*.)
- **zoxy does no DNS**: endpoints must be IP literals. The entrypoint resolves
  all four pool members once at start (compose DNS locally, `extra_hosts` in
  cloud) and renders the literals into the config.
- **zoxy caps admitted connections per process**: on the phase-1 L7 path,
  concurrency is bounded by `limits.conn_slots` (stock default 1386, ~32 MiB —
  zoxy prints the exact figure at startup) with a shared upstream keep-alive
  pool, `limits.upstream_slots` (stock default 1024). An upstream is leased
  per admitted connection at saturation, not per in-flight request, so a conn
  ceiling above the upstream ceiling is admission capacity that can't be
  served — `bench` pins both explicitly per profile (`proxy_env` in
  `profile.zig`): 1386 conn / **5544 upstream** for `c1k`, 11464/11464 (the
  io_uring completion-queue ceiling) for `c10k`. The upstream pool is 4x
  conn_slots at `c1k` because zoxy parks a keep-alive upstream **per endpoint**
  and round-robin rotates one downstream connection through all four backends;
  pinned equal, as it was with a single origin, zoxy would shed on
  `zoxy_l7_shed_upstream_slots` and the number would measure the pool. `c10k`
  cannot do the same — it is already at the ceiling — so it redials instead,
  which is a real and acknowledged handicap at that profile. Connections beyond
  the ceiling get a static shed response. Every other proxy has no such
  per-process cap.
- **The zoxy build stays fresh**: `ZOXY_REF` defaults to `main` on purpose —
  the nightly exists to catch a regression the morning after it lands. The
  Dockerfile's clone layer is cache-busted on the GitHub commits API response
  for `$ZOXY_REF`, not on the ref string, so a `main` build always reflects
  main's current HEAD. Pin a SHA only to reproduce a specific past run.
- **Same balancing policy for every proxy**: the origin is a four-node pool and
  every proxy is pinned to **strict round-robin** — haproxy `balance
  roundrobin`, nginx's default method over its `upstream` block, envoy
  `lb_policy: ROUND_ROBIN`, pingora an atomic counter, zoxy `"pick": "rr"`. Round-robin is not everyone's default (zoxy's is p2c, which
  would very likely serve it better), and that is the point: an unpinned policy
  makes the chart a comparison of endpoint-pick algorithms wearing proxy names.
  Nobody health-checks the pool either — haproxy and envoy ship active checks,
  nginx ships *passive* ones on by default (`max_fails=1`, so one error ejects
  an origin for 10s), and pingora as written has none. All of it is off:
  every backend is up for the whole run, and a member that did fail should
  surface as errors rather than be silently routed around by some proxies and
  not others. nginx's needed an explicit `max_fails=0` — the default would
  quietly drop it to a three-origin pool past the knee, which is where this
  benchmark spends its time.
- **Origin headroom**: the pool has 8 cores against the proxy's 1, and each
  member takes ~1/4 of the offered load, so the origin is not the thing being
  measured. This is now *asserted from the sizing*, not measured. A `direct`
  pseudo-proxy used to ramp straight at the origin every night and prove it —
  that was worth a full ramp per profile while the origin was a single 4-core
  box a fast proxy could plausibly approach, and stopped being worth it against
  a pool four times that size. If a proxy ever plateaus at a suspiciously round
  number, re-add it from `git log` before believing the plateau is the proxy's:
  it is the only check that ever bounded the origin *and* the network path.

## Layout

```
bench/CONTRACT.md         the interfaces terraform, cloud-init and CI code against
bench/src/profile.zig     c100, c1k, c10k — the ramp parameters, compiled in
bench/src/suite.zig       the per-proxy loop; the only place an error is caught
bench/src/ramp.zig        one ramp, embedding zrk's runner.run in-process
bench/src/cadvisor.zig    1Hz container sampling + the identity witness
bench/src/analysis.zig    the measurement math (ported from the old report.py)
bench/src/{svg,html}.zig  inline-SVG charts -> a self-contained report.html
bench/src/{ycs,commands}  Object Storage, the compute sweep, the CLI
compose.yaml              every service, proxies behind profiles, limits enforced
compose.cloud.yaml        host networking + cpuset + peer-IP overlay
proxies/<p>/              one static config per proxy (upstream is the backend0..3 pool)
backend/                  nginx origin, canned bodies generated at start (x4)
cloud/                    terraform: VPC + 6 ephemeral VMs, no public IPs
docs/SETUP.md             the one-time cloud setup CI cannot do for you
.github/workflows/        the nightly
```
