{
  description = "Reproducible multi-host benchmark: zoxy vs haproxy/envoy/traefik/caddy on Yandex Cloud";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # zoxy is packaged upstream: zoxy-io/zoxy exposes packages.default (a
    # hermetic Zig build — the vendored OpenSSL source is a fixed-output
    # derivation, built offline via `zig build --system`).
    zoxy = {
      url = "github:zoxy-io/zoxy";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, nixos-generators, zoxy, ... }@inputs:
    let
      # The fleet is Linux/x86_64; the devShell also works on darwin/aarch64.
      imageSystem = "x86_64-linux";
      shellSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forShells = f: nixpkgs.lib.genAttrs shellSystems (system: f system (import nixpkgs { inherit system; }));

      # zoxy under test. Default = the upstream build (ReleaseSafe, matching
      # TigerStyle / TigerBeetle's ship-ReleaseSafe stance). To benchmark a
      # ReleaseFast build instead, use the overrideAttrs form below.
      zoxyPkg = zoxy.packages.${imageSystem}.default;
      # zoxyPkg = zoxy.packages.${imageSystem}.default.overrideAttrs (o: {
      #   buildPhase = builtins.replaceStrings [ "ReleaseSafe" ] [ "ReleaseFast" ] o.buildPhase;
      # });
    in
    {
      # One image, every proxy, tuning baked in. `make image` builds this.
      packages.${imageSystem} = {
        zoxy = zoxyPkg;
        image = nixos-generators.nixosGenerate {
          system = imageSystem;
          format = "qcow"; # qcow2 — Yandex Cloud accepts it as a custom image
          modules = [ ./nix/host.nix ];
          specialArgs = { inherit zoxyPkg; };
        };
      };

      # The host config, reusable outside image generation (e.g. `nixos-rebuild`
      # against a running VM while iterating).
      nixosConfigurations.bench-host = nixpkgs.lib.nixosSystem {
        system = imageSystem;
        modules = [ ./nix/host.nix ];
        specialArgs = { inherit zoxyPkg; };
      };

      devShells = forShells (system: p: {
        default = p.mkShell {
          packages = with p; [
            opentofu # free Terraform; `tofu` CLI. Swap for `terraform` if you prefer.
            k6 # open-loop, constant-arrival-rate load generator (H1 + H2)
            wrk2 # HAProxy-grade H1 peak cross-check (Gil Tene, CO-corrected)
            prometheus # promtool + a local Prometheus for the control node
            awscli2 # push the qcow2 to Yandex Object Storage (S3-compatible)
            jq
            yq-go
            gnumake # the Makefile targets
            openssl # regenerate the TLS fixture if needed
            (python3.withPackages (ps: with ps; [ matplotlib pandas ]))
          ];
          # The image builds via `nix build .#image` (nixos-generators is a flake
          # input, not a shell tool), so nothing generator-specific is needed here.
        };
      });
    };
}
