#!/usr/bin/env bash
# Build the NixOS qcow2 (all five proxies + tuning) and push it to Yandex Object
# Storage, then print the source URL for terraform.tfvars.
#
# Requires: nix, awscli2, and:
#   BENCH_BUCKET             your YC Object Storage bucket name
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   a YC static access key (S3 API)
set -euo pipefail
cd "$(dirname "$0")/.."

BUCKET=${BENCH_BUCKET:?set BENCH_BUCKET to your Yandex Object Storage bucket}
KEY=${BENCH_IMAGE_KEY:-zoxy-benchmark/nixos.qcow2}
ENDPOINT=https://storage.yandexcloud.net

echo "== nix build .#image =="
nix build .#packages.x86_64-linux.image -o result-image

img=$(find -L result-image -name '*.qcow2' | head -1)
[ -n "$img" ] || { echo "no qcow2 under result-image/" >&2; exit 1; }
echo "built: $img ($(du -h "$img" | cut -f1))"

echo "== upload s3://$BUCKET/$KEY =="
aws --endpoint-url "$ENDPOINT" s3 cp "$img" "s3://$BUCKET/$KEY"

echo
echo "Set this in terraform/terraform.tfvars:"
echo "  image_source_url = \"$ENDPOINT/$BUCKET/$KEY\""
