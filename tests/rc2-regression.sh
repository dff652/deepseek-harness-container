#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly IMAGE_REF=${DSH_IMAGE:-local/dsh:0.1.1-rc.2-amd64}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail 'rc.2 regression requires docker'
docker image inspect "$IMAGE_REF" >/dev/null 2>&1 ||
  fail "rc.2 regression image is not loaded: $IMAGE_REF"
IMAGE_PLATFORM=$(docker image inspect "$IMAGE_REF" --format '{{.Os}}/{{.Architecture}}')
readonly IMAGE_PLATFORM
case "$IMAGE_PLATFORM" in
  linux/amd64|linux/arm64) ;;
  *) fail "unsupported DSH image platform: $IMAGE_PLATFORM" ;;
esac
test "$(docker image inspect "$IMAGE_REF" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = \
  '0.1.1-rc.2' || fail 'image version label is not exactly 0.1.1-rc.2'
test "$(docker run --rm --platform "$IMAGE_PLATFORM" --network none "$IMAGE_REF" --version)" = '0.1.1-rc.2' ||
  fail 'DSH CLI version is not exactly 0.1.1-rc.2'

# This is a package-level contract only. It never joins the host network, maps
# a host port, or touches the systemd deployment/current 8443 test instance.
docker run --rm \
  --platform "$IMAGE_PLATFORM" \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --tmpfs /var/lib/dsh:rw,nosuid,nodev,size=128m,uid=10001,gid=10001 \
  --mount "type=bind,src=$ROOT/tests/rc2-regression.mjs,dst=/workspace/rc2-regression.mjs,readonly" \
  --entrypoint /nodejs/bin/node \
  "$IMAGE_REF" /workspace/rc2-regression.mjs
