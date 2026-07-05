{ pkgs, ... }:
# `devenv shell` drops you into the toolchain; the Makefile targets are mirrored
# as scripts so you can run them by name (no `make` needed):
#
#   image   build the NixOS qcow2 and push it to Yandex Object Storage
#   up      tofu apply: VPC + loadgen/proxy/backend/control VMs
#   bench   run the matrix against each proxy (pass args, e.g. bench --proxies "zoxy haproxy")
#   report  render tables + plots from results/latest
#   down    tofu destroy
#   fmt     format tofu + nix
{
  packages = with pkgs; [
    opentofu # `tofu` — free Terraform
    k6 # open-loop, constant-arrival-rate load generator (H1 + H2)
    wrk2 # HTTP/1.1 peak cross-check (CO-corrected)
    prometheus # promtool + local Prometheus
    awscli2 # push the qcow2 to Yandex Object Storage (S3-compatible)
    jq
    yq-go
    openssl
    gnumake # so the existing `make` targets work too
    (python3.withPackages (ps: with ps; [ matplotlib pandas ]))
  ];

  # The image itself builds through the flake (nixos-generators lives there):
  #   nix build .#packages.x86_64-linux.image
  scripts.image.exec = "./scripts/build-image.sh";

  scripts.up.exec = ''
    tofu -chdir=terraform init -input=false
    tofu -chdir=terraform apply -auto-approve
    tofu -chdir=terraform output -json > terraform/inventory.json
    echo "fleet up — inventory written to terraform/inventory.json"
  '';

  scripts.bench.exec = ''./scripts/run.sh "$@"'';
  scripts.report.exec = ''./scripts/report.py "''${1:-results/latest}"'';
  scripts.down.exec = ''tofu -chdir=terraform destroy -auto-approve'';
  scripts.fmt.exec = ''
    tofu -chdir=terraform fmt
    nix fmt 2>/dev/null || true
  '';

  enterShell = ''
    echo "zoxy-benchmark — commands: image · up · bench · report · down · fmt"
    echo "typical run: image → up → bench → report → down"
  '';
}
