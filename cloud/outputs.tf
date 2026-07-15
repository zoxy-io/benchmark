# scripts/zrk-bench.sh consumes this: tofu -chdir=cloud output -json inventory
output "inventory" {
  value = {
    for name, inst in yandex_compute_instance.host : name => {
      internal_ip = inst.network_interface[0].ip_address
      external_ip = inst.network_interface[0].nat_ip_address
    }
  }
}

output "grafana_url" {
  # monitoring lives on the loadgen (fleet) or the megabox (single-VM mode)
  value = "http://${try(yandex_compute_instance.host["loadgen"].network_interface[0].nat_ip_address, yandex_compute_instance.host["megabox"].network_interface[0].nat_ip_address)}:3000"
}
