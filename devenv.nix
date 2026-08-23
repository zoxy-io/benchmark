{ pkgs, ... }:

{
  # Nothing here reads a .env any more: the ramp parameters are compiled into
  # bench/src/profile.zig, and the shell scripts that used to source one were
  # deleted with the bash driver (750f679). The hint is quieted rather than the
  # file being honoured.
  dotenv.disableHint = true;

  # Toolchain the Makefile shells out to. Docker itself is left to the host (it
  # needs a running daemon); everything else is pinned here so a fresh checkout
  # can `make build` / `make test` / `make report` without manual installs.
  packages = [
    pkgs.gnumake      # make — the entrypoint for every workflow
    pkgs.opentofu     # `tofu` — cloud/ terraform (Makefile TF ?= tofu)
    pkgs.openssh      # ssh/scp to the cloud fleet
    pkgs.curl         # poking at a proxy by hand behind `make up`
    pkgs.zig_0_16     # bench cross-compiles to a static
                      # musl binary every run (it embeds zrk's runner.run as a
                      # library, see its main.zig); pin the exact attr, not
                      # the bare `zig` alias — needs zig >= 0.16
    pkgs.cmake        # proxies/pingora: flate2's zlib-ng feature vendors and
                      # cmake-builds zlib-ng, even with no TLS feature enabled
    pkgs.yandex-cloud # `yc` — for getting ONTO a fleet host when a run wedges.
                      # The VMs have no public address, so `yc compute ssh`
                      # (which goes via the API) is the only way in; the nightly
                      # itself never uses this, it authenticates with an IAM
                      # token from OIDC and drives everything over the API.
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
