# Six Ubuntu 24.04 hosts (loadgen, proxy, four backends) in one zone and subnet,
# with no public addresses. CI creates the fleet, the loadgen runs the suite and
# ships results via Object Storage, CI destroys it. `bench sweep` cleans up
# orphans of cancelled runs by the bench=nightly label. No custom images:
# cloud-init installs pinned docker and unpacks payload.tar.

resource "yandex_vpc_network" "bench" {
  name = "bench-${var.runid}"
}

# Outbound-only internet (apt, Docker Hub, GitHub, Object Storage).
# shared_egress_gateway takes no arguments.
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

  # Also orders the apply, so egress is routable before the first apt-get.
  route_table_id = yandex_vpc_route_table.bench.id
}

resource "yandex_vpc_security_group" "bench" {
  name       = "bench-${var.runid}"
  network_id = yandex_vpc_network.bench.id

  # Fleet-internal only: loadgen ssh to peers, cAdvisor scrapes on :8081.
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

# Per-run ssh identity for the loadgen; never leaves terraform state and the
# loadgen's cloud-init.
resource "tls_private_key" "fleet" {
  algorithm = "ED25519"
}

# One fleet-wide ssh host key, so the loadgen's known_hosts is correct before
# peers boot. Per-host keys buy nothing within one apply's trust domain.
resource "tls_private_key" "host" {
  algorithm = "ED25519"
}

locals {
  subnet_cidr  = "10.10.0.0/24"
  ssh_key_path = "/home/ubuntu/.ssh/bench_ed25519" # the contract's SSH_KEY

  # One 4-core loadgen saturates the 1-CPU proxy well under its own limit.
  #
  # Addresses are pinned: the loadgen's cloud-init needs peer IPs, and reading
  # them off its for_each siblings is a self-reference. Yandex reserves the
  # first addresses of a subnet, hence .11.
  #
  # Four 2-core backends (sizing: variables.tf). The count also lives in the
  # compose.yaml services and proxies/*/ endpoint lists; change all three.
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

  # Ordered, so BACKEND_IPS[n] is always backendN.
  backend_ips = [for name in local.backend_names : local.backends[name].ip]

  known_hosts = join("\n", [
    for h in concat(["proxy"], local.backend_names) :
    "${local.hosts[h].ip} ${trimspace(tls_private_key.host.public_key_openssh)}"
  ])
}

resource "yandex_compute_instance" "host" {
  for_each = local.hosts

  # runid in the name marks orphans; hostname stays the bare role for logs.
  name        = "${each.key}-${var.runid}"
  hostname    = each.key
  platform_id = var.platform_id
  zone        = var.zone

  # bench=nightly is the recovery path: `bench sweep` deletes by this label
  # (bench/CONTRACT.md).
  labels = {
    bench = "nightly"
    runid = var.runid
    role  = each.key
  }

  # Metadata-service IAM tokens instead of a key on the host.
  service_account_id = var.service_account_id

  # Resize in place instead of destroy+recreate (matters for laptop fleets).
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
    # No public address: egress via the gateway, no inbound path.
    nat                = false
    security_group_ids = [yandex_vpc_security_group.bench.id]
  }

  # CONTRACT.md's "gce-http-token metadata key" is this block, not a
  # `metadata` key. The AWS-flavoured options keep API defaults.
  metadata_options {
    gce_http_endpoint = 1
    gce_http_token    = 1
  }

  metadata = {
    ssh-keys = "ubuntu:${trimspace(tls_private_key.fleet.public_key_openssh)}"

    # One template for every role. Secrets go only to the loadgen, so they are
    # absent from the peers' user-data.
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

    # The only way to inspect a host that never wrote boot-ok.
    serial-port-enable = "1"
  }
}
