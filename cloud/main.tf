# Three stock Ubuntu 24.04 hosts, one zone, one subnet. No custom images:
# cloud-init installs a PINNED docker-ce + compose plugin (so local and cloud
# run the same compose implementation) and applies the sysctl tuning. The
# benchmark itself is rsynced and driven by scripts/cloud-run.sh — editing a
# config never means rebuilding an image.

resource "yandex_vpc_network" "bench" {
  name = "proxy-bench"
}

resource "yandex_vpc_subnet" "bench" {
  name           = "proxy-bench"
  zone           = var.zone
  network_id     = yandex_vpc_network.bench.id
  v4_cidr_blocks = ["10.10.0.0/24"]
}

resource "yandex_vpc_security_group" "bench" {
  name       = "proxy-bench"
  network_id = yandex_vpc_network.bench.id

  ingress {
    protocol       = "TCP"
    description    = "ssh"
    v4_cidr_blocks = [var.allowed_cidr]
    port           = 22
  }
  ingress {
    protocol       = "TCP"
    description    = "grafana (loadgen host)"
    v4_cidr_blocks = [var.allowed_cidr]
    port           = 3000
  }
  ingress {
    protocol       = "TCP"
    description    = "prometheus (loadgen host; report.py queries it)"
    v4_cidr_blocks = [var.allowed_cidr]
    port           = 9090
  }
  ingress {
    protocol       = "ANY"
    description    = "all intra-fleet"
    v4_cidr_blocks = ["10.10.0.0/24"]
    from_port      = 0
    to_port        = 65535
  }
  egress {
    protocol       = "ANY"
    description    = "all egress (apt, docker hub, github)"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2404-lts-oslogin"
}

locals {
  # One loadgen: the open-loop vegeta-ramp generator saturates any proxy from a
  # single 16-core box at ~25% CPU (it hits the proxy's concurrency-collapse wall
  # long before its own limit), so a second loadgen added no reach and actually
  # pushed the proxy into collapse. loadgen also hosts prometheus/grafana.
  hosts = {
    loadgen = { cores = var.loadgen_cores, memory = var.loadgen_memory, role = "loadgen" }
    proxy   = { cores = var.proxy_cores, memory = var.proxy_memory, role = "proxy" }
    backend = { cores = var.backend_cores, memory = var.backend_memory, role = "backend" }
  }
}

resource "yandex_compute_instance" "host" {
  for_each = local.hosts

  name        = each.key
  hostname    = each.key
  platform_id = var.platform_id
  zone        = var.zone
  labels      = { role = each.value.role }

  # in-place stop→resize→start when cores/memory change, instead of destroy+
  # recreate — preserves the external IP (no address-quota churn) and the disk.
  allow_stopping_for_update = true

  resources {
    cores         = each.value.cores
    memory        = each.value.memory
    core_fraction = 100 # guaranteed vCPU — non-negotiable for a benchmark
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = var.disk_size
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.bench.id
    nat                = true # direct ssh to every role; egress for apt/docker
    security_group_ids = [yandex_vpc_security_group.bench.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      ssh_public_key = var.ssh_public_key
      docker_version = var.docker_version
    })
    serial-port-enable = "1"
  }
}
