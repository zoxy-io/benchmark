# Common configuration for EVERY host in the fleet. One image serves all four
# roles (loadgen / proxy / backend / control); the role only decides which
# services the orchestrator actually drives, not what's installed. Keeping the
# image uniform is what makes "only the proxy binary changes" literally true.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./proxies.nix # all five proxy units, shipped DISABLED
    ./backend.nix # nginx origin on :9000
    ./tls.nix # self-signed fixture at /etc/bench/tls
    ./metrics.nix # Prometheus for the control node, shipped DISABLED
  ];

  system.stateVersion = "24.11";

  # Use the official Envoy release binary rather than nixpkgs' from-source Bazel
  # build (uncached at our pin: ~1h + lots of RAM, and the release artifact is
  # what people actually deploy). proxies.nix picks this up via pkgs.envoy.
  nixpkgs.overlays = [
    (final: _prev: { envoy = final.callPackage ./envoy.nix { }; })
  ];

  # --- cloud / boot ----------------------------------------------------------
  boot.growPartition = true;
  services.qemuGuest.enable = true;
  services.cloud-init = {
    enable = true;
    network.enable = true;
    # Yandex Cloud exposes GCE- and EC2-style metadata; let cloud-init find SSH
    # keys / hostname from whichever the VM presents. TODO(you): if key injection
    # fails on first boot, pin this to the datasource your zone actually serves.
    settings.datasource_list = [ "GCE" "Ec2" "NoCloud" "None" ];
  };
  # Single network manager: systemd-networkd. cloud-init renders networkd
  # configs, so we must NOT also let dhcpcd manage the same links — that
  # combination can drop networking on boot (= no SSH = dead fleet). useDHCP
  # here is just networkd's fallback if cloud-init doesn't configure the link.
  networking.useNetworkd = true;
  networking.useDHCP = lib.mkForce true;

  # --- access ----------------------------------------------------------------
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";
  users.users.bench = {
    isNormalUser = true;
    extraGroups = [ "wheel" "proxy" ];
  };
  security.sudo.wheelNeedsPassword = false;

  # unprivileged account the proxies-under-test run as
  users.groups.proxy = { };
  users.users.proxy = {
    isSystemUser = true;
    group = "proxy";
  };

  # --- benchmark isolation ---------------------------------------------------
  # No host firewall: nftables + conntrack would be a hidden, per-proxy-run
  # variable on the hot path. The fleet lives in an isolated VPC; gate external
  # access with Yandex security groups at the network layer instead.
  networking.firewall.enable = false;

  # --- host tuning, applied identically on every role ------------------------
  boot.kernel.sysctl = {
    "net.core.somaxconn" = 65535;
    "net.core.netdev_max_backlog" = 250000;
    "net.ipv4.tcp_max_syn_backlog" = 65535;
    "net.ipv4.ip_local_port_range" = "1024 65535";
    "net.ipv4.tcp_tw_reuse" = 1;
    "net.ipv4.tcp_fin_timeout" = 10;
    "net.ipv4.tcp_slow_start_after_idle" = 0;
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "fs.file-max" = 2000000;
    "fs.nr_open" = 2000000;
  };
  security.pam.loginLimits = [
    { domain = "*"; type = "-"; item = "nofile"; value = "1048576"; }
  ];

  # --- metrics: node_exporter on every host ----------------------------------
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "systemd" "processes" "netdev" "meminfo" "cpu" "textfile" ];
    extraFlags = [ "--collector.textfile.directory=/var/lib/node_exporter/textfile" ];
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/node_exporter/textfile 0755 root root -"
  ];

  # k6 + wrk2 live on every image (harmless off the loadgen role); the
  # orchestrator scp's loadgen/*.sh + scenario.js and drives them over SSH.
  environment.systemPackages = with pkgs; [ curl htop jq k6 wrk2 ];
}
