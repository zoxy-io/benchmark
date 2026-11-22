# Methodology

What the benchmark measures, why the numbers are comparable across proxies, and
what travels with them. If you are here to *run* it, see
[RUNNING.md](RUNNING.md).

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

## The line-up, and what is missing from it

Charted every night: **zoxy**, **HAProxy**, **nginx**, **Envoy**, **Pingora**.

**Caddy and Traefik are deliberately absent.** Both were in earlier revisions of
this comparison and both were measured; on every profile they ran, each landed
**below Envoy** — never near the top of the chart, never the one a reader was
weighing zoxy against. The suite benches one proxy at a time on a fleet that
exists only for the duration of the run, so each name in the line-up costs a
full ramp per profile in wall-clock *and* in VM-hours. Two more ramps a night
that only redrew a shape already bounded from above by Envoy's line were not
worth the nightly's time or its bill, so they were **removed to cut run time and
cost, not because the proxies are uninteresting**.

A `direct` no-proxy origin baseline is gone for a related but separate reason —
see [Origin headroom](#fairness-rules) below. Envoy and nginx each went through
the same removal at one point and came back.

Nothing here is parked or commented out: an unexercised proxy config rots (the
TLS/ALPN pinning and healthcheck probes would be carried but never run), and
naming a removed proxy now fails at argument parsing with the name in the
message rather than later as a compose service that does not exist. `git log`
restores any of them, which is a better starting point than a config that has
sat unexercised.

## What every proxy is doing

Every proxy is an **HTTP/1.1 reverse proxy** doing the same job — HAProxy
`mode http`, nginx `proxy_pass`, Envoy `http_connection_manager`, Pingora's
~90-line Rust binary on Cloudflare's framework, zoxy's phase-1 `http`
listener: parse each request,
**pick an origin from a four-node pool**, forward it over a pooled keep-alive
upstream, stream the response back. The generator speaks HTTP/1.1 to the proxy
— over TLS on `c1k-tls` — except on `c1k-h2`, where it speaks HTTP/2 over the
same TLS, and on `c1k-h3`, where it speaks HTTP/3 over QUIC; every proxy speaks
plaintext HTTP/1.1 onward to the origins in every profile, and the origins are
nginx.

The pool is what makes the job the one a production proxy actually does: a
single origin measures forwarding, and forwarding alone. Balancing across a set
is the other half, and it is the half where proxies differ.

## Fairness rules

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
  - **TLS 1.3, and HTTP/1.1 underneath it** (on `c1k-tls`). Every listener is
    pinned to 1.3, and the generator offers **only `http/1.1` in ALPN**, so
    the protocol being proxied is the same one the plaintext profiles measure.
    The ALPN list is pinned to `http/1.1` where it can be (haproxy, envoy, and
    zoxy by omission) rather than left at each proxy's default: haproxy's TLS
    bind advertises `h2` by default and was measured negotiating HTTP/2
    against an ALPN-offering client while the others stayed on HTTP/1.1.
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
- **HTTP/2 is a profile too, and only to the client.** `c1k-h2` is `c1k-tls`
  with ALPN `h2` and nothing else changed, so `c1k-tls` → `c1k-h2` is a
  subtraction the way `c1k` → `c1k-tls` is. What travels with those numbers:
  - **One stream per connection.** Requests in flight still equal the 1 000
    connections, as on every other `c1k` profile. This prices HTTP/2's
    framing, HPACK and stream bookkeeping against HTTP/1.1 on the same TLS;
    it does **not** measure multiplexing, which would change the concurrency
    and with it every other number on the page.
  - **Every proxy advertises `h2, http/1.1`**, the way production listeners
    do: haproxy `alpn h2,http/1.1`, envoy's `alpn_protocols`, nginx
    `http2 on`, pingora `enable_h2()`, zoxy `tls.alpn`. The switch is one
    variable, `PROXY_H2`, and with it unset each proxy renders exactly its
    `c1k-tls` configuration. The generator offers the same two and **counts a
    connection that lands on HTTP/1.1 as a connect error** rather than
    measuring it, and `bench`'s warm probe fails the turn before the ramp if
    a listener picks anything but `h2`, so a proxy cannot quietly publish
    HTTP/1.1 numbers under this profile.
  - **Each proxy's HTTP/2 settings are its own defaults** (window sizes,
    concurrent-stream limits, header table). A 10 KiB response fits the
    protocol's default 65 535-byte window and one 16 KiB DATA frame, so
    neither flow control nor frame size decides the result here.
  - **Upstream stays HTTP/1.1** on every proxy: the same pooled keep-alive
    job as every other profile, now translating between the two protocols.
  - **zoxy's HTTP/2 pools are hard ceilings the others do not have**, like
    its TLS engines. `h2_connections` (pinned at its 1024 default) bounds the
    connections speaking HTTP/2, and with none free zoxy answers an `h2`
    offer with HTTP/1.1; `h2_streams` (1386, required whenever a listener
    speaks h2) bounds the streams. `bench` reads `zoxy_h2_shed_sessions` and
    `zoxy_h2_shed_streams` after every h2 ramp and notes the row if either is
    nonzero. The sessions are preallocated at boot (~94 KB each), so zoxy's
    memory on `c1k-h2` sits roughly 100 MiB above `c1k-tls` by construction.
- **HTTP/3 is a profile too, and only to the client.** `c1k-h3` is `c1k-tls`
  with a QUIC listener added on UDP at the TLS listener's port number, and the
  generator speaking HTTP/3 to it; `c1k-tls` → `c1k-h3` prices HTTP/3 over
  QUIC against HTTP/1.1 over TLS on TCP. What travels with those numbers:
  - **pingora is not in it.** Pingora 0.9 has no HTTP/3, so `bench` leaves it
    out of the profile before anything runs (`profile.zig`'s `serves`): no
    build, no turn, no row, rather than a failed row read as a broken proxy.
  - **One request per connection**, as on `c1k-h2`: 1 000 in flight. This
    prices QUIC packet protection, loss recovery and QPACK, not multiplexing.
  - **ALPN `h3` alone, no 0-RTT, no session resumption.** The generator
    leaves SNI out for the IP-literal target, as RFC 6066 requires. A QUIC
    connection that does not complete is a connect error, and `bench`'s warm
    probe (a two-second, one-connection zrk run over HTTP/3) fails the turn
    before the ramp unless every probe request completes.
  - **The TCP TLS listener stays up** beside the QUIC one, offering
    `http/1.1`, because the warm probe's first check and the healthchecks
    use it. The switch is one variable, `PROXY_H3`: haproxy `bind quic4@`,
    nginx `listen … quic` with `http3 on`, envoy a UDP listener with an HTTP3
    codec, zoxy `http.quic.bind`. With it unset each proxy renders exactly
    its `c1k-tls` configuration.
  - **Each proxy's QUIC settings are its own defaults** (flow-control
    windows, stream limits, Retry, GSO/GRO), and so are the hosts' UDP socket
    buffers: no proxy here sets its own, and `bench` does not raise the
    kernel's.
  - **Upstream stays HTTP/1.1 over TCP** on every proxy.
  - **zoxy's QUIC pool is a hard ceiling the others do not have.**
    `quic_connections` (1024, at most `tls_engines`) bounds the connections,
    and one that finds no slot is left unanswered; its requests share
    `h2_streams` (1386, required with a QUIC binding). zoxy sends a Retry once
    the pool is half full. `bench` reads `zoxy_h3_shed_connections` and
    `zoxy_h3_shed_streams` after every h3 ramp and notes the row if either is
    nonzero. Each QUIC connection reserves about 835 KiB at boot, so zoxy's
    memory on `c1k-h3` sits well above `c1k-tls` by construction, roughly
    835 MiB more.
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
    window of slope higher (~166 rps on the 100k ramp) and was paired with a
    window-averaged achieved rate beside it (zoxy-io/zrk#70). Every proxy in a
    run moves together, so within a run nothing changes; a small shift left on
    the trend chart across that commit is the commit.
  - **The body moved once, from 1 KiB to 10 KiB (2026-11-15),** in the same
    change that moved envoy to 1.40, pingora to 0.9 and the generator to zrk
    3.0.1 (on Zig 0.17.1), so the trend steps once for all of them. zrk 3
    sends a byte-identical HTTP/1.1 request and writes the same timeseries,
    but its connection loop was reworked (HTTP/3, scripting), so part of that
    step may be the generator rather than the proxies. 10 KiB estimates the
    mean response behind an app-tier proxy, and is where per-request and
    per-byte cost both show (reasoning in `profile.zig`, on `c1k`). Every
    proxy's `c1k` and `c1k-tls` trend steps down there; the 64 B, 10 KiB and
    100 KiB bands that ran from 2026-09-18 to 2026-10-07 stay in
    `history.ndjson`, and the old `c1k-10k` series is the one the new `c1k`
    continues.
  - **The generator moved to zrk 3.0.3 when `c1k-h3` started.** 3.0.2 shares
    latency statistics between the generator's threads instead of keeping a
    histogram per connection (much less memory on the loadgen); 3.0.3 fixes
    HTTP/3 against haproxy and envoy. The HTTP/1.1 and HTTP/2 requests and the
    timeseries are unchanged, so the `c1k`, `c1k-tls` and `c1k-h2` series carry
    on; a step on that night may still be the generator.
  - **`MAX_RATE` moved once, from 100k to 40k (2026-11-15), right after the
    body did.** At 10 KiB the fastest knee on record is zoxy's 27.2k, so
    100k spent most of each ramp in overload; 40k keeps 1.5x over that best
    night and puts 2.5x more windows near each knee. The run dispatched
    between the two changes is the one night of 10 KiB on the 100k ramp: read
    its offered axis apart from both sides. A proxy whose `sustained` reads
    within a few percent of 40k hit the ceiling, not its knee: raise
    `max_rate` before believing it.
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
