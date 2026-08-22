#!/usr/bin/env bash
set -Eeuo pipefail

# Direct container integration contract. It starts a disposable backend and
# HAProxy in the backend's network namespace, reproducing
# network_mode: service:dsh without touching the default Compose/Caddy stack.

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly HAPROXY_IMAGE=${HAPROXY_IMAGE:-haproxy:3.4.3-alpine3.24@sha256:c7f5037a567378929d0aba734eb78b73497209c72456519420ce5e68a42d60ac}
readonly HAPROXY_PLATFORM=${HAPROXY_PLATFORM:-linux/amd64}
readonly BACKEND_IMAGE=${BACKEND_IMAGE:-local/dsh:0.1.1-rc.1-amd64}
readonly BACKEND_PLATFORM=${BACKEND_PLATFORM:-linux/amd64}
readonly TEST_LABEL='io.deepseek-harness-container.test=haproxy-runtime'
readonly TEST_LABEL_VALUE='haproxy-runtime'
readonly BACKEND_NAME="dsh-haproxy-backend-${$}-${RANDOM}"
readonly PROXY_NAME="dsh-haproxy-proxy-${$}-${RANDOM}"
readonly STAGING_VOLUME="dsh-haproxy-staging-${$}-${RANDOM}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v docker >/dev/null || fail 'docker is required for HAProxy runtime validation'
command -v curl >/dev/null || fail 'curl is required for HAProxy runtime validation'
command -v openssl >/dev/null || fail 'openssl is required for no-SNI validation'
docker image inspect "$HAPROXY_IMAGE" >/dev/null 2>&1 || fail "HAProxy image is not loaded: $HAPROXY_IMAGE"
docker image inspect "$BACKEND_IMAGE" >/dev/null 2>&1 || fail "backend test image is not loaded: $BACKEND_IMAGE"

tmp_dir=$(mktemp -d /tmp/dsh-haproxy-runtime.XXXXXX)
cleanup() {
  if docker container inspect "$PROXY_NAME" >/dev/null 2>&1; then
    test "$(docker inspect "$PROXY_NAME" --format '{{index .Config.Labels "io.deepseek-harness-container.test"}}')" = "$TEST_LABEL_VALUE" || exit 2
    docker rm --force "$PROXY_NAME" >/dev/null
  fi
  if docker container inspect "$BACKEND_NAME" >/dev/null 2>&1; then
    test "$(docker inspect "$BACKEND_NAME" --format '{{index .Config.Labels "io.deepseek-harness-container.test"}}')" = "$TEST_LABEL_VALUE" || exit 2
    docker rm --force "$BACKEND_NAME" >/dev/null
  fi
  if docker volume inspect "$STAGING_VOLUME" >/dev/null 2>&1; then
    test "$(docker volume inspect "$STAGING_VOLUME" --format '{{index .Labels "io.deepseek-harness-container.test"}}')" = "$TEST_LABEL_VALUE" || exit 2
    docker volume rm "$STAGING_VOLUME" >/dev/null
  fi
  case "$tmp_dir" in
    /tmp/dsh-haproxy-runtime.*) ;;
    *) return 2 ;;
  esac
  if [[ -d "$tmp_dir" && ! -L "$tmp_dir" ]]; then
    find "$tmp_dir" -xdev -depth -mindepth 1 -delete
    rmdir -- "$tmp_dir"
  fi
}
trap cleanup EXIT

"$ROOT/scripts/haproxy-test-pki.sh" "$tmp_dir/pki" 127.0.0.1
export DSH_LAN_IP=127.0.0.1
export DSH_HAPROXY_USERNAME=dsh-admin
# Test-only 1000 rounds keep zero-warning deterministic under QEMU.
# shellcheck disable=SC2016 # crypt hashes must remain literal.
export DSH_HAPROXY_PASSWORD_HASH='$5$rounds=1000$dshpoc01$JV4p6OtCPE9397xXoWE1webmlCmF8waJmDLWnO5GFr/'
python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/haproxy.cfg"
docker volume create --label "$TEST_LABEL" "$STAGING_VOLUME" >/dev/null

# Model the Compose one-shot root staging boundary.  Host-side config and key
# remain 0600; only the named volume receives UID-99-readable 0440 copies.
docker run --rm \
  --platform "$HAPROXY_PLATFORM" \
  --user 0:0 \
  --network none \
  --read-only \
  --cap-drop ALL \
  --cap-add CHOWN \
  --cap-add DAC_OVERRIDE \
  --cap-add FOWNER \
  --security-opt no-new-privileges:true \
  --mount "type=bind,src=$tmp_dir/haproxy.cfg,dst=/input/haproxy.cfg,ro" \
  --mount "type=bind,src=$tmp_dir/pki/tls.pem,dst=/input/tls.pem,ro" \
  --mount "type=volume,src=$STAGING_VOLUME,dst=/run/haproxy" \
  --entrypoint /bin/sh \
  "$HAPROXY_IMAGE" -eu -c \
  'test -s /input/haproxy.cfg && test -s /input/tls.pem &&
   rm -f /run/haproxy/haproxy.cfg /run/haproxy/tls.pem &&
   cp /input/haproxy.cfg /run/haproxy/haproxy.cfg &&
   cp /input/tls.pem /run/haproxy/tls.pem &&
   chown 99:99 /run/haproxy/haproxy.cfg /run/haproxy/tls.pem &&
   chmod 0440 /run/haproxy/haproxy.cfg /run/haproxy/tls.pem'

docker run --detach \
  --platform "$BACKEND_PLATFORM" \
  --name "$BACKEND_NAME" \
  --label "$TEST_LABEL" \
  --publish 127.0.0.1::443 \
  --mount "type=bind,src=$ROOT/haproxy/test-backend.mjs,dst=/tmp/test-backend.mjs,ro" \
  --entrypoint /nodejs/bin/node \
  "$BACKEND_IMAGE" /tmp/test-backend.mjs >/dev/null

host_port=$(docker port "$BACKEND_NAME" 443/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p')
[[ "$host_port" =~ ^[0-9]+$ ]] || fail "could not resolve ephemeral HTTPS port: $host_port"
readonly host_port
readonly base_url="https://127.0.0.1:$host_port"

docker run --detach \
  --platform "$HAPROXY_PLATFORM" \
  --name "$PROXY_NAME" \
  --label "$TEST_LABEL" \
  --network "container:$BACKEND_NAME" \
  --user 99:99 \
  --init \
  --read-only \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=8m \
  --mount "type=volume,src=$STAGING_VOLUME,dst=/run/haproxy,ro" \
  --entrypoint haproxy \
  "$HAPROXY_IMAGE" -W -db -f /run/haproxy/haproxy.cfg >/dev/null

for attempt in $(seq 1 30); do
  if curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
      --user dsh-admin:test-password -H 'Host: 127.0.0.1' \
      --output /dev/null --write-out '%{http_code}' \
      "$base_url/" 2>/dev/null | grep -qx '200'; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    docker logs "$PROXY_NAME" >&2
    docker logs "$BACKEND_NAME" >&2
    fail 'HAProxy/backend did not become ready'
  fi
  sleep 1
done

request_with_host() {
  local host=${1:?host required}
  shift
  curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
    --user dsh-admin:test-password -H "Host: $host" "$@"
}

request() {
  request_with_host '127.0.0.1' "$@"
}

test "$(curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
  -H 'Host: 127.0.0.1' --output /dev/null --write-out '%{http_code}' "$base_url/")" = 401
test "$(request_with_host 'evil.example' --output /dev/null --write-out '%{http_code}' "$base_url/")" = 421
test "$(request_with_host '127.0.0.1:8443' --output /dev/null --write-out '%{http_code}' "$base_url/")" = 421
test "$(request -H 'Sec-Fetch-Site: cross-site' --output /dev/null --write-out '%{http_code}' "$base_url/")" = 403
test "$(request -H 'Origin: https://evil.example' --output /dev/null --write-out '%{http_code}' "$base_url/")" = 403

body=$(request "$base_url/")
python3 - "$body" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value == {"host": "127.0.0.1:3080", "origin": None, "sec_fetch_site": None}, value
PY

body=$(request -H 'Origin: https://127.0.0.1' -H 'Sec-Fetch-Site: same-origin' "$base_url/")
python3 - "$body" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value == {"host": "127.0.0.1:3080", "origin": None, "sec_fetch_site": None}, value
PY

test "$(request_with_host '127.0.0.1:443' --output /dev/null --write-out '%{http_code}' "$base_url/")" = 200

stream=$(curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
  --user dsh-admin:test-password -H 'Host: 127.0.0.1' \
  -N --max-time 5 "$base_url/stream" 2>/dev/null || true)
grep -Fq 'data: first' <<<"$stream" || fail 'SSE first event did not pass through'
grep -Fq 'data: second' <<<"$stream" || fail 'SSE second event did not pass through'

websocket=$(curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
  --user dsh-admin:test-password -H 'Host: 127.0.0.1' \
  --http1.1 --include --no-buffer \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$base_url/ws" \
  --max-time 5 2>/dev/null || true)
grep -Fq '101 Switching Protocols' <<<"$websocket" || fail 'WebSocket upgrade did not pass through'

nosni=$(printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Basic ZHNoLWFkbWluOnRlc3QtcGFzc3dvcmQ=\r\nConnection: close\r\n\r\n' |
  timeout 5 openssl s_client -quiet -noservername -connect "127.0.0.1:$host_port" \
    -CAfile "$tmp_dir/pki/ca.crt" 2>/dev/null || true)
grep -Fq 'HTTP/1.1 200' <<<"$nosni" || fail 'no-SNI request did not receive authorized 200'

ports=$(docker port "$BACKEND_NAME")
test "$ports" = "443/tcp -> 127.0.0.1:$host_port" || fail "unexpected published ports: $ports"
test "$(docker inspect "$PROXY_NAME" --format '{{.Config.User}}')" = '99:99'
printf 'PASS: HAProxy 401/200/421/403 including wrong-port Host, upstream header gate, SSE, WebSocket, no-SNI and no-3080 runtime contract\n'
