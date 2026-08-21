#!/usr/bin/env bash
set -euo pipefail

# This host-capability test intentionally uses the multi-platform index so it
# runs natively on both x86 development hosts and ARM CI. The shipped Compose
# separately pins the ARM64 child digest.
readonly CADDY_REF='caddy:2.11.4@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d'
readonly TEST_LABEL='io.deepseek-harness-container.test=caddy-init'
readonly DATA_VOLUME="dsh-caddy-init-data-${$}"
readonly CONFIG_VOLUME="dsh-caddy-init-config-${$}"

cleanup() {
  local volume_name
  for volume_name in "$DATA_VOLUME" "$CONFIG_VOLUME"; do
    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
      test "$(docker volume inspect "$volume_name" \
        --format '{{index .Labels "io.deepseek-harness-container.test"}}')" = \
        'caddy-init'
      docker volume rm "$volume_name" >/dev/null
    fi
  done
}
trap cleanup EXIT

for volume_name in "$DATA_VOLUME" "$CONFIG_VOLUME"; do
  case "$volume_name" in
    dsh-caddy-init-*) ;;
    *) exit 2 ;;
  esac
  docker volume create --label "$TEST_LABEL" "$volume_name" >/dev/null
done

docker run --rm \
  --user 0:0 \
  --network none \
  --read-only \
  --cap-drop ALL \
  --cap-add CHOWN \
  --security-opt no-new-privileges:true \
  --mount "type=volume,src=$DATA_VOLUME,dst=/data" \
  --mount "type=volume,src=$CONFIG_VOLUME,dst=/config" \
  --entrypoint /bin/sh \
  "$CADDY_REF" -eu -c \
  'mkdir -p /data/caddy /config/caddy && chown 1000:1000 /data/caddy /config/caddy'

docker run --rm \
  --user 1000:1000 \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --mount "type=volume,src=$DATA_VOLUME,dst=/data" \
  --mount "type=volume,src=$CONFIG_VOLUME,dst=/config" \
  --entrypoint /bin/sh \
  "$CADDY_REF" -eu -c \
  'touch /data/caddy/write-probe /config/caddy/write-probe
   test "$(stat -c %u:%g /data/caddy /config/caddy)" = "1000:1000
1000:1000"'

printf 'PASS: one-shot Caddy volume initializer enables non-root writes\n'
