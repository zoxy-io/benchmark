#!/bin/sh
# zoxy does no DNS (config endpoints must be IP literals), so resolve the
# backend hostnames here, with retries, and render them into the config.
# "pick": "rr" (not zoxy's default p2c) to match every other proxy.
set -eu

BACKENDS=${BACKENDS:-backend0:9000,backend1:9000,backend2:9000,backend3:9000}

# access_log_buffer_bytes at its 1 MiB ceiling: the 32 KiB default dropped
# 48.51% of log lines at c1k, while other proxies log every line.
# Unset slot knobs keep compiled defaults; relay_buffers defaults to conn_slots.
fields="\"access_log_buffer_bytes\": 1048576"
if [ -n "${ZOXY_CONN_SLOTS:-}" ]; then
    fields="$fields, \"conn_slots\": ${ZOXY_CONN_SLOTS}"
fi
if [ -n "${ZOXY_UPSTREAM_SLOTS:-}" ]; then
    fields="${fields}, \"upstream_slots\": ${ZOXY_UPSTREAM_SLOTS}"
fi
# TLS session pool, only on TLS turns. bench sets it to conn_slots: fewer sheds
# connections (watch zoxy_shed_tls_engines). Dominates TLS memory.
if [ -n "${ZOXY_TLS_ENGINES:-}" ]; then
    fields="${fields}, \"tls_engines\": ${ZOXY_TLS_ENGINES}"
fi
LIMITS="{${fields}}"

# All-or-nothing: a dropped member would round-robin over three backends.
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

# PROXY_TLS_PORT is set only on TLS turns; the listener is appended then, so
# plaintext configs are unchanged (the preallocated engine pool would add
# ~250 MiB). `tls` sits beside the `http` body (0.8.0 config).
# One line: it becomes a sed replacement, which rejects raw newlines.
if [ -n "${PROXY_TLS_PORT:-}" ]; then
    TLS_LISTENER=", { \"bind\": \"0.0.0.0:${PROXY_TLS_PORT}\", \"tls\": { \"cert\": \"/etc/bench/tls/bench.crt\", \"key\": \"/etc/bench/tls/bench.key\" }, \"http\": { \"cluster\": \"origin\" } }"
else
    TLS_LISTENER=""
fi

# `|` delimiter for the address list, which may grow to contain `/`.
sed -e "s|@BACKEND_ADDRS@|$addrs|" -e "s/@LIMITS@/$LIMITS/" \
    -e "s/@PORT@/${PROXY_PORT:-8080}/" -e "s|@TLS_LISTENER@|$TLS_LISTENER|" \
    /etc/zoxy/config.template.json > /etc/zoxy/config.json

# `--check` validates the rendered config without binding, printing the
# refusing rule and the config to stderr. Probed via --help: refs before 0.8.0
# (profile.zig `zoxy_ref`) would read it as a second config path.
if /usr/local/bin/zoxy --help 2>&1 | grep -q -- '--check'; then
    check_status=0
    /usr/local/bin/zoxy --check /etc/zoxy/config.json || check_status=$?
    if [ "$check_status" -ne 0 ]; then
        echo "zoxy-entrypoint: zoxy refused the config rendered below (--check exit ${check_status}; 1 = the config is wrong, 2 = this box cannot fit it)" >&2
        cat /etc/zoxy/config.json >&2
        exit "$check_status"
    fi
fi

# One event loop per process: exec a single zoxy as PID 1. Stdout is not
# redirected (zoxy writes the access log file itself); it carries the startup
# banners `docker logs` shows on a failed start.
exec /usr/local/bin/zoxy /etc/zoxy/config.json
