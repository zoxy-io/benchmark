# Internal addresses, for debugging and laptop runs. sensitive: no address may
# reach the public CI log (bench/CONTRACT.md, redact.assertNoIps).
output "inventory" {
  sensitive = true
  value = {
    for name, inst in yandex_compute_instance.host : name => {
      internal_ip = inst.network_interface[0].ip_address
    }
  }
}
