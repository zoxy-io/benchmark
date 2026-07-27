#!/usr/bin/env sh
# Cross-compile zrk-runner to a static x86_64-linux-musl binary (portable to
# any Linux, glibc or musl, no runtime deps) — the same portability zrk's own
# release binaries have, so it can just be rsynced to the loadgen and run
# directly, no container needed.
#
# The zrk/zio versions actually used are pinned in build.zig.zon (via `zig
# fetch --save`), not here — bump them with `zig fetch --save=zrk
# git+https://github.com/zoxy-io/zrk#<ref>` (and `=zio` similarly, matching
# whatever zio commit that zrk ref pins in ITS build.zig.zon — they must
# resolve to the same module instance or the Io type across the zrk/zio
# boundary won't unify).
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
ZIG_TARGET=${ZIG_TARGET:-x86_64-linux-musl}

command -v zig >/dev/null 2>&1 || {
    echo "zrk-runner/build.sh: zig not found — it's in the devenv shell (needs >= 0.16)" >&2
    exit 1
}

( cd "$DIR" && zig build -Doptimize=ReleaseFast -Dtarget="$ZIG_TARGET" )
echo "zrk-runner: built $DIR/zig-out/bin/zrk-runner ($ZIG_TARGET, zig $(zig version 2>/dev/null || echo '?'))"
