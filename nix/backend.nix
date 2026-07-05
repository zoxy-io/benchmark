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
    appendHttpConfig = ''
      access_log off;
      keepalive_requests 100000000;   # don't GOAWAY mid-run
      keepalive_timeout 3600s;
      sendfile on;
      tcp_nopush on;
    '';
    virtualHosts."_" = {
      default = true;
      listen = [ { addr = "0.0.0.0"; port = 9000; } ];
      root = "${bodies}";
      locations."/".extraConfig = ''
        default_type application/octet-stream;
        try_files $uri $uri/ =404;
      '';
    };
  };
}
