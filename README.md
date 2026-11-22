# benchmark

Compares **zoxy** against **HAProxy**, **nginx**, **Envoy** and **Pingora**: every proxy
gets the *identical* linearly-growing **open-loop** load ramp until it stops
keeping up, and the output is one self-contained HTML report overlaying
**latency, CPU, memory and achieved req/s against offered load**.

It runs **unattended every night** on a throwaway six-VM fleet with no public
addresses, and the summary is posted to Discord and published to Pages.

```
           200 ──────── linear ramp ────────► MAX_RATE (40k)
                                                  ┌─► backend0 ─┐
        zrk ───────► proxy-under-test ────────────┼─► backend1  │  nginx origin
 (open loop, CO-     (pinned core, 4 GiB cap,     ├─► backend2  │  pool: one
  corrected)          ONE at a time)              └─► backend3 ─┘  canned 10 KiB
      │                       │                    round-robin     body, 2
      │                       │                                    cpus each
      │                       └── cAdvisor :8081 ── sampled at 1Hz
      │                            (cpu + working-set, into the run's
      └── per-1s NDJSON             own artifacts — no Prometheus)
        + HdrHistogram
             │
             └─► bench report ── report.json + report.html
```

**Every request fetches the same 10 KiB response, and nothing else is
measured.** One body size, on purpose: 10 KiB is our estimate of the *mean*
response behind an application-tier proxy (API and HTML, static assets on a
CDN; the median is nearer 1 KiB, but the mean is what sets capacity under a
real mix), and it is the size at which a proxy's per-request cost and its
per-byte cost both show in the result. Smaller bodies measured mostly request
handling; at 100 KiB every proxy converged on the network path. The 64 B to
100 KiB nights this was decided from are in the published history
(2026-09-18 to 2026-10-07).

Every proxy is a **reverse proxy speaking HTTP/1.1 to the origins** (and
HTTP/1.1, or HTTP/2 on `c1k-h2` and HTTP/3 on `c1k-h3`, to the clients) doing
the same job: parse each
request, **pick an origin from a four-node pool**, forward it over a pooled
keep-alive upstream, stream the response back. The pool is what makes the job
the one a production proxy actually does — a single origin measures forwarding,
and forwarding alone; balancing across a set is the other half, and it is the
half where proxies differ.

> **Caddy and Traefik are not in the line-up.** Both were measured in earlier
> revisions and both came in **below Envoy** on every profile they ran. They
> were **removed to cut nightly run time and cost**: the suite benches one proxy
> at a time on a fleet that exists only for the run, so each name costs a full
> ramp per profile in wall-clock and VM-hours, and neither was ever the line a
> reader was reading zoxy against. `git log` restores either one — details in
> [docs/METHODOLOGY.md](docs/METHODOLOGY.md#the-line-up-and-what-is-missing-from-it).

## Docs

| | |
|---|---|
| [docs/METHODOLOGY.md](docs/METHODOLOGY.md) | what is measured, the fairness rules that make the numbers comparable, and what travels with them |
| [docs/RUNNING.md](docs/RUNNING.md) | profiles, triggering a run, the `make` targets, CI, and why `make local` is not a result |
| [docs/SETUP.md](docs/SETUP.md) | the one-time cloud setup CI cannot do for you |
| [docs/LAYOUT.md](docs/LAYOUT.md) | what lives where in this repo |

## Quick start

```sh
make build     # the bench binary (static musl)
make test      # unit tests
make smoke     # a ~90s end-to-end run of the whole suite, 2 proxies
```

The nightly runs itself; use `workflow_dispatch` to trigger one by hand. `make
local` runs the whole suite on your own docker daemon — good for working on the
harness, **not** a benchmark result. See [docs/RUNNING.md](docs/RUNNING.md).
