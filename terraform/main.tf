# The fleet: one VPC + subnet in a single zone, one custom NixOS image, and the
# four roles. Every instance boots the SAME image at core_fraction=100; the role
# only decides what the orchestrator drives on it.

resource "yandex_vpc_network" "bench" {
  name = "zoxy-bench"
}

resource "yandex_vpc_subnet" "bench" {
  name           = "zoxy-bench"
  zone           = var.zone
  network_id     = yandex_vpc_network.bench.id
  v4_cidr_blocks = ["10.10.0.0/24"]
}

# Internal traffic wide open (isolated VPC); external only SSH. The host firewall
# is off by design, so this security group is the only network gate.
resource "yandex_vpc_security_group" "bench" {
  name       = "zoxy-bench"
  network_id = yandex_vpc_network.bench.id

  ingress {
    protocol       = "TCP"
    description    = "ssh"
    v4_cidr_blocks = [var.allowed_ssh_cidr]
    port           = 22
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
    description    = "all egress"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

resource "yandex_compute_image" "bench" {
  name       = "zoxy-bench-nixos"
  source_url = var.image_source_url
  # os_type left default; qcow2 boots via the image's own grub.
}

locals {
  # name => { role, cores, memory }. core_fraction is forced to 100 below.
  hosts = merge(
    {
      proxy   = { role = "proxy", cores = var.proxy_cores, memory = var.proxy_memory }
      control = { role = "control", cores = 2, memory = 4 }
    },
    { for i in range(var.loadgen_count) : "loadgen-${i}" => { role = "loadgen", cores = var.loadgen_cores, memory = var.loadgen_memory } },
    { for i in range(var.backend_count) : "backend-${i}" => { role = "backend", cores = var.backend_cores, memory = var.backend_memory } },
  )
}

resource "yandex_compute_instance" "host" {
  for_each = local.hosts

  name        = each.key
  hostname    = each.key
  platform_id = var.platform_id
  zone        = var.zone
  labels      = { role = each.value.role }

  resources {
    cores         = each.value.cores
    memory        = each.value.memory
    core_fraction = 100 # guaranteed vCPU — non-negotiable for a benchmark
  }

  boot_disk {
    initialize_params {
      image_id = yandex_compute_image.bench.id
      size     = var.disk_size
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.bench.id
    nat                = true # external IP for SSH + image/metrics pull
    security_group_ids = [yandex_vpc_security_group.bench.id]
  }

  metadata = {
    ssh-keys           = "bench:${var.ssh_public_key}"
    user-data          = templatefile("${path.module}/cloud-init.yaml.tftpl", { ssh_public_key = var.ssh_public_key })
    serial-port-enable = "1"
  }
}
