# `bench` interface contract

The single binary is built once per run (static `x86_64-linux-musl`) and used
both on the CI runner and on the loadgen VM. This file pins the interfaces the
workflow, terraform and cloud-init depend on, so those can be written against it
independently.

## Subcommands

| Command | Runs on | Purpose |
|---|---|---|
| `bench sweep` | runner | Delete any instance labelled `bench=nightly` left over from a previous run |
| `bench wait --runid <id> [--max-wait-s <n>]` | runner | Poll Object Storage for `DONE`/`FAILED`, streaming the uploaded log to stdout |
| `bench fetch --runid <id> --out <dir>` | runner | Download the run's artifacts |
| `bench suite --profile <name> [--proxies a,b,c]` | loadgen | Run every proxy's ramp for one profile (calls the ramp in-process; there is no separate `ramp` subcommand) |
| `bench report <dir> --profile <name>` | runner | `<dir>` → `report.json` + `report.html` |
| `bench index <rundir> --out _site` | runner | Both profiles + trend chart → Pages site |
| `bench notify <rundir> [--dry-run]` | runner | Discord embed per profile, linking the published `report.html` under `--base-url` |

Exit codes: `0` ok, `2` usage error, `3` the operation completed but the run had
failures worth failing CI over, `1` unexpected error.

`bench wait` also uses `5`: the `--max-wait-s` deadline elapsed with no
DONE/FAILED marker yet, but the fleet may still be healthy — unlike `1`
(`never_booted`), which means no VM ever wrote its boot marker and no amount of
retrying will help. `5` is what tells the workflow to re-mint the IAM token and
call `wait` again rather than give up; see nightly.yml's "Wait for the run"
steps.

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
| `PROXY_IP` | Private address of the proxy VM (static .12 — a `for_each` instance cannot reference its siblings). |
| `BACKEND_IPS` | Comma-separated, ORDERED private addresses of the backend pool (static .13-.16). Order matters only so entry N is `backendN` — the same host terraform, the compose `backendN` profile and the `BACKENDn_IP` override all mean. Consumers split on the comma rather than assuming a count. |
| `SSH_KEY` | Path to the per-run private key used to drive proxy/backends. |

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
                       (`bench suite` also WRITES into the unpacked copy: proxies/tls/
                       holds the run's own self-signed ECDSA P-256 cert, generated on the
                       proxy host before any container starts and mounted into every
                       proxy. Nothing uploads it; it dies with the fleet.)
  boot-ok.<role>       written by each VM once cloud-init finishes (diagnoses a boot failure);
                       <role> is loadgen | proxy | backend0..backend3, one object per VM
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
    profile.json                     per-proxy status, provenance + ramp params (replaces meta.json)
    <proxy>.ndjson                   zrk timeseries, byte-identical to the CLI's
    <proxy>.hgrm                     whole-run percentile distribution
    <proxy>.cadvisor.ndjson          {"t":..,"cpu_seconds_total":..,"mem_ws":..,"cadvisor_ms":..} @1Hz
  c1k-tls/ ...
  c10k/ ...
```

One directory per profile, named by the profile — so a profile name is also a
path segment on the published site and a series key in the trend chart.
`profile.json`'s `ramp` object carries `"tls"`, which is what says whether the
load in that directory was offered over TLS; the profile's name is a convention,
that field is the record. Each proxy record also gains `shed_tls_engines` — how
many connections zoxy refused for want of a preallocated TLS session slot, null
for every other proxy and on every plaintext profile. Both fields are additive,
so `schema` stays at 2.

No IP address appears in any of these. `bench` refuses to write an artifact
containing one (see `redact.assertNoIps`).

Each `profile.json` proxy record carries the build its numbers came from, read
out of the container that actually served the ramp rather than from
compose.yaml:

    version        what the running proxy answers (`haproxy -v`, `envoy
                   --version`, `zoxy --version`), or its image reference for one
                   with no version CLI (pingora, whose tag carries the
                   pingora-core release it links)
    build_info     optimisation mode and target CPU, from the image's own
                   /etc/<proxy>/build-info — absent for a stock upstream image
    zoxy_commit    the commit the running zoxy image baked (zoxy only)
    zoxy_ref       the ref the build asked for, normally `main`
    zoxy_ref_sha   what that ref pointed at when the build ran, resolved from
                   GitHub independently of the image

`zoxy_commit != zoxy_ref_sha` means the build did not pick up the ref it named
— the failure the Dockerfile's cache-bust exists to prevent — and marks the
record `degraded` with a `STALE BUILD` note. Either side being null means the
check could not run (GitHub unreachable), which is not the same as stale and is
not reported as such.

`version` is repeated on each `report.json` proxy record, verbatim. profile.json
is this harness's own run record; report.json is what other things read, and a
consumer labelling a number with the build behind it should not have to fetch a
second artifact or hand-type the version and hope it is still true. The string
is the probe's output unchanged (`HAProxy version 3.0.7-1~bpo12+1 ...`), not a
shortened label: shortening is a presentation choice, and anything that wants
`3.0` can take it from the front of that, while nothing can recover the rest
once dropped. `null` where the probe failed or the run predates it — a legacy
run dir with no profile.json reports every version as null rather than failing.
The field is additive, so `schema` stays at 1.

`status` is repeated the same way, and for a sharper reason. report.json
publishes `sustained` as a number for every proxy it lists, so a turn that died
at `start` appears as a plain `0` — indistinguishable from a proxy that ran and
sustained nothing. Every other surface already separates the two: the HTML
table renders an em-dash, history.ndjson carries `status` (which is what keeps
a failure out of the trend line and out of the vs-last-night delta), and the
Discord table refuses to print a zero for a failed proxy at all. This was the
one machine-readable artifact where a crash and a real zero read alike, which
is exactly the "absent, not zero" distinction the rest of the harness insists
on. Values are the `artifact.Status` names — `ok`, `degraded`, `failed`,
`skipped` — or `null` for a run dir with no profile.json. Additive, so `schema`
stays at 1.
