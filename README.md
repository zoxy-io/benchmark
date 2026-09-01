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
upstream, stream the response back. The generator speaks HTTP/1.1 end-to-end —
over TLS to the proxy on the `c1k-tls` profile, plaintext onward to the origins
in every profile — and the origins are nginx.

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
and run across `zoxy, haproxy, nginx, pingora, envoy`. `c1k` and `c1k-tls` run
on the schedule; pass `profiles: c1k,c1k-tls,c10k` on a manual dispatch to run
`c10k` too:

| profile | connections | transport | deadline | runs nightly? | what it answers |
|---|---|---|---|---|---|
| `c100` | 100 | plaintext | — | manual only | cheap smoke profile, zoxy's shipped defaults |
| `c1k` | 1 000 | plaintext | — | yes (default) | how fast is each proxy at a healthy concurrency |
| `c1k-tls` | 1 000 | TLS 1.3 | — | yes (default) | what terminating TLS costs each proxy — `c1k` with TLS on and nothing else changed |
| `c10k` | 10 000 | plaintext | 1 s | manual only | how much of a 10k-connection schedule can each serve *within an SLO* |
| `smoke` | 50 | plaintext | — | never | **not a measurement** — the CI gate. A 30 s, 200→5 000 req/s ramp that exists so a push can prove the harness still runs end-to-end without paying for a fleet. Its ramp shape deliberately matches no other profile, so its numbers cannot be plotted against a real one; `profile.zig` has a test asserting that stays true. |

Locally you can work on everything except the load generation itself:

```sh
make build     # the bench binary (static musl)
make test      # unit tests
make smoke     # a ~90s end-to-end run of the whole suite, 2 proxies
make local     # a whole run on THIS machine — see the caveat below
make report    # re-render a run dir:  make report RUN=results/latest PROFILE=c1k
make up/down   # the backend origin pool, for poking at a proxy by hand
```

Every push and pull request runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml):
`zig fmt`, the unit tests, the nightly's exact cross-compile, `docker compose
config` for every profile, `tofu validate`, `actionlint`, and then `make smoke`'s
run end-to-end. Before it existed the only thing that ever compiled `bench` was
the nightly — so a broken push cost a night and six VMs to discover.

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
- **Everyone access-logs every request**, because a production reverse proxy
  does and a comparison with logging off measures a configuration nobody
  deploys. Four things follow, and all four have to be read with the numbers:
  - **Numbers from before this landed are not comparable to numbers after it.**
    Every proxy now pays per-request formatting and a write it did not pay
    before. A step down across that commit on the trend chart is the commit.
  - **The sink is a file** — `/tmp/access.log` — **not the container's
    stdout.** Stdout is a pipe dockerd drains, and a proxy that fills it blocks
    inside its own event loop, which makes the ramp a measurement of docker's
    log driver rather than of the proxy. A file write lands in page cache and
    returns. `/tmp` is not a production path; it is the one location writable
    by all five images' users with no `mkdir` and no `chown` (envoy and haproxy
    run non-root), and the container is removed after each turn so the file
    goes with it. One proxy gets there differently: **haproxy** has no
    file-path log target in its configuration language at all — syslog, a
    socket, a ring or a file descriptor — so compose redirects its fd 1 to that
    same file. Its startup `[NOTICE]` lines are on stderr, so `docker logs`
    still explains a failed start.
  - **Each proxy logs its OWN stock format**, not a common one — haproxy
    `option httplog`, nginx's `main`, envoy's default line, zoxy's fixed JSON.
    That is the line each proxy's operators actually read, but the formats run
    from roughly 90 to 250 bytes, so some of the spread is format verbosity.
    Pingora is the exception in kind: it ships no access log at all (it is a
    framework), so `proxies/pingora/src/main.rs` picks one — combined-shaped,
    plus a microsecond duration, with the same per-second timestamp cache nginx
    and haproxy keep internally, so it is not handicapped by formatting a date
    40,000 times a second that the others do not.
  - **They still disagree about backpressure**, which the file sink narrows but
    does not erase. nginx, haproxy and pingora write once per request and wear
    the cost. Envoy buffers and flushes on a timer. zoxy **drops** the line
    rather than stall its event loop. Dropping is cheaper than writing, so zoxy
    would post a throughput number the others were not allowed to earn unless
    the drops are counted. `bench` reads `zoxy_access_log_dropped` off zoxy's
    admin endpoint after every ramp into `access_log_dropped` in the run
    record; nonzero puts a note on that proxy's row saying how much logging
    work was skipped there and not elsewhere.
- **TLS is a profile, not a proxy setting.** Every proxy binds **both** a
  plaintext and a TLS listener on every run, and the profile decides which one
  the ramp connects to — so `c1k-tls` is `c1k` with the transport swapped and
  nothing else changed, and the pair is a subtraction rather than two
  experiments. What travels with those numbers:
  - **One certificate for all five**, generated per run on the proxy host:
    self-signed **ECDSA P-256**. The key type is part of the measurement — a
    signature is per handshake, and an RSA-2048 key would charge a proxy CPU
    that P-256 does not. It is also the only choice available: zoxy accepts
    ECDSA P-256/P-384 and rejects RSA outright, because an RSA signature would
    stall its single event loop.
  - **TLS 1.3, and HTTP/1.1 underneath it.** Every listener is pinned to 1.3,
    and the generator offers **no ALPN**, so nothing here is HTTP/2 and the
    protocol being proxied is the same one every other profile measures. The
    ALPN list is pinned to `http/1.1` where it can be (haproxy, envoy) rather
    than left at each proxy's default: haproxy's TLS bind advertises `h2` by
    default and was measured negotiating HTTP/2 against an ALPN-offering client
    while the others stayed on HTTP/1.1.
  - **The cipher suite is not pinned**, because it cannot be for all five —
    zoxy exposes no knob for it. Each proxy picks from what the generator
    offers, AES-GCM and ChaCha20-Poly1305 do not cost the same per byte, and
    that difference is part of what "this proxy as it ships" means here.
  - **zoxy's TLS session pool is a hard ceiling the others do not have.** It
    preallocates one engine per admitted TLS connection and sheds past the
    pool; `c1k-tls` pins `tls_engines` to 1024, which is both v0.2.0's default
    and its maximum (2048 and 4096 are rejected at startup), against 1 000
    offered connections. `bench` reads `zoxy_shed_tls_engines` off the admin
    endpoint after every TLS ramp and puts a note on the row if it is nonzero —
    a shed connection means the number is partly about that ceiling.
  - **No session resumption, ever.** The generator (zrk, on zssl since 2.4.0)
    can resume and declines to: it offers no PSK and discards the tickets a
    server issues, so every connection is a full handshake. Two consequences:
    handshakes are paid at *connect* time — all 1 000 in the first seconds of
    the ramp — and the p50/p99 read at the 2 000 req/s reference rate is
    record-layer crypto on kept-alive connections, not handshake throughput.
    **zoxy's ticket support is therefore not exercised by this profile at
    all.**
  - **Inbound only.** Every proxy terminates TLS and talks plaintext to the
    origin pool, because zoxy terminates inbound only; letting the other four
    also encrypt upstream would measure a job zoxy cannot do.
  - **The plaintext profiles are untouched**: no proxy renders a TLS listener
    at all unless the profile terminates TLS, so `c1k` runs the configuration it
    ran before this existed and its trend is continuous across the commit. That
    is not tidiness — zoxy preallocates its TLS engine pool at boot, so an
    always-bound listener would have added ~166 MiB (68 MiB → 234 MiB, as
    `zoxy --check` prices 0.8.0) to a published memory number for a socket that
    never sees a handshake.
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
  - **The offered axis itself moved once, at the zrk 2.4.2 bump.** A
    `--timeseries` row's `target_rate` is the load offered across that window;
    it used to be the schedule at the window's closing instant, which is half a
    window of slope higher (~166 rps on this ramp) and was paired with a
    window-averaged achieved rate beside it (zoxy-io/zrk#70). Every proxy in a
    run moves together, so within a run nothing changes; a small shift left on
    the trend chart across that commit is the commit.
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
  pool, `limits.upstream_slots` (stock default 1311). An upstream is leased
  per admitted connection at saturation, not per in-flight request, so a conn
  ceiling above the upstream ceiling is admission capacity that can't be
  served — `bench` pins both explicitly per profile (`proxy_env` in
  `profile.zig`): 1386 conn / **5544 upstream** for `c1k`, 11457/11457 (the
  io_uring completion-queue ceiling) for `c10k`. The upstream pool is 4x
  conn_slots at `c1k` because zoxy parks a keep-alive upstream **per endpoint**
  and round-robin rotates one downstream connection through all four backends;
  pinned equal, as it was with a single origin, zoxy would shed on
  `zoxy_l7_shed_upstream_slots` and the number would measure the pool. `c10k`
  cannot do the same — it is already at the ceiling — so it redials instead,
  which is a real and acknowledged handicap at that profile. Connections beyond
  the ceiling get a static shed response. Every other proxy has no such
  per-process cap.
- **zoxy is measured as shipped**: the nightly benches the **latest published
  release** — `bench` resolves the tag, downloads that release's own
  `x86_64-linux` tarball and verifies it against its `SHA256SUMS.txt`. That is
  the binary a user downloads, which gives it the same standing as the stock
  haproxy, nginx and envoy images it is charted against, and it takes the
  longest and most failure-prone step out of an unattended run. The cost is
  named: a regression now surfaces the night after it **ships**, and the trend
  chart bisects to a release rather than a commit. Set `zoxy_ref` (bench/src/
  profile.zig) to `main`, a branch or a SHA to build from source instead — the
  only way to bench something unreleased. That path clones and compiles on the
  fleet, and its clone layer is cache-busted on the GitHub commits API response
  for `$ZOXY_REF`, not on the ref string, so a `main` build always reflects
  main's current HEAD.
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
bench/src/http.zig        the one bounded HTTP client (std.http.Client has no deadline)
bench/src/{ycs,commands}  Object Storage, the compute sweep, the CLI
compose.yaml              every service, proxies behind profiles, limits enforced
compose.cloud.yaml        host networking + cpuset + peer-IP overlay
proxies/<p>/              one static config per proxy (upstream is the backend0..3 pool)
backend/                  nginx origin, canned bodies generated at start (x4)
cloud/                    terraform: VPC + 6 ephemeral VMs, no public IPs
docs/SETUP.md             the one-time cloud setup CI cannot do for you
.github/workflows/        ci.yml (every push) + the nightly
```
