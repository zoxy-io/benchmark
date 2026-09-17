{ pkgs, ... }:

{
  # No .env is read; ramp parameters live in bench/src/profile.zig.
  dotenv.disableHint = true;

  # Docker comes from the host (it needs a running daemon).
  packages = [
    pkgs.gnumake      # make — the entrypoint for every workflow
    pkgs.opentofu     # `tofu` for cloud/
    pkgs.openssh      # ssh/scp to the cloud fleet
    pkgs.curl         # poking at a proxy by hand behind `make up`
    pkgs.zig_0_16     # bench; pin the exact attr, not the `zig` alias
    pkgs.cmake        # proxies/pingora: flate2's zlib-ng builds with cmake
    pkgs.yandex-cloud # `yc compute ssh`: the only way onto a wedged fleet host
  ];

  # cargo/rustc for iterating on proxies/pingora without Docker; the
  # Dockerfile stays the authoritative build.
  languages.rust.enable = true;

  enterShell = ''
    echo "proxy-bench dev shell — run 'make help' for the workflow. (docker comes from the host)"
  '';
}
