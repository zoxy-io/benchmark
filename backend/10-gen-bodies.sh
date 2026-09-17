#!/bin/sh
# Run by the nginx image before start: canned bodies into the tmpfs.
set -eu
gen() { head -c "$2" /dev/zero | tr '\0' 'x' > "/srv/bodies/$1"; }
gen 64 64
gen 1k 1024
gen 10k 10240
gen 100k 102400
