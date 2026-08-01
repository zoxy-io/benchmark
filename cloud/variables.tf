variable "service_account_key_file" {
  type        = string
  default     = null
  description = <<-EOT
    Path to (or the contents of) a Yandex SA key file — `yc iam key create ...
    --output sa-key.json`. Optional, and unset in CI: the nightly workflow has
    no static key at all, it exchanges a GitHub OIDC token for a short-lived IAM
    token and exports YC_TOKEN, which the provider reads from the environment.
    Keep it for laptop-driven runs.
  EOT
}

variable "cloud_id" {
  type = string
}

variable "folder_id" {
  type = string
}

variable "runid" {
  type        = string
  description = <<-EOT
    Identifies one run everywhere it has to be identified: the
    `runs/<runid>/` object prefix, the `runid` label that `bench sweep` reads,
    and the suffix on every resource name — so a fleet orphaned by a run that
    died between apply and destroy cannot collide with, or block, the next one.
    The charset is the intersection of two namespaces: Yandex resource names
    reject the underscore that labels accept, and neither accepts uppercase.
  EOT

  validation {
    # Length caps at 40 so the longest derived name ("backend0-<runid>") stays
    # inside Yandex's 63-character limit with room to spare.
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$", var.runid))
    error_message = "runid must be 1-40 characters of [a-z0-9-], starting and ending alphanumeric."
  }
}

variable "service_account_id" {
  type        = string
  description = <<-EOT
    Service account attached to every instance. It needs write access to
    var.bench_bucket and nothing else. This is the ONLY credential path off a
    VM: with it attached, the metadata service mints IAM tokens on demand (see
    metadata_options in main.tf), so no key material for the cloud is ever
    written to a benchmark host. Terraform does not create it or its bucket
    grant — both outlive any single run.
  EOT
}

variable "bench_bucket" {
  type        = string
  description = <<-EOT
    Object Storage bucket holding `runs/<runid>/`. The runner puts payload.tar
    there before apply; the loadgen reads it back and writes log/results.tar/DONE
    to the same prefix. See bench/CONTRACT.md.
  EOT
}

variable "bench_profiles" {
  type        = string
  default     = "c1k,c10k"
  description = "BENCH_PROFILES — comma-separated, run in order, one `bench suite` per profile."
}

variable "bench_proxies" {
  type = string
  # Matches nightly.yml's own default. traefik/nginx were deleted rather than
  # parked (commands.zig's parseProxies rejects them outright); envoy came
  # back after being temporarily out of the comparison.
  default     = "direct,zoxy,haproxy,pingora,envoy"
  description = "BENCH_PROXIES — comma-separated, passed straight to `bench suite --proxies`."
}

variable "zone" {
  type        = string
  default     = "ru-central1-a"
  description = <<-EOT
    Single zone for every host — cross-zone RTT would be a hidden variable, and
    with a backend POOL it would be a per-member one: the proxy would be
    round-robining across origins at different distances, so its throughput
    would depend on which member each request happened to draw.
  EOT
}

variable "platform_id" {
  type    = string
  default = "standard-v3" # keep every role on ONE platform
}

variable "docker_version" {
  type    = string
  default = "28.0" # apt version prefix pinned by cloud-init; same compose CLI everywhere
}

variable "disk_size" {
  type    = number
  default = 30
}

variable "image_id" {
  type        = string
  default     = "fd8dcjve5vsdhbqs6nqj" # ubuntu-2404-lts-oslogin, pinned at fleet creation.
  description = <<-EOT
    Boot disk image, pinned rather than resolved live from the
    ubuntu-2404-lts-oslogin family. Yandex republishes that family
    periodically; resolving it live means an UNRELATED apply (e.g. a core-
    count bump) silently picks up a newer image, which changes
    boot_disk.image_id and forces a destroy+recreate of every host (new
    external IPs, lost disks) instead of the in-place resize
    allow_stopping_for_update is there for. Bump this deliberately.

    A nightly fleet is recreated anyway, so the destroy+recreate no longer
    hurts — but the image is still pinned, because an image that changes under
    you changes the kernel and therefore the numbers, and a benchmark that
    silently re-baselines itself overnight is worse than one that fails.
  EOT
}

# Sizing: the proxy container is capped to 1 CPU on cpuset 0 (compose.cloud.yaml)
# whatever the VM has, so core count does NOT change what the proxy under test
# gets. Spare cores buy two things instead: the OS, dockerd, sshd and cAdvisor are
# unpinned, so more of them stay off core 0, and `docker build` — which runs HERE,
# driven over ssh — gets to use them.
#
# That build is most of a nightly. The fleet is ephemeral, so there is no layer
# cache and zoxy is compiled from source every run: measured at ~13 min of a
# 37-min four-proxy run, against 5-min ramps. haproxy, a stock image, builds in 1s.
#
# CAVEAT worth re-checking after any change here: Yandex standard-v3 scales the
# NETWORK allowance with vCPU count, and that is benchmark-visible. Proxied
# traffic crosses this NIC twice (loadgen->proxy->backend and back), so at 24.9k
# rps of 1 KiB zoxy was already pushing ~408 Mbps through it. If proxy numbers
# RISE after this bump, they were NIC-limited before and the old ones were not
# measuring the proxy.
variable "proxy_cores" {
  type    = number
  default = 4
}
variable "proxy_memory" {
  type    = number
  default = 8
}
# PER BACKEND, and there are four of them (local.backend_names in main.tf) — so
# the pool is 8 cores against the 4 a single origin used to have, while each
# member is deliberately half the size. Both halves of that matter:
#
#   * Smaller members make the pool a real pool. Four origins that each dwarf
#     the 1-CPU proxy would be four ways of measuring the same thing; at 2 cores
#     a member is small enough that spreading load across them is load
#     BALANCING and not just fan-out.
#   * A bigger pool keeps the origin off the critical path. In a proxied run
#     each member takes ~1/4 of the offered load, so the pool has to be wrong by
#     4x before it can bottleneck anything.
#
# `direct` is what turns that second claim from arithmetic into a measurement.
# zrk resolves exactly one address, so it cannot fan out across the pool — it
# hits backend0 with 100% of the offered load, four times what that host sees in
# a proxied run. If the direct row clears the fastest proxy, the pool provably
# has 4x+ headroom. If it does NOT, that is the signal to raise backend_cores:
# the direct row has stopped proving anything, and every proxy number above it
# is suspect.
variable "backend_cores" {
  type    = number
  default = 2
}
variable "backend_memory" {
  type    = number
  default = 4
}
variable "loadgen_cores" {
  type    = number
  default = 4
}
variable "loadgen_memory" {
  type    = number
  default = 8
}
