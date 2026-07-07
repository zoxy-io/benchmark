# proxy-bench

Compares **zoxy** against **HAProxy**, **Envoy**, **Traefik** and **Caddy**:
every proxy gets the *identical* linearly-growing open-loop load ramp until it
stops keeping up, and the output is one HTML report overlaying **latency, CPU,
memory and achieved req/s against offered load** — plus a live Grafana view
while a run is in flight.

```
            0 ──────── linear ramp ────────► MAX_RATE
   k6  ─────────────► proxy-under-test ─────────────► nginx origin
 (open loop,          (2 cpus, 512 MiB,               (canned 64B..100k
  arrival rate)        ONE at a time)                  bodies, 2x cpus)
        │                     │ cAdvisor: cpu/mem per container
        └── remote-write ──► Prometheus ◄── scrape ───┘
                                │
                     Grafana (live) + report.py (the artifact)
```

## The design in five sentences

**Containers are the deploy spec.** Each proxy is a compose service with a
static config and the *same* enforced cpu/memory limits (service-level `cpus` /
`mem_limit` — compose applies these without swarm); locally the whole stack is
one compose project, in the cloud the very same `compose.yaml` runs across
three VMs with a small overlay (`compose.cloud.yaml`: host networking, cpuset,
peer IPs). **The measurement is one deterministic ramp** (k6
`ramping-arrival-rate`, 0 → `MAX_RATE` over `RAMP_DURATION`) shared by every
proxy, so elapsed time ≡ offered rate is the same mapping for every run and
sequential runs overlay on a single x-axis. **Saturation is detected post-hoc**
by `report.py` (2 consecutive 15s windows with achieved < 98% of offered,
errors > 1%, or dropped iterations), not by aborting mid-run — the post-knee
failure shape is data, not noise. **Runs are guarded**: open-loop arrivals are
coordinated-omission-free, `MAX_VUS` caps connection storms, a `direct` pseudo
proxy calibrates that the origin itself saturates above `MAX_RATE`, and the
report flags any window where the loadgen/backend host ran out of CPU.
**Local = correctness, cloud = numbers**: on macOS everything shares the Docker
VM, so treat local results as a smoke test and quote the 3-VM cloud runs.

## Run it locally

Needs docker + docker compose v2, jq, python3.

```sh
cp .env.example .env       # knobs: MAX_RATE, RAMP_DURATION, PROXY_CPUS, PROXIES...
make smoke                 # 2-min mini-ramp on haproxy+caddy — checks the plumbing
make bench                 # the real thing: every proxy, identical ramp (~10 min each)
make report                # -> results/<runid>/report.html
open results/latest/report.html
```

Grafana live view: <http://localhost:3000> (dashboard "Proxy bench — live run").
Run a subset with `make bench PROXIES="zoxy haproxy"`; add `direct` to PROXIES
to run the origin-calibration ramp.

## Run it in Yandex Cloud

```sh
cd cloud && cp terraform.tfvars.example terraform.tfvars   # fill in creds
make cloud-up              # 3 VMs: loadgen 16c / proxy 4c / backend 8c, core_fraction=100
make cloud-bench           # rsync repo -> VMs, backend+monitoring up, ramp every proxy
PROM_URL=http://<loadgen-ip>:9090 make report
make cloud-down
```

`cloud-bench` prints the Grafana URL. VMs run stock Ubuntu 24.04; cloud-init
installs a **pinned** docker-ce so local and cloud execute the same compose
implementation. Iterating never rebuilds an image — edit, rerun `cloud-bench`.

## Fairness rules (what makes the numbers comparable)

- **Same box for every proxy**: `PROXY_CPUS` / `PROXY_MEM` enforced by cgroups,
  identical per proxy; thread counts are set *explicitly* to match
  (`nbthread`, `--concurrency`, `GOMAXPROCS`) — container runtimes lie to
  autodetection.
- **Same ramp for every proxy**: never compare runs with different `MAX_RATE`
  or `RAMP_DURATION` — the shared x-axis depends on it. Recorded per run in
  `results/<runid>/runs.json` together with image versions.
- **zoxy runs io_uring**: Docker's default seccomp profile has denied
  `io_uring_*` since engine 25.0. `proxies/zoxy/seccomp-iouring.json` is the
  default profile *plus* those three syscalls — not `unconfined`, so zoxy keeps
  the same syscall-filter overhead as everyone else. The driver fails the run
  if zoxy dies at startup (the symptom of a missing profile).
- **Origin headroom**: backend gets 2× the proxy's cores; run `direct` once per
  environment to prove the origin saturates above `MAX_RATE`.

## Layout

```
compose.yaml           every service, proxies behind profiles, limits enforced
compose.cloud.yaml     host networking + cpuset + peer-IP overlay
proxies/<p>/           one static config per proxy (upstream is always `backend`)
backend/               nginx origin, canned bodies generated at start
k6/ramp.js             warmup + the single linear ramp (open loop)
scripts/run-all.sh     the driver: up -> probe -> ramp -> down -> cooldown
scripts/cloud-run.sh   terraform IPs -> rsync -> remote compose -> run-all.sh
monitoring/            prometheus (+file_sd targets), grafana provisioning
report/report.py       prometheus -> saturation knees -> self-contained report.html
cloud/                 terraform: VPC + 3 VMs + pinned-docker cloud-init
```
