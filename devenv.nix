{ pkgs, ... }:

{
  # The project's .env is sourced by scripts/*.sh and auto-loaded by docker
  # compose, and vegeta-bench.sh manages .env-vs-CLI-override precedence itself —
  # so we deliberately do NOT pre-load it into the shell (just quiet the hint).
  dotenv.disableHint = true;

  # Toolchain the Makefile and scripts/ shell out to. Docker itself is left to
  # the host (it needs a running daemon); everything else is pinned here so a
  # fresh checkout can `make cloud-bench` / `make report` without manual installs.
  packages = [
    pkgs.gnumake      # make — the entrypoint for every workflow
    pkgs.jq           # scripts/*.sh JSON wrangling
    pkgs.opentofu     # `tofu` — cloud/ terraform (Makefile TF ?= tofu)
    pkgs.rsync        # scripts/vegeta-bench.sh fleet sync
    pkgs.openssh      # ssh/scp to the cloud fleet
    pkgs.curl         # health checks in scripts/*.sh
    pkgs.python3      # report/report_vegeta.py (stdlib only)
    # the load generator (loadgen/vegeta-ramp) is built with the golang docker
    # image on the loadgen host by vegeta-bench.sh — no local go toolchain needed
  ];

  enterShell = ''
    echo "proxy-bench dev shell — run 'make help' for the workflow. (docker comes from the host)"
  '';
}
