# Self-signed TLS fixture baked into the image, so every host presents the same
# cert/key. Used by the proxies' :8443 listeners and by the backend if you ever
# flip on upstream re-encryption. This is a throwaway benchmark cert — never a
# real one. Regenerate with `openssl` in the devShell if you want a fresh SAN.
{ config, lib, pkgs, ... }:

let
  tls = pkgs.runCommand "bench-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout $out/key.pem -out $out/cert.pem -days 3650 \
      -subj "/CN=bench.local" \
      -addext "subjectAltName=DNS:bench.local,DNS:localhost,IP:127.0.0.1"
    # haproxy wants cert+key in one file for `bind ... crt`
    cat $out/cert.pem $out/key.pem > $out/bundle.pem
  '';
in
{
  environment.etc."bench/tls/cert.pem".source = "${tls}/cert.pem";
  environment.etc."bench/tls/key.pem" = {
    source = "${tls}/key.pem";
    mode = "0640";
    group = "proxy";
  };
  environment.etc."bench/tls/bundle.pem" = {
    source = "${tls}/bundle.pem";
    mode = "0640";
    group = "proxy";
  };
}
