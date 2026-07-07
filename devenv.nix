{ pkgs, ... }:

{
  # The project's .env is sourced by scripts/*.sh and auto-loaded by docker
  # compose, and run-all.sh manages .env-vs-CLI-override precedence itself —
  # so we deliberately do NOT pre-load it into the shell (just quiet the hint).
  dotenv.disableHint = true;

  # Toolchain the Makefile and scripts/ shell out to. Docker itself is left to
  # the host (it needs a running daemon); everything else is pinned here so a
  # fresh checkout can `make up` / `make bench` / `make report` without manual
  # installs.
  packages = [
    pkgs.gnumake      # make — the entrypoint for every workflow
    pkgs.jq           # scripts/*.sh JSON wrangling
    pkgs.k6           # k6/ramp.js load generator
    pkgs.opentofu     # `tofu` — cloud/ terraform (Makefile TF ?= tofu)
    pkgs.rsync        # scripts/cloud-run.sh fleet sync
    pkgs.openssh      # ssh/scp to the cloud fleet
    pkgs.curl         # health checks in scripts/*.sh
    pkgs.python3      # report/report.py (stdlib only)
  ];

  enterShell = ''
    echo "proxy-bench dev shell — run 'make help' for the workflow. (docker comes from the host)"
  '';
}
