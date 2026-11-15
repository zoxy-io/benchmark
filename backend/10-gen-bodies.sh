#!/bin/sh
# Run by the nginx image before start: the canned body into the tmpfs.
# One size, 10 KiB, for every profile and healthcheck (profile.zig `c1k`).
set -eu
head -c 10240 /dev/zero | tr '\0' 'x' > /srv/bodies/10k
