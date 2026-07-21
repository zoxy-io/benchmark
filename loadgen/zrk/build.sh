#!/usr/bin/env sh
# Fetch the zrk load generator (github.com/zoxy-io/zrk) into ./zrk from a PINNED
# release. zrk ships statically-linked Linux binaries, so the same file runs in
# any container (the driver runs it in python:3-alpine) — no zig / build
# toolchain, no source clone. This replaces the old clone+cross-compile.
#
# Pinned to a release VERSION (ZRK_VERSION); bump it deliberately. The tarball
# is checksum-verified against the release's SHA256SUMS.txt before install.
set -eu

ZRK_REPO=${ZRK_REPO:-zoxy-io/zrk}
ZRK_VERSION=${ZRK_VERSION:-0.4.1}
ZRK_ARCH=${ZRK_ARCH:-x86_64-linux}    # static binary: runs in alpine and glibc alike

DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$DIR/zrk"
STAMP="$DIR/.built-ref"

asset="zrk-${ZRK_VERSION}-${ZRK_ARCH}.tar.gz"
base="https://github.com/${ZRK_REPO}/releases/download/v${ZRK_VERSION}"
want="${ZRK_VERSION}-${ZRK_ARCH}"

# Skip if we already have this exact release.
if [ -x "$BIN" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$want" ]; then
    echo "zrk: $BIN already at $want"
    exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "zrk/build.sh: curl not found" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then SHACHECK="sha256sum -c -"
elif command -v shasum   >/dev/null 2>&1; then SHACHECK="shasum -a 256 -c -"
else echo "zrk/build.sh: need sha256sum or shasum" >&2; exit 1; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "zrk: fetching $asset from $ZRK_REPO v$ZRK_VERSION"
curl -fsSL "$base/$asset"          -o "$tmp/$asset"
curl -fsSL "$base/SHA256SUMS.txt"  -o "$tmp/SHA256SUMS.txt"

# Verify the checksum (fail loudly on mismatch — a truncated/tampered download
# must never silently become the load generator).
( cd "$tmp" && grep -F "$asset" SHA256SUMS.txt | $SHACHECK ) \
    || { echo "zrk/build.sh: checksum verification FAILED for $asset" >&2; exit 1; }

tar xzf "$tmp/$asset" -C "$tmp"
install -m 0755 "$tmp/zrk" "$BIN"
printf '%s' "$want" > "$STAMP"
echo "zrk: installed $BIN ($asset, $("$BIN" --version 2>/dev/null || echo '?'))"
