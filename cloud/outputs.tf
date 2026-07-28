# Internal addresses only — there are no public ones any more, and the run
# drives itself from inside the VPC, so this is a debugging aid (and what a
# laptop-driven run still reads with `tofu output -json inventory`) rather than
# something the nightly needs.
#
# sensitive because the nightly prints its apply output into a public CI log,
# and because no benchmark artifact is allowed to contain an address at all
# (bench/CONTRACT.md, redact.assertNoIps). `tofu output -json inventory` still
# emits the value when asked for it by name.
output "inventory" {
  sensitive = true
  value = {
    for name, inst in yandex_compute_instance.host : name => {
      internal_ip = inst.network_interface[0].ip_address
    }
  }
}
