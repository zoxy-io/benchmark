# Official Envoy release binary instead of nixpkgs' from-source Bazel build.
# Two reasons: (1) the source build isn't cached at our nixpkgs pin and takes
# ~an hour + tons of RAM; (2) benchmarking the upstream release artifact is
# closer to what people actually deploy. Tetrate's archive is func-e's source
# and redirects to the envoyproxy GitHub release asset.
{ lib, stdenv, fetchurl, autoPatchelfHook, zlib }:

stdenv.mkDerivation rec {
  pname = "envoy-bin";
  version = "1.36.5"; # keep in sync with the version nixpkgs would have built

  src = fetchurl {
    url = "https://archive.tetratelabs.io/envoy/download/v${version}/envoy-v${version}-linux-amd64.tar.xz";
    hash = "sha256-hJCOkSu2xlB/0Syh4ks20kzTyMLYYywvceQuXsNqxms=";
  };

  # foreign glibc binary -> patch its interpreter + rpath onto the nix runtime
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ (lib.getLib stdenv.cc.cc) zlib ];

  sourceRoot = "."; # extract at top so the */bin/envoy glob below works
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 */bin/envoy $out/bin/envoy
    runHook postInstall
  '';

  meta = {
    description = "Official Envoy release binary (envoyproxy GitHub release via tetrate archive)";
    homepage = "https://www.envoyproxy.io/";
    license = lib.licenses.asl20;
    mainProgram = "envoy";
    platforms = [ "x86_64-linux" ];
  };
}
