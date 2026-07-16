#!/usr/bin/env sh
# Build the zrk load generator (github.com/floatdrop/zrk) into ./zrk as a STATIC
# musl binary that runs in any alpine container. Uses your local zig (the devenv
# shell provides it; needs >= 0.16) — cross-compiled to musl, no toolchain fetch.
#
# Pinned to a SHA (ZRK_REF): zrk force-pushes main, and a cached `git clone`
# would silently keep building an OLD commit. Bump ZRK_REF deliberately.
set -eu

ZRK_REPO=${ZRK_REPO:-https://github.com/floatdrop/zrk}
ZRK_REF=${ZRK_REF:-8e9b88c}                    # v0.2.1: measuring fixes; -t removed (#11)
ZIG_TARGET=${ZIG_TARGET:-x86_64-linux-musl}    # static: runs in alpine:3

DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$DIR/src"
BIN="$DIR/zrk"
STAMP="$DIR/.built-ref"

command -v zig >/dev/null 2>&1 || {
    echo "zrk/build.sh: zig not found — it's in the devenv shell (needs >= 0.16)" >&2
    exit 1
}

# Skip if we already built this exact ref.
if [ -x "$BIN" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$ZRK_REF" ]; then
    echo "zrk: $BIN already built at $ZRK_REF"
    exit 0
fi

# Fetch/refresh the pinned source. Explicit checkout of the SHA defeats any
# clone caching — the whole point of pinning.
if [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch origin "$ZRK_REF" 2>/dev/null || git -C "$SRC" fetch --tags origin
else
    rm -rf "$SRC"
    git clone "$ZRK_REPO" "$SRC"
fi
git -C "$SRC" checkout -q "$ZRK_REF"

# Cross-compile a static musl binary with the local zig.
( cd "$SRC" && zig build -Doptimize=ReleaseFast -Dtarget="$ZIG_TARGET" )
cp "$SRC/zig-out/bin/zrk" "$BIN"
printf '%s' "$ZRK_REF" > "$STAMP"
echo "zrk: built $BIN at $ZRK_REF ($ZIG_TARGET, zig $(zig version 2>/dev/null || echo '?'))"
