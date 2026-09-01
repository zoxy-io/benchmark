#!/bin/sh
# zoxy (libxev) does no DNS by design — config endpoints must be IP literals
# (config.zig rejects hostnames structurally). The benchmark's upstream is a
# four-node pool addressed by hostname (`backend0`..`backend3` — compose service
# DNS locally, extra_hosts entries in cloud), so resolve them HERE, once, before
# zoxy starts, and render the literals into the config. The retry loop also
# absorbs the DNS-registration blip that used to race proxies at startup — by
# the time zoxy runs, every address is a literal and can never miss.
#
# The cluster pins "pick": "rr" (config.template.json). zoxy's own default is
# p2c, which would very likely serve it better under load — but every proxy in
# this comparison round-robins, and the run is meant to measure proxies rather
# than endpoint-pick policies.
set -eu

BACKENDS=${BACKENDS:-backend0:9000,backend1:9000,backend2:9000,backend3:9000}

# access_log_buffer_bytes fixed at its compiled ceiling (constants.zig's
# access_log_buffer_bytes_max, 1 MiB), not left at the 32 KiB default: the
# access log is two of these buffers with one write in flight, so the real
# burst-absorption depth before lines drop is one buffer's worth, and at 32
# KiB that was ~131 typical lines — far too little at c10k concurrency on the
# 1-CPU box this runs on, where the write's own round trip already competes
# with the event loop for the one core. The c1k run this was found on dropped
# 48.51% of completed requests' log lines at the default; every other proxy
# in the comparison writes (or buffers) every line, so an undersized zoxy
# default was contaminating the comparison with a capacity artifact rather
# than a genuine throughput difference.
#
# Optional c10k knobs: config.zig's `limits.conn_slots`/`limits.upstream_slots`
# default to 1386/1311 (~32 MiB of pools); omitting a key or passing `{}` is
# identical to leaving it at its compiled default (all `Limits` fields default;
# see constants.zig's upstream_slots_default, deliberately NOT tracking the
# compiled ceiling — a deployment opts up explicitly, here). Neither set =>
# `{}`, today's default behavior, byte-for-byte. relay_buffers isn't set on
# purpose — it defaults to conn_slots when omitted.
fields="\"access_log_buffer_bytes\": 1048576"
if [ -n "${ZOXY_CONN_SLOTS:-}" ]; then
    fields="$fields, \"conn_slots\": ${ZOXY_CONN_SLOTS}"
fi
if [ -n "${ZOXY_UPSTREAM_SLOTS:-}" ]; then
    fields="${fields}, \"upstream_slots\": ${ZOXY_UPSTREAM_SLOTS}"
fi
# The TLS session pool, set only on a TLS turn and sized by the profile
# (bench passes ZOXY_TLS_ENGINES=conn_slots — one engine is held for every
# admitted connection on a TLS listener, so anything less sheds by admission
# policy and measures the cap instead of the proxy; watch
# `zoxy_shed_tls_engines`, which bench reads off the admin endpoint after every
# ramp). It is also the largest object zoxy holds — ~92 KiB of engine plus a
# 64 KiB plaintext buffer per engine, over a 10 MiB shared libcrypto heap — so
# this line is most of a TLS deployment's memory: 68 MiB with no TLS listener,
# 234 MiB with one at the stock 1024 engines, as `zoxy --check` prices this
# deployment at 0.8.0 (it was ~136 KiB per engine under the old ztls engine;
# 0.8.0 terminates with zssl).
if [ -n "${ZOXY_TLS_ENGINES:-}" ]; then
    fields="${fields}, \"tls_engines\": ${ZOXY_TLS_ENGINES}"
fi
LIMITS="{${fields}}"

# Every member, in the order given: a JSON array of "ip:port" string literals.
# All-or-nothing — a pool member that silently dropped out would leave zoxy
# round-robining across three backends while every other proxy uses four, which
# is a throughput difference that looks exactly like a proxy difference.
addrs=""
for entry in $(echo "$BACKENDS" | tr ',' ' '); do
    host=${entry%:*}
    port=${entry##*:}

    ip=""
    for i in $(seq 1 40); do # ~20s ceiling; compose gates backends healthy first
        ip=$(getent ahostsv4 "$host" | head -n1 | cut -d' ' -f1) || ip=""
        [ -n "$ip" ] && break
        echo "zoxy-entrypoint: waiting for '$host' to resolve ($i/40)" >&2
        sleep 0.5
    done
    if [ -z "$ip" ]; then
        echo "zoxy-entrypoint: cannot resolve upstream '$host' — is it up?" >&2
        exit 1
    fi

    [ -n "$addrs" ] && addrs="$addrs, "
    addrs="$addrs\"$ip:$port\""
done

# PROXY_PORT varies per (profile, proxy) turn on the cloud fleet — see
# compose.yaml's x-proxy-common for why — always set by compose (defaulting
# to 8080), never literally unset.
#
# PROXY_TLS_PORT is the same, with one difference that decides the shape of
# this block: it is set only on a TLS TURN, and empty otherwise. So a TLS
# listener is APPENDED to the listener array for the c1k-tls profile and the
# rendered config on a plaintext profile is byte-for-byte what it was before
# TLS existed here. That matters more for zoxy than for any other proxy in the
# comparison: the TLS engine pool is preallocated at boot, so an always-present
# TLS listener would have added ~250 MiB to zoxy's published memory number on
# profiles that never send it a handshake.
#
# The listener is otherwise identical to the plaintext one — same cluster, same
# `http` body — because zoxy terminates TLS inbound only and the upstream leg
# stays plaintext either way. That is what makes c1k vs c1k-tls a measurement
# of TLS rather than of two different configurations.
#
# `tls` sits BESIDE the `http` body rather than inside it (zoxy 0.8.0's config
# freeze): both protocols can be spoken over a terminated session, so the block
# is shared, and the body key is what names the protocol now that `protocol` is
# gone.
#
# The cert is the run's own ECDSA P-256 self-signed pair, generated on the
# proxy host before any container starts (bench's ensureTlsMaterial) and
# mounted read-only at /etc/bench/tls. zoxy rejects an RSA key outright, so the
# curve is not a preference.
#
# ONE LINE, deliberately: this becomes a sed replacement, and sed rejects a raw
# newline in one. JSON does not care, and the rendered config is only ever read
# by zoxy and by whoever is debugging a start failure.
if [ -n "${PROXY_TLS_PORT:-}" ]; then
    TLS_LISTENER=", { \"bind\": \"0.0.0.0:${PROXY_TLS_PORT}\", \"tls\": { \"cert\": \"/etc/bench/tls/bench.crt\", \"key\": \"/etc/bench/tls/bench.key\" }, \"http\": { \"cluster\": \"origin\" } }"
else
    TLS_LISTENER=""
fi

#
# `|` as the sed delimiter for the address list: the replacement contains `/`
# in neither the IPs nor the quotes, but it is a comma-joined list that will
# grow if the pool does, and a `/` sneaking in would turn a config error into a
# sed syntax error. The other two stay on `/` — they are a bare integer and a
# brace-delimited JSON object.
sed -e "s|@BACKEND_ADDRS@|$addrs|" -e "s/@LIMITS@/$LIMITS/" \
    -e "s/@PORT@/${PROXY_PORT:-8080}/" -e "s|@TLS_LISTENER@|$TLS_LISTENER|" \
    /etc/zoxy/config.template.json > /etc/zoxy/config.json

# The rendered config is the most likely thing in this file to be wrong — a
# template edit, a slot ceiling that moved under a version bump (zoxy #132 took
# nine off `conn_slots_max` and every c10k turn was refused until profile.zig
# caught up), a cert absent from the mount. `--check` runs the whole load —
# every limit, every cert — WITHOUT binding a port, so the loader's own message
# names the rule that refused, on stderr, ahead of the exec. Its budget banner
# is the same one a start prints, so a passing check costs a line `docker logs`
# was going to carry anyway.
#
# PROBED, not assumed. This entrypoint also serves source builds of older refs
# — profile.zig's `zoxy_ref` is how the ReleaseFast/ReleaseSafe A/B pinned
# v0.1.0 against v0.2.1 — and `--check` arrived in 0.8.0. Every tag before it
# answers `--help` and would read `--check` as a second config path
# (`extra_arguments`), failing a run that was fine. No match, no gate.
#
# The config goes to stderr on a refusal: it lives inside a container that is
# about to not exist, and "which rule refused" is only half of a debuggable
# report without the document it refused.
if /usr/local/bin/zoxy --help 2>&1 | grep -q -- '--check'; then
    check_status=0
    /usr/local/bin/zoxy --check /etc/zoxy/config.json || check_status=$?
    if [ "$check_status" -ne 0 ]; then
        echo "zoxy-entrypoint: zoxy refused the config rendered below (--check exit ${check_status}; 1 = the config is wrong, 2 = this box cannot fit it)" >&2
        cat /etc/zoxy/config.json >&2
        exit "$check_status"
    fi
fi

# One event loop per PROCESS (no thread/worker knob), capped to 1 CPU and pinned
# to core 0 by the cloud overlay: run a SINGLE zoxy, exec'd so it stays PID 1.
#
# Stdout is deliberately NOT redirected, even though every proxy here logs to
# /tmp/access.log: zoxy opens that file itself (`access_log.sink: "file"` in
# config.template.json), so stdout carries only the two banners — the check's
# above and the start's here, both the memory budget and the resolved slot
# ceilings — which is what `docker logs` shows the harness when a container
# fails to start. Redirecting would take that with it.
exec /usr/local/bin/zoxy /etc/zoxy/config.json
