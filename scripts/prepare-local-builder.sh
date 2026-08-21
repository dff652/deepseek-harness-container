#!/usr/bin/env bash
set -euo pipefail

readonly BUILDER_NAME='dsh-arm64-qemu'
readonly BINFMT_REF='tonistiigi/binfmt:qemu-v10.0.4@sha256:8f58e6214f4cc9dc83ce8f5acad1ece508eb6b20e696a8c1e9f274481982c541'
readonly BUILDKIT_REF='moby/buildkit:v0.29.0@sha256:0039c1d47e8748b5afea56f4e85f14febaf34452bd99d9552d2daa82262b5cc5'
readonly PROBE_REF='alpine:3.22@sha256:2c9d26f410d032d5b1525aa8a873e238b05b90c4ae8618743d4311f0cc827e37'
readonly BINFMT_PATH='/proc/sys/fs/binfmt_misc/qemu-aarch64'

usage() {
  printf 'Usage: %s [--install-binfmt]\n' "$0"
  printf 'Without the flag, this script performs checks and creates no binfmt handler.\n'
}

install_binfmt=false
case "${1:-}" in
  '') ;;
  --install-binfmt) install_binfmt=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
if (( $# > 1 )); then usage >&2; exit 2; fi

command -v docker >/dev/null
docker info >/dev/null
docker buildx version >/dev/null

if [[ ! -f "$BINFMT_PATH" ]]; then
  if [[ "$install_binfmt" != true ]]; then
    printf 'ARM64 binfmt is absent; rerun with --install-binfmt after host-admin approval.\n' >&2
    exit 1
  fi
  docker run --privileged --rm "$BINFMT_REF" --install arm64
fi

grep -qx 'enabled' "$BINFMT_PATH"
grep -Eq '^flags:.*F' "$BINFMT_PATH"
test "$(docker run --rm --platform linux/arm64 "$PROBE_REF" uname -m)" = 'aarch64'

if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  docker buildx create \
    --name "$BUILDER_NAME" \
    --driver docker-container \
    --driver-opt "image=$BUILDKIT_REF" \
    --use
fi

builder_output=$(docker buildx inspect "$BUILDER_NAME" --bootstrap)
printf '%s\n' "$builder_output"
grep -Eq 'Platforms:.*linux/arm64' <<<"$builder_output"
