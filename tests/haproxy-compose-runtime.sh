#!/usr/bin/env bash
set -Eeuo pipefail

# Real isolated Compose smoke. Set DSH_IMAGE to a loaded AMD64/ARM64 DSH
# candidate and run this script on that architecture (or under QEMU). It
# never modifies compose.yaml or starts the default Caddy project.

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly PROJECT="dsh-haproxy-compose-${$}-${RANDOM}"
readonly DSH_IMAGE=${DSH_IMAGE:?usage: DSH_IMAGE=loaded-dsh-image DSH_PLATFORM=linux/amd64 tests/haproxy-compose-runtime.sh}
readonly DSH_PLATFORM=${DSH_PLATFORM:-linux/amd64}
readonly HAPROXY_IMAGE=${HAPROXY_IMAGE:-haproxy:dsh-offline-3.4.3-amd64-c7f5037a5673}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v docker >/dev/null || fail 'docker is required'
command -v curl >/dev/null || fail 'curl is required'
docker image inspect "$DSH_IMAGE" >/dev/null 2>&1 || fail "DSH image is not loaded: $DSH_IMAGE"
docker image inspect "$HAPROXY_IMAGE" >/dev/null 2>&1 || fail "HAProxy image is not loaded: $HAPROXY_IMAGE"

tmp_dir=$(mktemp -d /tmp/dsh-haproxy-compose.XXXXXX)
cleanup() {
  docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" down --volumes --remove-orphans >/dev/null 2>&1 || true
  case "$tmp_dir" in
    /tmp/dsh-haproxy-compose.*) ;;
    *) return 2 ;;
  esac
  if [[ -d "$tmp_dir" && ! -L "$tmp_dir" ]]; then
    find "$tmp_dir" -xdev -depth -mindepth 1 -delete
    rmdir -- "$tmp_dir"
  fi
}
trap cleanup EXIT
mkdir -p -- "$tmp_dir/workspace"
host_port=$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)
[[ "$host_port" =~ ^[0-9]+$ ]] || fail "could not reserve a test HTTPS port: $host_port"
readonly host_port
if ((host_port == 65535)); then wrong_port=$((host_port - 1)); else wrong_port=$((host_port + 1)); fi
readonly wrong_port
readonly approved_authority="127.0.0.1:$host_port"
"$ROOT/scripts/haproxy-test-pki.sh" "$tmp_dir/pki" 127.0.0.1
export DSH_LAN_IP=127.0.0.1
export DSH_HTTPS_PORT="$host_port"
export DSH_HAPROXY_USERNAME=dsh-admin
# Test-only 1000 rounds keep zero-warning deterministic under QEMU.
# shellcheck disable=SC2016 # crypt hashes must remain literal.
export DSH_HAPROXY_PASSWORD_HASH='$5$rounds=1000$dshpoc01$JV4p6OtCPE9397xXoWE1webmlCmF8waJmDLWnO5GFr/'
python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/haproxy.cfg"

export DSH_IMAGE DSH_PLATFORM HAPROXY_IMAGE DSH_WORKSPACE="$tmp_dir/workspace"
export HAPROXY_CONFIG="$tmp_dir/haproxy.cfg" HAPROXY_CERT="$tmp_dir/pki/tls.pem"

docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" up --detach --wait
running=$(docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" ps --status running --services | sort)
test "$running" = $'dsh\nhaproxy' || {
  docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" ps
  fail "unexpected running services: $running"
}
for attempt in $(seq 1 30); do
  if curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
      --user dsh-admin:test-password -H "Host: $approved_authority" \
      --output /dev/null --write-out '%{http_code}' \
      "https://127.0.0.1:$host_port/" 2>/dev/null | grep -qx '200'; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" logs >&2
    fail 'HAProxy/DSH did not become ready'
  fi
  sleep 1
done
test "$(curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
  -H "Host: $approved_authority" --output /dev/null --write-out '%{http_code}' \
  "https://127.0.0.1:$host_port/")" = 401
test "$(curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
  --user dsh-admin:test-password -H "Host: $approved_authority" \
  --output /dev/null --write-out '%{http_code}' "https://127.0.0.1:$host_port/")" = 200
test "$(curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
  --user dsh-admin:test-password -H "Host: 127.0.0.1:$wrong_port" \
  --output /dev/null --write-out '%{http_code}' "https://127.0.0.1:$host_port/")" = 421
test "$(docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" port dsh 443)" = "127.0.0.1:$host_port"
test -z "$(docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" port dsh 3080 2>/dev/null)"
test -z "$(docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" port dsh 443/udp 2>/dev/null || true)"

proxy_container=$(docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" ps -q haproxy)
test -n "$proxy_container"
test "$(docker inspect "$proxy_container" --format '{{.State.Health.Status}}')" = healthy
docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" restart haproxy >/dev/null
for attempt in $(seq 1 30); do
  health=$(docker inspect "$proxy_container" --format '{{.State.Health.Status}}')
  if [[ "$health" == healthy ]]; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    docker compose --project-name "$PROJECT" --file "$ROOT/compose.haproxy.yaml" logs haproxy >&2
    fail "HAProxy did not recover from restart: $health"
  fi
  sleep 1
done
test "$(curl --silent --show-error --noproxy '*' --cacert "$tmp_dir/pki/ca.crt" \
  --user dsh-admin:test-password -H "Host: $approved_authority" \
  --output /dev/null --write-out '%{http_code}' "https://127.0.0.1:$host_port/")" = 200
printf 'PASS: isolated Compose HAProxy + DSH startup and LAN 401/200/wrong-port-421/no-3080 smoke (%s)\n' "$DSH_PLATFORM"
