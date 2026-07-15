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
    pkgs.zig_0_16     # loadgen/zrk/build.sh cross-compiles zrk to a static musl
                      # binary that the drivers ship to the loadgen (zrk needs
                      # zig 0.16; pin the exact attr, not the bare `zig` alias)
  ];

  enterShell = ''
    echo "proxy-bench dev shell — run 'make help' for the workflow. (docker comes from the host)"
  '';
}
