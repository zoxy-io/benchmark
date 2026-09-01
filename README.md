# benchmark

Compares **zoxy** against **HAProxy**, **nginx**, **Envoy** and **Pingora**: every proxy
gets the *identical* linearly-growing **open-loop** load ramp until it stops
keeping up, and the output is one self-contained HTML report overlaying
**latency, CPU, memory and achieved req/s against offered load**.

It runs **unattended every night** on a throwaway six-VM fleet with no public
addresses, and the summary is posted to Discord and published to Pages.

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

Every proxy is an **HTTP/1.1 reverse proxy** doing the same job: parse each
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
