# Running the benchmark

The nightly runs itself. One-time cloud setup — service accounts, the OIDC
federation, the results bucket — is in [SETUP.md](SETUP.md); after that, use
`workflow_dispatch` to trigger a run by hand.

## How a nightly run happens

[`.github/workflows/nightly.yml`](../.github/workflows/nightly.yml) creates a
throwaway six-VM fleet with no public addresses, the loadgen drives the whole
suite itself, results come back through Object Storage, the fleet is destroyed,
and the summary is posted to Discord and published to Pages.

All of that happens **inside the VPC**. The six VMs have no public IPs; the
only things that cross the boundary are the payload going in and the results
coming out, both through Object Storage.

## Profiles

Ramp profiles are compiled into [`bench/src/profile.zig`](../bench/src/profile.zig)
and run across `zoxy, haproxy, nginx, pingora, envoy` (pingora sits out
`c1k-h3`: it has no HTTP/3). `c1k`, `c1k-tls`, `c1k-h2` and `c1k-h3` run on the
schedule, once a night at 00:00 UTC; add `c10k` to
`profiles` on a manual dispatch to run it too. Every profile requests the same
10 KiB body (why: the README, and the `c1k` doc comment in `profile.zig`), on
one ramp: 200 → 40 000 req/s in 300 s (`smoke` excepted).

| profile | connections | transport | deadline | runs nightly? | what it answers |
|---|---|---|---|---|---|
| `c100` | 100 | plaintext | — | manual only | cheap smoke profile, zoxy's shipped defaults |
| `c1k` | 1 000 | plaintext | — | yes (default) | how fast is each proxy at a healthy concurrency |
| `c1k-tls` | 1 000 | TLS 1.3 | — | yes (default) | what terminating TLS costs each proxy — `c1k` with TLS on and nothing else changed |
| `c1k-h2` | 1 000 | HTTP/2, TLS 1.3 | — | yes (default) | what serving HTTP/2 costs each proxy — `c1k-tls` with ALPN `h2` and nothing else changed (one stream per connection; upstream stays HTTP/1.1) |
| `c1k-h3` | 1 000 | HTTP/3, QUIC | — | yes (default) | what serving HTTP/3 costs each proxy — `c1k-tls` with QUIC on the same port number and nothing else changed (one request per connection; upstream stays HTTP/1.1 over TCP; pingora sits out) |
| `c10k` | 10 000 | plaintext | 1 s | manual only | how much of a 10k-connection schedule can each serve *within an SLO* |
| `smoke` | 50 | plaintext | — | never | **not a measurement** — the CI gate. A 30 s, 200→5 000 req/s ramp that exists so a push can prove the harness still runs end-to-end without paying for a fleet. Its ramp shape deliberately matches no other profile, so its numbers cannot be plotted against a real one; `profile.zig` has a test asserting that stays true. |

**Ramp parameters are not knobs.** They are compiled into
[`bench/src/profile.zig`](../bench/src/profile.zig), because the previous
environment-variable plumbing had eleven values with silent fallbacks — which is
how a real run executed with `TIMEOUT_S=0` against a documented `1` and nothing
noticed.

## Locally

You can work on everything except the load generation itself:

```sh
make build     # the bench binary (static musl)
make test      # unit tests
make smoke     # a ~90s end-to-end run of the whole suite, 2 proxies
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

## CI

Every push and pull request runs [`.github/workflows/ci.yml`](../.github/workflows/ci.yml):
`zig fmt`, the unit tests, the nightly's exact cross-compile, `docker compose
config` for every profile, `tofu validate`, `actionlint`, and then `make smoke`'s
run end-to-end. Before it existed the only thing that ever compiled `bench` was
the nightly — so a broken push cost a night and six VMs to discover.
