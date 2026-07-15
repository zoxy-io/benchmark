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
  # monitoring lives on the loadgen host
  value = "http://${yandex_compute_instance.host["loadgen"].network_interface[0].nat_ip_address}:3000"
}
