# The origin. Deliberately trivial and very fast: nginx serving byte-identical,
# fixed-size canned bodies out of the store. It must have far more headroom than
# any proxy under test — the saturation self-check (loadgen/self_check.sh) voids
# any run where a backend, not the proxy, is the bottleneck.
{ config, lib, pkgs, ... }:

let
  # Canned bodies generated once into the store, so every backend host serves
  # exactly the same payloads. Requested by the load matrix at /64 /1k /10k /100k.
  bodies = pkgs.runCommand "bench-bodies" { } ''
    mkdir -p $out
    fill() { ${pkgs.coreutils}/bin/head -c "$1" /dev/zero | ${pkgs.coreutils}/bin/tr '\0' x > "$out/$2"; }
    fill 64     64
    fill 1024   1k
    fill 10240  10k
    fill 102400 100k
    ${pkgs.coreutils}/bin/cp "$out/64" "$out/index.html"
  '';
in
{
  services.nginx = {
    enable = true;
    recommendedTlsSettings = false;
    recommendedProxySettings = false;
    # The NixOS module emits no worker_processes directive, and nginx's default
    # is ONE worker — a single-core origin whose saturation the whole-host CPU
    # self-check would never see (1 of 4 cores busy = 25% "idle" host). Use
    # every core, and raise the connection/file limits so upstream keep-alive
    # pools from an 8-core proxy never queue on the origin.
    appendConfig = ''
      worker_processes auto;
      worker_rlimit_nofile 1048576;
    '';
    eventsConfig = ''
      worker_connections 65535;
      multi_accept on;   # accept all pending connections per wakeup
    '';
    appendHttpConfig = ''
      access_log off;
      server_tokens off;
      keepalive_requests 100000000;   # don't GOAWAY mid-run
      keepalive_timeout 3600s;
      sendfile on;
      tcp_nopush on;
      tcp_nodelay on;                 # flush keep-alive responses immediately
      reset_timedout_connection on;   # RST dead clients, free their slots fast
      # The origin serves the same handful of files forever — cache their open
      # fds + metadata so requests aren't repeated open()+fstat() (denji
      # nginx-tuning: ~600 rps/instance on this alone).
      open_file_cache max=16384 inactive=3600s;
      open_file_cache_valid 3600s;
      open_file_cache_min_uses 1;
      open_file_cache_errors on;
    '';
    virtualHosts."_" = {
      default = true;
      # reuseport shards accept across workers via SO_REUSEPORT (big win when
      # clients open many connections); large backlog absorbs accept bursts.
      listen = [ { addr = "0.0.0.0"; port = 9000; extraParameters = [ "reuseport" "backlog=65535" ]; } ];
      root = "${bodies}";
      locations."/".extraConfig = ''
        default_type application/octet-stream;
        try_files $uri $uri/ =404;
      '';
    };
  };

  # worker_rlimit_nofile above needs the service's own rlimit to match.
  systemd.services.nginx.serviceConfig.LimitNOFILE = 1048576;
}
