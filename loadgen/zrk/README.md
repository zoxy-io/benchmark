# zrk (load generator)

The benchmark's load generator is [**zrk**](https://github.com/zoxy-io/zrk) — a
constant-throughput / linear-ramp HTTP load generator (Zig, wrk2 lineage) that
reports latency **corrected for coordinated omission** and records it in an
**HdrHistogram**. It replaced the old `vegeta-ramp`.

Why zrk here:

- **Open-loop linear ramp** (`-R start:end -d dur`) — offers a rate that climbs
  `START_RATE → MAX_RATE` and keeps offering even when the proxy falls behind, so
  saturation shows as a sharp knee (same discipline as the old vegeta-ramp, but
  CO-correct *during* the ramp — send times are a closed-form function of the
  request index, never of responses).
- **High-frequency, accurate latency**: per-interval NDJSON with
  p50/p90/p99/**p99.9**/**max**, plus (with `--timeseries-histogram`) each
  interval's full **HdrHistogram** blob — losslessly mergeable / re-percentileable.
- **Whole-run HdrHistogram** (`--hdr`, `--format json`) incl. p99.99.

## Files

```
build.sh   download a PINNED zrk release (ZRK_VERSION) — checksum-verified,
           statically-linked `zrk`; no zig / source clone
run.py     orchestrator: runs zrk for one ramp AND re-exports its live NDJSON as a
           Prometheus /metrics endpoint (:8090) so the Grafana live dashboard works
zrk        the downloaded static binary   (git-ignored)
```

## Fetch

`build.sh` downloads a pinned zrk **release** binary (statically linked, so the
same file runs in `alpine` or any glibc image) and verifies it against the
release's `SHA256SUMS.txt`. No build toolchain is needed. Pin a release version —
bump it deliberately.

```sh
./build.sh                          # fetches ./zrk at the pinned ZRK_VERSION (1.1.1)
ZRK_VERSION=1.1.1 ./build.sh        # a specific release
ZRK_ARCH=aarch64-linux ./build.sh   # a different arch (default x86_64-linux)
```

### Threading model (>=1.0.0)

As of v1.0.0 zrk runs its load generation on a **zio coroutine engine**
instead of `std.Io.Threaded`'s one-OS-thread-per-connection model — connections
are now cheap coroutines multiplexed across a small, fixed pool of OS threads
(`-t`/`--threads`, zrk default 2, like wrk). `run.py` exposes this as `THREADS`
(default 4) and passes it straight through as `-t`; size it to the **loadgen
VM's core count** (`loadgen_cores` in `cloud/variables.tf`, default 4), not to
`CONNECTIONS` — connections no longer cost a thread each.

## Run

The driver (`scripts/zrk-bench.sh`) fetches `zrk` locally, ships the binary to the
loadgen, and invokes `run.py` in a `python:3-alpine` container with the config as
env:

```sh
docker run --rm --network host --ulimit nofile=1048576 -v ~/zrk:/w -w /w \
  -e TARGET=http://PROXY:8080/1k -e MAX_RATE=67000 -e RAMP_SECONDS=300 \
  -e START_RATE=200 -e CONNECTIONS=1024 -e THREADS=4 -e OUT=/w/zoxy.lg1 -e NAME=zoxy -e RUNID=$RUNID \
  python:3-alpine python3 /w/run.py
```

Outputs (consumed by `report/report.py`): `OUT.ndjson`, `OUT.json`, `OUT.hgrm`.
