# Six stock Ubuntu 24.04 hosts — loadgen, proxy, and a four-node backend pool —
# in one zone, one subnet, with NO public addresses.
#
# The fleet is ephemeral and self-driving: CI creates it, the loadgen runs the
# whole suite itself and ships the results out through Object Storage, CI
# destroys it. Nothing outside the VPC can dial in, and nothing on a host holds
# a cloud credential — the payload comes down, and the results go up, on IAM
# tokens minted by the metadata service against an attached service account.
#
# Terraform state is per-run and lives in the CI workspace, so it is NOT the
# recovery mechanism: a run cancelled between apply and destroy is cleaned up by
# `bench sweep`, which deletes by the bench=nightly label below.
#
# Still no custom images: cloud-init installs a PINNED docker-ce + compose
# plugin (so local and cloud run the same compose implementation), applies the
# sysctl and fd tuning, and unpacks payload.tar. Editing a proxy config never
# means rebuilding an image.

resource "yandex_vpc_network" "bench" {
  name = "bench-${var.runid}"
}

# Outbound-only internet. With nat = false on every interface there is no
# address anyone can dial, but the hosts still have to reach apt, Docker Hub,
# GitHub and storage.yandexcloud.net. A shared egress gateway plus a default
# route does exactly that, one way.
#
# shared_egress_gateway is the only gateway kind this provider models and it
# takes no arguments — the empty block IS the whole configuration.
resource "yandex_vpc_gateway" "egress" {
  name = "bench-egress-${var.runid}"

  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "bench" {
  name       = "bench-${var.runid}"
  network_id = yandex_vpc_network.bench.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.egress.id
  }
}

resource "yandex_vpc_subnet" "bench" {
  name           = "bench-${var.runid}"
  zone           = var.zone
  network_id     = yandex_vpc_network.bench.id
  v4_cidr_blocks = [local.subnet_cidr]

  # Attaching the table here is also what orders the apply: instances depend on
  # the subnet, the subnet on the table, the table on the gateway, so egress is
  # already routable by the time the first host runs `apt-get update`.
  route_table_id = yandex_vpc_route_table.bench.id
}

resource "yandex_vpc_security_group" "bench" {
  name       = "bench-${var.runid}"
  network_id = yandex_vpc_network.bench.id

  # No ssh, no grafana, no prometheus from outside — there is no outside any
  # more. The only ingress that still has to exist is fleet-internal: the
  # loadgen ssh'ing into its peers to bring proxies up, and scraping the proxy
  # host's cAdvisor on :8081.
  ingress {
    protocol       = "ANY"
    description    = "all intra-fleet"
    v4_cidr_blocks = [local.subnet_cidr]
    from_port      = 0
    to_port        = 65535
  }
  egress {
    protocol       = "ANY"
    description    = "all egress via the NAT gateway (apt, docker hub, github, object storage)"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# --------------------------------------------------------------- identities --

# The per-run ssh identity the loadgen uses to drive its peers. Generated here,
# handed to the loadgen through its own cloud-init, and destroyed with the
# workspace when the job ends: it never reaches Object Storage, never reaches a
# log, and there is no key on anyone's laptop that opens a benchmark fleet.
resource "tls_private_key" "fleet" {
  algorithm = "ED25519"
}

# One ssh HOST key for the whole fleet, injected via cloud-init so the loadgen
# can carry a known_hosts that is correct before the peers have even booted —
# StrictHostKeyChecking against a known key instead of trust-on-first-use.
# Per-host keys would be stricter, but the fleet is created and destroyed by one
# apply and shares one trust domain, so there is nothing left to separate.
resource "tls_private_key" "host" {
  algorithm = "ED25519"
}

locals {
  subnet_cidr  = "10.10.0.0/24"
  ssh_key_path = "/home/ubuntu/.ssh/bench_ed25519" # the contract's SSH_KEY

  # One loadgen: the open-loop zrk generator saturates a 1-CPU proxy from a
  # single 4-core box well under its own limit (it hits the proxy's
  # concurrency-collapse wall first). loadgen also hosts prometheus/grafana.
  # (Tried 6 cores 2026-07-24 to give zrk's threads more headroom — reverted:
  # loadgen's Grafana CPU% is dominated by iowait-accounting noise from
  # Prometheus's 1s scrape interval hitting the network-ssd disk, not real
  # compute pressure, so the extra cores didn't buy anything measurable.)
  #
  # Addresses are PINNED, not allocated. The loadgen's cloud-init has to carry
  # PROXY_IP/BACKEND_IPS and a known_hosts keyed by address, and it cannot read
  # those off its own for_each siblings — that is a self-reference, and
  # terraform rejects it. Yandex reserves the first four addresses of a subnet,
  # so the fleet starts at .11. Each run gets its own network, so fixed
  # addresses cannot collide across concurrent runs.
  #
  # FOUR backends, not one. A production proxy fronts a POOL and spends real
  # work choosing a member per request; one origin measured only the forwarding
  # path. Each is deliberately SMALLER than the old single box (2 cores, was 4)
  # while the pool is larger in total (8 cores, was 4), so no proxy is ever
  # waiting on the origin — see the `direct` note in variables.tf for the
  # calibration that proves it rather than assumes it.
  #
  # The count is 4 in three places that cannot read each other: here, the
  # `backend0..backend3` services in compose.yaml, and the endpoint lists in
  # proxies/*/. Changing it means changing all three — bench/src/suite.zig
  # iterates whatever it is handed, so it is the one place that does not care.
  backend_names = ["backend0", "backend1", "backend2", "backend3"]

  backends = {
    for i, name in local.backend_names : name => {
      cores  = var.backend_cores
      memory = var.backend_memory
      ip     = cidrhost(local.subnet_cidr, 13 + i)
    }
  }

  hosts = merge({
    loadgen = { cores = var.loadgen_cores, memory = var.loadgen_memory, ip = "10.10.0.11" }
    proxy   = { cores = var.proxy_cores, memory = var.proxy_memory, ip = "10.10.0.12" }
  }, local.backends)

  # Ordered, so BACKEND_IPS[0] is backend0 everywhere — `direct` calibrates
  # against that one specifically, and a map's iteration order must not decide
  # which host that is.
  backend_ips = [for name in local.backend_names : local.backends[name].ip]

  known_hosts = join("\n", [
    for h in concat(["proxy"], local.backend_names) :
    "${local.hosts[h].ip} ${trimspace(tls_private_key.host.public_key_openssh)}"
  ])
}

resource "yandex_compute_instance" "host" {
  for_each = local.hosts

  # Names carry the runid so an orphaned fleet from a cancelled run is obvious
  # in the console and cannot get in the next apply's way. The guest hostname
  # stays the bare role: the compose overlay addresses peers by IP, and role
  # names are what show up in logs.
  name        = "${each.key}-${var.runid}"
  hostname    = each.key
  platform_id = var.platform_id
  zone        = var.zone

  # bench=nightly IS the recovery path (bench/CONTRACT.md): per-run state dies
  # with the runner, so a job cancelled between apply and destroy leaves VMs
  # that nothing can `tofu destroy`. `bench sweep` deletes by this label.
  labels = {
    bench = "nightly"
    runid = var.runid
    role  = each.key
  }

  # Lets the guest ask the metadata service for an IAM token instead of holding
  # a key. Nothing else on the instance authenticates to the cloud.
  service_account_id = var.service_account_id

  # in-place stop→resize→start when cores/memory change, instead of destroy+
  # recreate — preserves the disk. Near-vestigial for a fleet that is recreated
  # nightly, but it is what keeps a laptop-driven fleet alive across a sizing edit.
  allow_stopping_for_update = true

  resources {
    cores         = each.value.cores
    memory        = each.value.memory
    core_fraction = 100 # guaranteed vCPU — non-negotiable for a benchmark
  }

  boot_disk {
    initialize_params {
      image_id = var.image_id
      size     = var.disk_size
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id  = yandex_vpc_subnet.bench.id
    ip_address = each.value.ip
    # No public address on any role. Outbound still works through the shared
    # egress gateway; inbound has no path at all, which is the point.
    nat                = false
    security_group_ids = [yandex_vpc_security_group.bench.id]
  }

  # This is what CONTRACT.md means by "the gce-http-token metadata key": the
  # GCE-flavoured metadata endpoint that serves
  # /computeMetadata/v1/instance/service-accounts/default/token. In this
  # provider it is a first-class block, not a key in `metadata` — there is no
  # such key in the schema. 1 = enabled. The AWS-flavoured pair is left
  # unspecified so the API keeps its own defaults; nothing here speaks it, and
  # turning it off would be a guess about what the image's own agents use.
  metadata_options {
    gce_http_endpoint = 1
    gce_http_token    = 1
  }

  metadata = {
    ssh-keys = "ubuntu:${trimspace(tls_private_key.fleet.public_key_openssh)}"

    # One template for every role — see the header comment in the template for
    # why. The two secrets are passed only to the role that may hold them, so
    # the private key is absent from the peers' rendered user-data, not merely
    # unused by it.
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      role                 = each.key
      docker_version       = var.docker_version
      ssh_public_key       = trimspace(tls_private_key.fleet.public_key_openssh)
      ssh_host_private_key = trimspace(tls_private_key.host.private_key_openssh)
      ssh_host_public_key  = trimspace(tls_private_key.host.public_key_openssh)
      fleet_private_key    = each.key == "loadgen" ? trimspace(tls_private_key.fleet.private_key_openssh) : ""
      known_hosts          = each.key == "loadgen" ? local.known_hosts : ""
      ssh_key_path         = local.ssh_key_path
      bench_bucket         = var.bench_bucket
      runid                = var.runid
      bench_profiles       = var.bench_profiles
      bench_proxies        = var.bench_proxies
      proxy_ip             = local.hosts["proxy"].ip
      backend_ips          = join(",", local.backend_ips)
    })

    # With no public address and no inbound rule, the serial console is the only
    # way to look at a host that failed before it could write `boot-ok`.
    serial-port-enable = "1"
  }
}
