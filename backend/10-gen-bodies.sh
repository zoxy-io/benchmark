#!/bin/sh
# Run by the nginx image before start: canned bodies into the tmpfs.
# 10k is every nightly profile's; 1k serves c100/c10k/smoke and healthchecks.
set -eu
gen() { head -c "$2" /dev/zero | tr '\0' 'x' > "/srv/bodies/$1"; }
gen 1k 1024
gen 10k 10240
