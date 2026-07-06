# zoxy-benchmark

A reproducible, multi-host benchmark that compares **zoxy** against **HAProxy**,
**Envoy**, **Traefik**, and **Caddy** on identical hardware, and reports peak
req/s, tail latency, CPU, and memory for each.

The whole run is one-shot: `make bench` provisions a fleet in Yandex Cloud,
converges it, drives the full scenario matrix against each proxy in turn, pulls
the metrics back, and tears the fleet down.

## Why a fleet instead of one box

The single-host benches in `zoxy/bench/` are honest but constrained: the load
generator, the proxy, and the origin all share one kernel and compete for cores.
They pin roles to **disjoint cores** to keep that competition from lying. This
suite makes the same isolation stronger and simpler — **disjoint hosts** — and
makes the setup reproducible enough to compare five different proxies fairly:

```
   loadgen ×M            proxy-under-test (SUT)          backend ×N
  ┌───────────┐   k6 /   ┌──────────────────────┐  h1   ┌──────────┐
  │ generator │ ─ wrk2 ─►│ zoxy | haproxy |      │ keep- │ nginx    │
  │           │◄─ p50..  │ envoy | traefik |     │ alive │ canned   │
  │           │   p999   │ caddy  (ONE per run)  │ ─────►│ 200 body │
  └───────────┘          └──────────────────────┘       └──────────┘
        │  node_exporter on EVERY host  ┌─────────────┐
        └──────────────────────────────►│ control VM  │  Prometheus + orchestrator
                                         │ Prometheus  │◄── each proxy's own /metrics
                                         └─────────────┘
```

Only the **proxy binary changes between runs**. VM type, kernel, sysctls,
backend, and load profile are byte-identical, so a difference in the numbers is a
difference in the proxy — not the environment.

## What makes the comparison fair (the credibility layer)

These are the controls that decide whether the numbers mean anything:

- **Guaranteed vCPU.** Yandex `core_fraction` is pinned to **100** on the proxy
  host (and the generators). A fractional core shares a physical core and turns
  results into noise.
- **One image, all proxies, tuning baked in.** Every host boots the *same*
  NixOS image (built by `nixos-generators`). Sysctls and ulimits
  (`nofile`, `somaxconn`, `tcp_max_syn_backlog`, `netdev_max_backlog`,
  `ip_local_port_range`, `tw_reuse`) are set identically everywhere. Default
  ulimits alone cap a fast proxy far below its ceiling.
- **Thread parity.** Each proxy is told to use every vCPU, and we record the
  knob: `haproxy nbthread=N`, `envoy --concurrency N`, `GOMAXPROCS=N`
  (Caddy/Traefik), zoxy auto thread-per-core (`SO_REUSEPORT`). The exact binary
  versions under test are recorded into `results/<ts>/versions.txt`.
- **The backend is never the bottleneck.** `N` origin hosts run nginx with
  `worker_processes auto` (the distro default of ONE worker would cap the origin
  at a single core) serving a canned, in-memory 200. Every run runs a
  **saturation self-check** against both the host-average CPU *and the busiest
  single core* (a lone hot thread hides in the average): if a generator or a
  backend saturates before the proxy does, the run is **void** and discarded
  automatically. The check **fails closed** — no Prometheus answer also voids.
- **Errors and drops can't fake a peak.** Cells are voided when the error
  fraction (non-2xx + socket errors) exceeds `load.max_error_rate`, or when k6
  drops iterations (`maxVUs` exhausted ⇒ latency would be CO-biased).
- **A single generator can't saturate a fast proxy.** Load is aggregated across
  `M` generator hosts (default 2), each running the same self-check.
- **Open-loop load.** k6's constant-arrival-rate executor measures true peak
  req/s at saturation and coordinated-omission-free p99/p999 under a held rate —
  not the closed-loop `conns/latency` figure that conflates the two. h1/h2 cells
  are driven by k6 and h1-tls by wrk2, so compare proxies *within* a protocol;
  a **wrk2 cross-check replays each k6-found h1 peak** to expose tool skew.
- **Discipline.** Warm-up discarded, settle pause after each saturating peak
  search, 3 repeats per cell by default (raise `load.repeats` to ≥5 for
  publishable numbers), median + spread reported. Plaintext **and** TLS (so
  zoxy's kTLS path is exercised). Peaks are bracketed geometrically, then
  bisected to ~10%.

## Repository layout

```
zoxy-benchmark/
├── flake.nix            # devShell + the NixOS image ("bench-host") + zoxy packaging
├── Makefile             # bench / image / up / down / report targets
├── nix/
│   ├── host.nix         # common: sysctl + ulimit tuning, ssh, node_exporter
│   ├── proxies.nix      # all 5 proxy systemd units, shipped DISABLED
│   ├── backend.nix      # nginx origin serving fixed-size canned bodies
│   └── tls.nix          # self-signed fixture baked into the image
├── terraform/           # YC VPC + subnet + image upload + role VMs; outputs inventory
├── proxies/             # one config TEMPLATE per proxy (backends filled at deploy time)
│   ├── zoxy/config.json.tmpl
│   ├── haproxy/haproxy.cfg.tmpl
│   ├── envoy/envoy.yaml.tmpl
│   ├── traefik/{traefik.yml,dynamic.yml.tmpl}
│   └── caddy/Caddyfile.tmpl
├── backend/             # body-size fixtures + nginx site
├── loadgen/             # k6 scenario, rate-sweep driver, wrk2 cross-check, self-check
├── metrics/             # prometheus.yml template + TSDB snapshot puller
├── scenarios/           # the full-sweep matrix (protocol × body × rate × backends)
├── scripts/             # run.sh (one-shot), render-config.sh, collect.sh, report.py
└── results/<timestamp>/ # k6 JSON + prometheus snapshot + each proxy's /metrics
```

## Conventions (every file agrees on these)

| Thing | Value |
| --- | --- |
| Roles | `loadgen` ×M · `proxy` ×1 · `backend` ×N · `control` ×1 |
| Proxy listen | `:8080` H1 plaintext · `:8443` H1/H2 over TLS |
| zoxy admin | `:9901/metrics` |
| Backend listen | `:9000` H1 plaintext, bodies at `/64` `/1k` `/10k` `/100k` |
| node_exporter | `:9100` on every host |
| Prometheus | `:9090` on `control` (remote-write receiver enabled for k6) |
| Proxy config path | `/etc/{zoxy,haproxy,envoy,traefik,caddy}/…` (populated at deploy) |
| TLS fixture | `/etc/bench/tls/{cert,key}.pem` (baked into image) |
| Renderer inputs | `BACKENDS` = `ip:9000,ip:9000,…` · `NPROC` = vCPU count |

## Prerequisites

- Nix with flakes (`nix develop` gives you opentofu, k6, wrk2, jq, prometheus,
  nixos-generators, awscli2).
- A Yandex Cloud account with a **service account** key, a cloud/folder id, and
  an Object Storage bucket for the image. Copy `terraform/terraform.tfvars.example`
  to `terraform/terraform.tfvars` and fill it in.
- An SSH keypair. Its **public** key goes in `var.ssh_public_key` (terraform
  injects it for `bench` on every host); point `SSH_KEY` at the matching
  **private** key when running `bench`. Defaults to `~/.ssh/zoxy_bench`, so
  `ssh-keygen -t ed25519 -f ~/.ssh/zoxy_bench` needs no extra config.

## Run it

Two equivalent front-ends — pick one. With **devenv** (no `make` needed), the
Makefile targets are mirrored as commands you run by name:

```sh
devenv shell    # toolchain: opentofu, k6, wrk2, awscli2, python, …
image           # build the NixOS qcow2 (all five proxies + tuning) and push to YC Object Storage
up              # tofu apply: VPC, subnet, and the loadgen/proxy/backend/control VMs
bench           # for each proxy: render config → start → warm → run the matrix → collect
report          # render tables + plots into results/<timestamp>/
down            # tofu destroy
```

Or with the flake dev shell + `make` (both are provided; `nix develop` now
includes `gnumake`):

```sh
nix develop
make image
make up
make bench      # e.g. make bench PROXIES="zoxy haproxy"
make report
make down
```

> The orchestrator SSHes as `bench` using `$SSH_KEY` (default `~/.ssh/zoxy_bench`,
> else your agent/default keys) and jumps through `control` to the internal hosts.
> It runs with `BatchMode=yes`, so a missing/wrong key stops the run immediately
> with a hint — it never falls back to a password prompt. Fix:
> `SSH_KEY=~/.ssh/yourkey bench` (or `ssh-add ~/.ssh/yourkey`).

`make bench` is the interesting one. Per proxy it:

1. renders the proxy's config template with the real backend IPs and `NPROC`,
   scp's it to `/etc/<proxy>/…`, and `systemctl start`s just that unit;
2. warms up and discards the warm-up window;
3. walks `scenarios/matrix.yaml` (protocol × body size × arrival rate × backend
   count), running k6 from all `M` generators and recording to Prometheus;
4. runs the saturation self-check and marks void cells;
5. `systemctl stop`s the proxy and moves to the next one.

## Cost & safety

- Instances are **on-demand, not preemptible** — a preemptible VM reclaimed
  mid-run would silently corrupt a cell. `make down` (and the `trap` in
  `scripts/run.sh`) always destroys the fleet. Budget realistically: the full
  default matrix (120 cells × peak search + 9 measured runs each) is on the
  order of **15–20 hours** of a handful of small VMs — trim
  `scenarios/matrix.yaml` or use `make bench PROXIES="zoxy haproxy"` for
  shorter passes.
- Nothing here targets anything you don't own: it stands up your own VMs in your
  own folder and load-tests your own proxy. Do not point the generators at hosts
  outside the fleet.
- **Only `control` has a public IP.** proxy/loadgen/backend are internal-only;
  the orchestrator reaches them by internal IP through control as an SSH jump
  host (`ssh -J`). One public IPv4, minimal external surface — the security
  group opens only port 22 on that one host.

## Reading the results

Peak req/s is the highest arrival rate a proxy sustains **before** its own CPU
saturates *and* while the generators and backends still have headroom (the
self-check gate). Latency is reported at that rate and at fixed fractions of it
(e.g. 50%/80%) so the tail is measured under realistic, not overloaded, load.
CPU and memory come from `node_exporter` on the proxy host, scoped to the run
window. See `results/<timestamp>/report.md` after `make report`.

## Status

First-cut scaffold. The connective tissue (image → terraform → orchestrator →
metrics) is complete and internally consistent. zoxy is built from the upstream
package (`zoxy-io/zoxy` → `packages.default`, a hermetic Zig build), defaulting
to its **ReleaseSafe** profile — flip the `overrideAttrs` line in `flake.nix` to
benchmark ReleaseFast. The remaining spots that need your input are marked
`TODO(you)`: your **Yandex Cloud credentials** in `terraform/terraform.tfvars`
and the **NixOS-on-YC image / cloud-init datasource** (the least-tested link).
