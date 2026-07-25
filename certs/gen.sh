#!/usr/bin/env sh
# Regenerate the shared benchmark TLS identity: one self-signed ECDSA P-256
# cert+key, presented by EVERY proxy-under-test (parity — same curve, same
# key size, so no proxy pays a different asymmetric-crypto cost). P-256 is
# a hard requirement, not a preference: zoxy's ztls engine (phase-3a-ztls)
# only signs with ECDSA P-256/P-384, RSA and Ed25519 are rejected at load.
#
# Throwaway and safe to commit — same practice as zoxy's own src/tls/testdata
# (self-signed, 10y validity, regenerate freely, protects nothing real). zrk
# connects with -k (skip verification), which also drops SNI, so the CN/SAN
# below never gets checked by the load path; they exist for humans (curl -k,
# browsers) poking the stack directly.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"

openssl ecparam -name prime256v1 -genkey -noout -out key.pem
openssl req -new -x509 -key key.pem -subj "/CN=proxy.bench.local" \
    -addext "subjectAltName=DNS:proxy.bench.local,DNS:localhost,IP:127.0.0.1" \
    -days 3650 -out cert.pem

# haproxy's `bind ... crt <file>` wants cert immediately followed by key in
# one PEM; every other proxy takes cert/key as two separate files.
cat cert.pem key.pem > combined.pem

# World-readable: bind-mounted read-only into every proxy container, several
# of which (envoy) run as a non-root user from the start and can't read a
# key `openssl req` left at the default 0600 — envoy fails startup with
# "Failed to load incomplete private key" otherwise. Not a real secret (see
# above), so this costs nothing.
chmod 0644 cert.pem key.pem combined.pem

echo "certs/: wrote cert.pem, key.pem, combined.pem (ECDSA P-256, self-signed, 10y)"
