# zrk (load generator)

The benchmark's load generator is [**zrk**](https://github.com/floatdrop/zrk) — a
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
build.sh   clone (pinned ZRK_REF) + build a static musl `zrk` with local zig
run.py     orchestrator: runs zrk for one ramp AND re-exports its live NDJSON as a
           Prometheus /metrics endpoint (:8090) so the Grafana live dashboard works
src/       the cloned zrk source (git-ignored; created by build.sh)
zrk        the built static binary   (git-ignored)
```

## Build

`build.sh` uses the local `zig` (the devenv shell provides it; needs >= 0.16) to
cross-compile a static musl `zrk`. It pins a zrk commit — zrk force-pushes
`main`, so a floating ref would silently build an old commit.

```sh
./build.sh                       # builds ./zrk at the pinned ZRK_REF
ZRK_REF=<sha> ./build.sh         # build a different zrk commit
```

## Run

The drivers (`scripts/zrk-bench.sh` cloud / `scripts/megabox-bench.sh` loopback)
build `zrk` locally, ship the binary to the loadgen, and invoke `run.py` in a
`python:3-alpine` container with the config as env:

```sh
docker run --rm --network host --ulimit nofile=1048576 -v ~/zrk:/w -w /w \
  -e TARGET=http://PROXY:8080/1k -e MAX_RATE=160000 -e RAMP_SECONDS=120 \
  -e START_RATE=200 -e CONNECTIONS=2000 -e OUT=/w/zoxy.lg1 -e NAME=zoxy -e RUNID=$RUNID \
  python:3-alpine python3 /w/run.py
```

Outputs (consumed by `report/report.py`): `OUT.ndjson`, `OUT.json`, `OUT.hgrm`.
