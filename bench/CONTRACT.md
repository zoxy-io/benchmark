# `bench` interface contract

The single binary is built once per run (static `x86_64-linux-musl`) and used
both on the CI runner and on the loadgen VM. This file pins the interfaces the
workflow, terraform and cloud-init depend on, so those can be written against it
independently.

## Subcommands

| Command | Runs on | Purpose |
|---|---|---|
| `bench sweep` | runner | Delete any instance labelled `bench=nightly` left over from a previous run |
| `bench wait --runid <id>` | runner | Poll Object Storage for `DONE`/`FAILED`, streaming the uploaded log to stdout |
| `bench fetch --runid <id> --out <dir>` | runner | Download the run's artifacts |
| `bench suite --profile <name> [--proxies a,b,c]` | loadgen | Run every proxy's ramp for one profile (calls the ramp in-process; there is no separate `ramp` subcommand) |
| `bench report <dir> --profile <name>` | runner | `<dir>` → `report.json` + `report.html` |
| `bench index <rundir> --out _site` | runner | Both profiles + trend chart → Pages site |
| `bench notify <rundir> [--dry-run]` | runner | Discord embed + `report.html` attachments |

Exit codes: `0` ok, `2` usage error, `3` the operation completed but the run had
failures worth failing CI over, `1` unexpected error.

## Environment

Read on the **runner**:

| Variable | Meaning |
|---|---|
| `YC_TOKEN` | IAM token from the OIDC exchange. Used as `Authorization: Bearer`. |
| `YC_FOLDER_ID` | Folder to enumerate instances in, for `sweep`. |
| `BENCH_BUCKET` | Object Storage bucket holding run artifacts. |
| `DISCORD_WEBHOOK` | Discord webhook. **Never** passed to a VM. |
| `GITHUB_RUN_ID`, `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY` | Optional; used to link the run from a failure notification. |

Read on the **VM** (set by cloud-init from instance metadata):

| Variable | Meaning |
|---|---|
| `BENCH_BUCKET` | Same bucket. The IAM token comes from the metadata service, not here. |
| `BENCH_RUNID` | Run id; the object prefix is `runs/<runid>/`. |
| `BENCH_PROFILES` | Comma-separated profiles to run, in order. |
| `BENCH_PROXIES` | Comma-separated proxy names. |
| `PROXY_IP`, `BACKEND_IP` | Private addresses of the other two VMs (static .11/.12/.13 — a `for_each` instance cannot reference its siblings). |
| `SSH_KEY` | Path to the per-run private key used to drive proxy/backend. |

No cloud credential is ever stored on a VM: `bench` fetches an IAM token from
`http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token`
with the `Metadata-Flavor: Google` header. That endpoint is enabled by the
instance's `metadata_options` block (`gce_http_endpoint = 1`,
`gce_http_token = 1`) plus an attached service account — it is a first-class
provider block, NOT a `gce-http-token` metadata key.

## Object Storage layout

```
s3://$BENCH_BUCKET/runs/<runid>/
  payload.tar          uploaded by the runner BEFORE apply; bench + compose + proxy configs
  boot-ok.<role>       written by each VM once cloud-init finishes (diagnoses a boot failure)
  log                  the suite's running log, re-uploaded every ~30s
  results.tar          every artifact, uploaded once the suite finishes
  DONE                 written last, after results.tar; its presence means "complete"
  FAILED               written instead of DONE if the suite could not run at all
```

`DONE`/`FAILED` are written **after** the payload they describe, so the runner
never sees a marker pointing at a half-uploaded object.

All access uses `Authorization: Bearer <IAM token>` against
`https://storage.yandexcloud.net`. Yandex Object Storage accepts IAM tokens
directly, so there is no AWS SigV4 signing and no static access key anywhere.

## Instance labels

Every instance carries `bench=nightly` and `runid=<runid>`. `bench sweep`
deletes anything labelled `bench=nightly`, which is the recovery path when a run
is cancelled between `apply` and `destroy` and terraform's per-run state is lost
with the runner.

## Artifact layout inside `results.tar`

Written by the loadgen at `~/bench/results/<runid>/<profile>/`, then tarred.

```
<runid>/
  manifest.json
  c1k/
    profile.json                     per-proxy status + ramp params (replaces meta.json)
    <proxy>.ndjson                   zrk timeseries, byte-identical to the CLI's
    <proxy>.hgrm                     whole-run percentile distribution
    <proxy>.cadvisor.ndjson          {"t":..,"cpu_seconds_total":..,"mem_ws":..} @1Hz
  c10k/ ...
```

No IP address appears in any of these. `bench` refuses to write an artifact
containing one (see `redact.assertNoIps`).
