# One-time cloud setup for the nightly benchmark

`.github/workflows/nightly.yml` assumes a small amount of cloud furniture already
exists. None of it can be created from CI, and that is deliberate: the CI
identity has no right to create identities, keys or buckets, so the blast radius
of a compromised workflow stops at "can create and delete benchmark VMs".

Everything here is done once, by a human, with `yc`. What the workflow creates
and destroys every night is only the fleet itself (`cloud/main.tf`).

> Commands marked **[verify]** are the ones I could not run against a live
> cloud while writing this. The shape is right; check the exact flag names with
> `yc <group> <command> --help` before pasting, because Yandex has renamed
> subcommands in this area more than once.

## Contents

1. [What already has to exist](#0-prerequisites)
2. [Two service accounts](#1-two-service-accounts)
3. [Roles, and why they are the ones they are](#2-roles)
4. [Workload identity federation](#3-workload-identity-federation)
5. [The Object Storage bucket](#4-the-object-storage-bucket)
6. [GitHub repo variables and secrets](#5-github-repo-variables-and-secrets)
7. [GitHub Pages](#6-github-pages)
8. [Testing before you enable the cron](#7-testing-before-you-enable-the-cron)
9. [Things that will bite you](#8-things-that-will-bite-you)

---

## 0. Prerequisites

* A Yandex Cloud **cloud** and a **folder** dedicated to the benchmark. Use a
  dedicated folder: `bench sweep` deletes *every* instance in the folder
  labelled `bench=nightly`, and quota accounting is much easier to read when
  nothing else lives there.
* `yc` CLI, authenticated as a human with folder admin rights.
* The GitHub repo `zoxy-io/benchmark`, with Actions enabled.
* Enough quota in the folder for one fleet:

  | | cores | memory | disk |
  |---|---|---|---|
  | loadgen | 4 | 8 GB | 30 GB network-ssd |
  | proxy | 2 | 4 GB | 30 GB network-ssd |
  | backend | 4 | 8 GB | 30 GB network-ssd |
  | **total** | **10** (at `core_fraction = 100`) | **20 GB** | **90 GB** |

  Plus, per run, one VPC network, one subnet, one route table, one NAT
  (shared-egress) gateway and one security group. An orphaned fleet holds all of
  that until it is swept, so if a run ever fails to tear down, the *next* run
  fails on quota rather than silently doubling the bill.

Set these up front — the rest of the document uses them:

```sh
export YC_FOLDER_ID="$(yc config get folder-id)"
export YC_CLOUD_ID="$(yc config get cloud-id)"
export BENCH_BUCKET="zoxy-benchmark"        # must be globally unique
export GH_REPO="zoxy-io/benchmark"
```

---

## 1. Two service accounts

Two, not one, because they are trusted with very different things. The CI
account can create and destroy machines; the VM account is attached to a host
that is deliberately saturated with hostile-shaped load traffic all night and
must therefore be worth nothing to an attacker.

```sh
yc iam service-account create --name bench-ci \
  --description "GitHub Actions nightly: creates and destroys the benchmark fleet"

yc iam service-account create --name bench-vm \
  --description "Attached to the benchmark VMs: Object Storage, nothing else"

export CI_SA_ID="$(yc iam service-account get --name bench-ci --format json | jq -r .id)"
export VM_SA_ID="$(yc iam service-account get --name bench-vm --format json | jq -r .id)"
echo "CI  $CI_SA_ID"
echo "VM  $VM_SA_ID"
```

**Do not create an access key or an authorized key for either of them.** Not
`yc iam key create`, not `yc iam access-key create`. The whole design (see the
header comment of `bench/src/ycs.zig`) rests on there being no static credential
anywhere: CI gets a short-lived IAM token from OIDC federation, and a VM gets one
from the metadata service. If a key was ever created, delete it:

```sh
yc iam access-key list --service-account-id "$VM_SA_ID"     # expect: empty
yc iam key        list --service-account-id "$VM_SA_ID"     # expect: empty
# yc iam access-key delete <id>
```

(`cloud/terraform.tfvars.example` still documents `service_account_key_file` —
that is the *laptop* path, one human holding one key. CI never uses it, and
`cloud/sa-key.json` is gitignored.)

---

## 2. Roles

### `bench-ci` — what the workflow needs to build and tear down a fleet

```sh
# instances and their disks
yc resource-manager folder add-access-binding "$YC_FOLDER_ID" \
  --role compute.editor --service-account-id "$CI_SA_ID"

# network, subnet, route table, shared-egress gateway, security group
yc resource-manager folder add-access-binding "$YC_FOLDER_ID" \
  --role vpc.admin --service-account-id "$CI_SA_ID"

# permission to ATTACH bench-vm to an instance (service_account_id in main.tf).
# Bound on the SA itself, not on the folder — see below.
yc iam service-account add-access-binding "$VM_SA_ID" \
  --role iam.serviceAccounts.user --service-account-id "$CI_SA_ID"
```

Why each one, and why nothing else:

* **`compute.editor`** — the workflow creates and deletes instances. It is scoped
  to the folder, so it cannot touch anything in a sibling folder.
* **`vpc.admin`** — every run builds its own network, subnet, route table,
  egress gateway and security group (`cloud/main.tf`), so it needs the VPC admin
  role. Note what is *missing*: **`vpc.publicAdmin` is deliberately not
  granted.** That is the role required to give an instance a public address, and
  the fleet has none (`nat = false` on every interface). If someone later flips
  `nat = true`, `tofu apply` fails on permissions instead of quietly putting a
  benchmark VM on the internet. That failure is the point.
* **`iam.serviceAccounts.user`, bound on `bench-vm` specifically** — terraform
  passes `service_account_id` when creating an instance, which requires the
  right to use that identity. Granting it on the *folder* would let the CI
  account attach **any** service account in the folder to a machine it controls,
  which is a straightforward privilege-escalation path. Bound on the one SA, the
  worst it can do is create a VM with exactly the identity it was already meant
  to use.
* No `iam.admin`, no `resource-manager.admin`: CI cannot create identities,
  cannot grant roles, and cannot mint a key.

### `bench-ci` and `bench-vm` — bucket access

Both need the bucket, for opposite halves of the same conversation: the runner
`PUT`s `payload.tar` and `GET`s `log` / `results.tar` / `DONE`; the loadgen
`GET`s `payload.tar` and `PUT`s everything else.

**[verify]** Bind at the *bucket*, not the folder, so neither account can read
another bucket that happens to share the folder:

```sh
yc storage bucket add-access-binding --name "$BENCH_BUCKET" \
  --role storage.editor --service-account-id "$CI_SA_ID"

yc storage bucket add-access-binding --name "$BENCH_BUCKET" \
  --role storage.editor --service-account-id "$VM_SA_ID"
```

If bucket-scoped bindings are not available in your `yc` version, the fallback is
the folder-scoped equivalent — strictly worse, and worth a note in the runbook:

```sh
yc resource-manager folder add-access-binding "$YC_FOLDER_ID" \
  --role storage.editor --service-account-id "$CI_SA_ID"
```

`storage.editor` rather than `storage.uploader` because both sides read as well
as write. Neither gets `storage.admin`: nobody in this system needs to change a
bucket's configuration, and in particular the VM account must not be able to
delete the lifecycle rule or the bucket.

Confirm what you ended up with:

```sh
yc resource-manager folder list-access-bindings "$YC_FOLDER_ID"
yc iam service-account list-access-bindings "$VM_SA_ID"
```

---

## 3. Workload identity federation

This is the piece that replaces the static key. GitHub signs a short-lived JWT
describing the workflow run; Yandex is configured to trust that issuer, and to
map one exact subject onto `bench-ci`.

Create the federation. Note the command path is `oidc federation` — `oidc` is a
command group with `federation` beneath it, so `oidc-federation` (hyphenated) is
not a command and will fail with an unknown-command error:

```sh
yc iam workload-identity oidc federation create \
  --name github-actions \
  --description "GitHub Actions OIDC for $GH_REPO" \
  --issuer   "https://token.actions.githubusercontent.com" \
  --jwks-url "https://token.actions.githubusercontent.com/.well-known/jwks" \
  --audiences "https://github.com/zoxy-io"

export FED_ID="$(yc iam workload-identity oidc federation get --name github-actions \
  --format json | jq -r .id)"
```

Bind one subject to the CI service account:

```sh
yc iam workload-identity federated-credential create \
  --service-account-id  "$CI_SA_ID" \
  --federation-id       "$FED_ID" \
  --external-subject-id "repo:zoxy-io/benchmark:ref:refs/heads/main"
```

Two details that decide whether this works at all:

* **`--audiences` must equal the `aud` claim the workflow's ID token carries.**
  `yc-actions/yc-iam-token-fed` requests GitHub's default audience, which is the
  repository *owner* URL — `https://github.com/zoxy-io`. If the exchange comes
  back with an audience mismatch, read the `aud` claim the action actually
  requested and set `--audiences` to that. Do **not** widen it to a wildcard;
  the audience is half of what stops another repo's token being replayed here.
* **`--external-subject-id` is an exact string, not a pattern.** The value above
  matches *only* a workflow running on `refs/heads/main`. This is intentional
  (nothing but main should be able to spend cloud money) and it has a
  consequence you will hit immediately — see [§7](#7-testing-before-you-enable-the-cron).

Verify:

```sh
yc iam workload-identity federated-credential list --service-account-id "$CI_SA_ID"
```

### Fallback if the action does not work

The exchange is a plain OAuth 2.0 token exchange, so it can be done with `curl`
if the action turns out not to fit. Replace the two token
steps in the workflow with:

```sh
jwt="$(curl -fsS \
  -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https://github.com/zoxy-io" | jq -r .value)"

tok="$(curl -fsS -X POST 'https://auth.yandex.cloud/oauth/token' \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  -d 'requested_token_type=urn:ietf:params:oauth:token-type:access_token' \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:id_token' \
  -d "audience=$CI_SA_ID" \
  --data-urlencode "subject_token=$jwt" | jq -r .access_token)"

echo "::add-mask::$tok"
echo "YC_TOKEN=$tok" >> "$GITHUB_ENV"
```

**[verify]** — the endpoint and the `audience` parameter (the *service account
id*, confusingly, not the JWT audience) are from Yandex's federation docs and I
could not exercise them. `$ACTIONS_ID_TOKEN_REQUEST_*` require
`permissions: id-token: write`, which the workflow already sets.

---

## 4. The Object Storage bucket

```sh
yc storage bucket create \
  --name "$BENCH_BUCKET" \
  --default-storage-class standard \
  --max-size 107374182400          # 100 GiB; a run is ~tens of MiB
```

The bucket is the *only* channel in or out of the fleet — the VMs have no public
address and no inbound rule — so its layout is part of the contract
(`bench/CONTRACT.md`):

```
s3://$BENCH_BUCKET/runs/<runid>/
  payload.tar   uploaded by the runner before apply
  boot-ok.<role>
  log           re-uploaded by the loadgen every ~30s
  results.tar
  DONE | FAILED written last
```

### No static access keys

There is nothing to configure here — just do not create any (§1). Both sides
authenticate with `Authorization: Bearer <IAM token>`, which Yandex Object
Storage accepts directly, so there is no SigV4 signing and no access key to
leak. If your organisation can enforce this centrally
(organization-manager → security policy → forbid static access keys), do
— **[verify]**, I could not confirm the exact policy name.

### Allow public objects, so the Discord post can link the report

`bench notify` uploads each profile's `report.html` to
`runs/<runid>/<profile>/report.html` with `x-amz-acl: public-read`, and puts the
resulting URL in the Discord embed. The report is linked rather than attached
because a Discord HTML attachment cannot be previewed — it has to be downloaded
and opened from disk, which means the artifact that took the whole night to
produce goes unread.

Only that one object per profile is made public. The raw run data, the payload
and the log stay private, and everything ages out together under the same
lifecycle rule.

For the ACL to take effect the bucket must permit public objects. Yandex
buckets default to private, and a bucket with public access blocked will make
the `PUT` fail — `bench notify` then falls back to the GitHub Pages link and
carries on, so this is a nice-to-have, not a prerequisite.

**[verify]** In the console: Object Storage → the bucket → Access → allow public
read for objects. There is no per-object toggle to set in advance; the ACL
travels with the upload.

If you would rather the bucket stay entirely private, do nothing — the Pages
link covers the latest run, and only the ability to link an *older* run's report
is lost.

### 30-day lifecycle rule on `runs/`

The bucket is transport, not an archive. The durable copy of a night's data is
the 90-day GitHub Actions artifact the workflow uploads; the bucket only has to
hold a run long enough for the runner to fetch it.

**[verify]** Write the rule to a file and apply it:

```yaml
# lifecycle.yaml
- id: expire-runs
  enabled: true
  filter:
    prefix: runs/
  expiration:
    days: 30
```

```sh
yc storage bucket update --name "$BENCH_BUCKET" \
  --lifecycle-rules-from-file lifecycle.yaml

yc storage bucket get --name "$BENCH_BUCKET" --format json | jq .lifecycle_rules
```

If that flag does not exist in your `yc`, set the rule in the console
(Object Storage → the bucket → Lifecycle → add rule, prefix `runs/`, delete
objects after 30 days). Do **not** reach for `aws s3api put-bucket-lifecycle-configuration`
— that needs a static access key, which is exactly what this setup does not have.

Note the asymmetry on purpose: **bucket 30 days, Actions artifact 90 days.** If
you ever need to reproduce an old run, the artifact is the source of truth;
`runs/<runid>/` will be long gone.

---

## 5. GitHub repo variables and secrets

Repository **variables** (Settings → Secrets and variables → Actions →
Variables). These are identifiers, not credentials — they appear in the workflow
log as `-var` arguments and that is fine:

| Variable | Value | Used for |
|---|---|---|
| `YC_CLOUD_ID` | `$YC_CLOUD_ID` | provider config |
| `YC_FOLDER_ID` | `$YC_FOLDER_ID` | provider config, and `bench sweep`'s instance enumeration |
| `YC_CI_SA_ID` | `$CI_SA_ID` | the OIDC exchange target |
| `YC_VM_SA_ID` | `$VM_SA_ID` | `-var service_account_id=` — the identity attached to each VM |
| `BENCH_BUCKET` | `$BENCH_BUCKET` | payload upload, result polling |

Repository **secrets**:

| Secret | Value |
|---|---|
| `DISCORD_WEBHOOK` | the channel webhook `bench notify` posts to |

`DISCORD_WEBHOOK` is optional. Without it the workflow still runs and
`bench notify` is invoked with `--dry-run`, so the post is rendered and validated
but not sent. It is never passed to a VM (`bench/CONTRACT.md`).

There is **no** `YC_SA_KEY`, `YC_TOKEN` or `AWS_*` secret, and there should never
be one.

```sh
gh variable set YC_CLOUD_ID  --repo "$GH_REPO" --body "$YC_CLOUD_ID"
gh variable set YC_FOLDER_ID --repo "$GH_REPO" --body "$YC_FOLDER_ID"
gh variable set YC_CI_SA_ID  --repo "$GH_REPO" --body "$CI_SA_ID"
gh variable set YC_VM_SA_ID  --repo "$GH_REPO" --body "$VM_SA_ID"
gh variable set BENCH_BUCKET --repo "$GH_REPO" --body "$BENCH_BUCKET"
gh secret   set DISCORD_WEBHOOK --repo "$GH_REPO"     # reads from stdin
```

---

## 6. GitHub Pages

Settings → Pages → **Build and deployment → Source: GitHub Actions**. Nothing
else; there is no `gh-pages` branch and the workflow publishes an artifact rather
than pushing anything.

If the `github-pages` environment has deployment branch restrictions (it is
created with "selected branches: main" by default in some orgs), a
`workflow_dispatch` run from a feature branch will have its `deploy` job blocked.
That is harmless — the `deploy` job is `continue-on-error: true` precisely so a
Pages problem cannot turn a good benchmark red — but it does mean you will not
see the site until you are running from `main`.

---

## 7. Testing before you enable the cron

The `schedule:` trigger in `.github/workflows/nightly.yml` is **enabled** —
nightly at 00:00 UTC. If you are setting this up fresh, comment it out until the
sequence below is clean; an unattended cron is a poor place to discover a broken
credential.

### Merge to `main` first — you have no choice, and it is also the easy path

Two constraints point the same way:

* **GitHub only offers "Run workflow" for a `workflow_dispatch` workflow that
  exists on the DEFAULT branch.** While `nightly.yml` lives only on a feature
  branch, the button does not appear at all and there is nothing to click.
* **The federated credential is bound to
  `repo:zoxy-io/benchmark:ref:refs/heads/main`**, so a dispatch from any other
  branch fails the `sub` check at the token exchange — the *first* cloud
  interaction, so it fails cheaply, before anything is created, but it fails.

Merging is safe: the `schedule:` trigger is commented out, so landing the
workflow on `main` starts nothing. Merge, then dispatch from `main`, and both
constraints are satisfied at once with no temporary credential.

If you really must run from a branch after the workflow is on `main` (say, to
iterate on the driver), add a second federated credential for it and **delete it
when you are done** — it is a standing grant to spend cloud money from an
unreviewed branch:

```sh
yc iam workload-identity federated-credential create \
  --service-account-id "$CI_SA_ID" --federation-id "$FED_ID" \
  --external-subject-id "repo:zoxy-io/benchmark:ref:refs/heads/nightly-bench"
# ... test, then: ...
yc iam workload-identity federated-credential list --service-account-id "$CI_SA_ID"
yc iam workload-identity federated-credential delete <credential-id>
```

### Smoke run — smallest useful shape

One profile, two proxies. `direct` calibrates the origin and `zoxy` is the one
proxy whose image is built from source, so this exercises the slow path without
paying for the full matrix (~15 minutes rather than ~70).

```sh
gh workflow run nightly.yml --repo "$GH_REPO" --ref main \
  -f profiles=c1k -f proxies=direct,zoxy

gh run watch --repo "$GH_REPO"
```

Check, in this order:

1. **The token exchange succeeded.** If not, stop — nothing has been created,
   and the problem is §3.
2. **`payload.tar` landed**, and each host wrote its marker:
   ```sh
   yc storage s3api list-objects --bucket "$BENCH_BUCKET" --prefix "runs/" # [verify]
   ```
   Expect `payload.tar`, `boot-ok.loadgen`, `boot-ok.proxy`, `boot-ok.backend`,
   then `log`, `results.tar`, `DONE`. A missing `boot-ok.<role>` names the host
   that failed to boot; the serial console (`serial-port-enable`) is the only
   other way in.
3. **No address in the log.** Search the raw log for a dotted quad. `tofu`'s
   diff is scrubbed by the workflow and `tofu output` is `sensitive`, but this is
   the check that keeps it true — the log is public.
4. **The fleet is gone:**
   ```sh
   yc compute instance list --folder-id "$YC_FOLDER_ID"
   yc vpc network list      --folder-id "$YC_FOLDER_ID"
   ```
   Both empty. If not, `bench sweep`'s backstop did not fire either — that is a
   blocker, not a nit.
5. **The artifact exists** (`bench-<runid>`, 90-day retention) and contains
   `results/<runid>/c1k/`.
6. **Pages published**, if you ran from `main`.
7. **Discord got one embed per profile**, with no address in it.

### Full run

```sh
gh workflow run nightly.yml --repo "$GH_REPO" --ref main   # defaults: c1k,c10k x 4 proxies
```

Expect roughly: 4 min boot, 5-20 min of cold docker builds, then
2 profiles x 4 proxies x ~350 s ≈ 47 min. If it approaches the 150-minute job
timeout, cut the proxy list rather than raising the timeout.

### Then enable the cron

Uncomment the two `schedule:` lines and merge. `00:00 UTC` is a suggestion, not a
guarantee — GitHub's scheduler runs cron triggers late under load, sometimes by
tens of minutes. Nothing here depends on the wall-clock time, only on the `runid`
being unique, which a UTC timestamp is.

---

## 8. Things that will bite you

**`bench sweep` deletes by label, and the label is not run-specific.** It removes
every instance in `YC_FOLDER_ID` labelled `bench=nightly` — and `cloud/main.tf`
puts that label on *every* fleet it creates, including one you brought up by hand
with `make cloud-up`. The workflow sweeps before it applies and again if
`tofu destroy` fails. **Do not run a manual fleet in the CI folder**; use a
separate folder for laptop-driven runs, or accept that the nightly will delete it
out from under you.

**The IAM token expires before a long run does.** Federated tokens are
short-lived and the job is allowed 150 minutes. The workflow re-mints the token
immediately before `tofu destroy` for exactly this reason. If you restructure the
teardown, keep that step — a teardown that 401s leaves three VMs running until
someone notices.

**Cancelling a run is not free.** `concurrency.cancel-in-progress` is `false` on
purpose. A cancellation still runs the `if: always()` teardown steps, but it
races the runner's grace period; the label sweep on the *next* run is what
actually guarantees cleanup. If you cancel, check the folder.

**Terraform state is ephemeral by design.** It lives in the runner workspace and
dies with the job. There is no remote backend and there should not be one: the
recovery mechanism is the `bench=nightly` label, not a state file. Do not add a
backend to `cloud/versions.tf` "for safety" — a shared state file between
concurrent runs is a new failure mode, not a mitigation.

**The trend chart's history lives in the published site.** `actions/deploy-pages`
replaces the site wholesale, so the workflow downloads
`https://<owner>.github.io/<repo>/history.ndjson` before building the new one and
feeds it back through `bench index --history`. Two consequences: the first run
has no trend (expected), and **if you put a custom domain on Pages, update that
URL in the "Fetch the published history" step** or the trend silently restarts
from one night every night. Nothing else breaks — it is a `curl ... || true`.

**Quota failures look like benchmark failures.** An orphaned fleet holds 10
vCPUs, and the next run's `apply` will fail on quota rather than saying
"something from last night is still up". If `apply` fails, list instances before
debugging anything else.
