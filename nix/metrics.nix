# Prometheus, present on every image but shipped DISABLED — the orchestrator
# starts it only on the `control` host after scp'ing a fleet-specific config.
# Runtime config (not Nix-baked) so targets can come from the terraform output,
# and the remote-write receiver lets the k6 generators stream native histograms
# here for cross-host latency aggregation.
{ config, lib, pkgs, ... }:

{
  users.groups.prom = { };
  users.users.prom = {
    isSystemUser = true;
    group = "prom";
  };

  systemd.tmpfiles.rules = [
    "d /etc/prometheus   0775 bench prom -"
    "d /var/lib/bench-prom 0750 prom prom -"
  ];

  systemd.services.bench-prometheus = {
    description = "Prometheus (control node)";
    wantedBy = lib.mkForce [ ];
    serviceConfig = {
      User = "prom";
      Group = "prom";
      Restart = "no";
      ExecStart = ''
        ${pkgs.prometheus}/bin/prometheus \
          --config.file=/etc/prometheus/prometheus.yml \
          --storage.tsdb.path=/var/lib/bench-prom \
          --web.listen-address=0.0.0.0:9090 \
          --web.enable-remote-write-receiver \
          --web.enable-admin-api'';
    };
  };
}
