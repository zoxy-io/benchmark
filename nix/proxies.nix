# All five proxies-under-test, present on the image but shipped DISABLED. The
# orchestrator scp's a rendered config into /etc/<proxy>/ and `systemctl start`s
# exactly one per run, then stops it before the next. That is the whole point of
# the uniform image: between runs, only the started unit differs.
{ config, lib, pkgs, zoxyPkg, ... }:

let
  # Shared unit skeleton. wantedBy=[] means "installed, never auto-started".
  common = {
    wantedBy = lib.mkForce [ ];
    serviceConfig = {
      User = "proxy";
      Group = "proxy";
      Restart = "no";
      LimitNOFILE = 1048576;
      LimitMEMLOCK = "infinity"; # zoxy pins io_uring registered buffers at startup
      NoNewPrivileges = true;
    };
  };
in
{
  # Config dirs owned by `bench` so `scp` can drop rendered configs in place.
  systemd.tmpfiles.rules = [
    "d /etc/zoxy    0775 bench proxy -"
    "d /etc/haproxy 0775 bench proxy -"
    "d /etc/envoy   0775 bench proxy -"
    "d /etc/traefik 0775 bench proxy -"
    "d /etc/caddy   0775 bench proxy -"
  ];

  # zoxy — thread-per-core, sizes itself to the visible CPUs (SO_REUSEPORT).
  systemd.services.zoxy = lib.recursiveUpdate common {
    description = "zoxy (proxy-under-test)";
    serviceConfig.ExecStart = "${zoxyPkg}/bin/zoxy /etc/zoxy/config.json";
  };

  # haproxy — nbthread is set in the rendered config (= vCPU count).
  systemd.services.haproxy = lib.recursiveUpdate common {
    description = "haproxy (proxy-under-test)";
    serviceConfig.ExecStart = "${pkgs.haproxy}/bin/haproxy -db -f /etc/haproxy/haproxy.cfg";
  };

  # envoy — no --concurrency flag => it uses every hardware thread (the tuned
  # default we record). Add `--concurrency N` here to force a specific count.
  systemd.services.envoy = lib.recursiveUpdate common {
    description = "envoy (proxy-under-test)";
    serviceConfig.ExecStart = "${pkgs.envoy}/bin/envoy -c /etc/envoy/envoy.yaml";
  };

  # traefik — GOMAXPROCS defaults to all cores.
  systemd.services.traefik = lib.recursiveUpdate common {
    description = "traefik (proxy-under-test)";
    serviceConfig.ExecStart = "${pkgs.traefik}/bin/traefik --configFile=/etc/traefik/traefik.yml";
  };

  # caddy — GOMAXPROCS defaults to all cores. It still initialises a storage dir
  # even with admin/auto_https off, so point XDG at a writable tmp path (the
  # `proxy` system user has no home).
  systemd.services.caddy = lib.recursiveUpdate common {
    description = "caddy (proxy-under-test)";
    serviceConfig = {
      ExecStart = "${pkgs.caddy}/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile";
      Environment = [ "XDG_DATA_HOME=/tmp/caddy-data" "XDG_CONFIG_HOME=/tmp/caddy-config" ];
      RuntimeDirectory = "caddy";
    };
  };
}
