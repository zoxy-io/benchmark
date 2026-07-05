# The orchestrator consumes this as JSON: `tofu output -json > inventory.json`.
# Shape: { hosts: { <name>: { role, internal_ip, external_ip } }, ... }
output "inventory" {
  value = {
    hosts = {
      for name, inst in yandex_compute_instance.host : name => {
        role        = inst.labels.role
        internal_ip = inst.network_interface[0].ip_address
        external_ip = inst.network_interface[0].nat_ip_address
      }
    }
    zone   = var.zone
    subnet = "10.10.0.0/24"
  }
}

# The one public IP — SSH here; the orchestrator jumps through it for the rest.
output "control_ip" {
  value = yandex_compute_instance.host["control"].network_interface[0].nat_ip_address
}

# Proxy has no public IP now; expose its internal IP for debugging/jump.
output "proxy_internal_ip" {
  value = yandex_compute_instance.host["proxy"].network_interface[0].ip_address
}
