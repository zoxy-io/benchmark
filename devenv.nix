{ pkgs, ... }:

{
  # The project's .env is sourced by scripts/*.sh and auto-loaded by docker
  # compose, and zrk-bench.sh manages .env-vs-CLI-override precedence itself —
  # so we deliberately do NOT pre-load it into the shell (just quiet the hint).
  dotenv.disableHint = true;

  # Toolchain the Makefile and scripts/ shell out to. Docker itself is left to
  # the host (it needs a running daemon); everything else is pinned here so a
  # fresh checkout can `make cloud-bench` / `make report` without manual installs.
  packages = [
    pkgs.gnumake      # make — the entrypoint for every workflow
    pkgs.jq           # scripts/*.sh JSON wrangling
    pkgs.opentofu     # `tofu` — cloud/ terraform (Makefile TF ?= tofu)
    pkgs.rsync        # scripts/zrk-bench.sh fleet sync
    pkgs.openssh      # ssh/scp to the cloud fleet
    pkgs.curl         # health checks in scripts/*.sh
    pkgs.python3      # report/report.py (stdlib only)
    pkgs.zig_0_16     # loadgen/zrk-runner/build.sh cross-compiles to a static
                      # musl binary every run (it embeds zrk's runner.run as a
                      # library, see its main.zig); pin the exact attr, not
                      # the bare `zig` alias — needs zig >= 0.16
    pkgs.cmake        # proxies/pingora: flate2's zlib-ng feature vendors and
                      # cmake-builds zlib-ng, even with no TLS feature enabled
  ];

  # cargo/rustc for iterating on proxies/pingora locally without a Docker
  # build — nixpkgs' rustc is plenty for a TLS-free (default-features=[])
  # pingora build; the Dockerfile (pinned rust:1.85-bookworm) stays the
  # authoritative build for actual benchmark runs.
  languages.rust.enable = true;

  enterShell = ''
    echo "proxy-bench dev shell — run 'make help' for the workflow. (docker comes from the host)"
  '';
}
