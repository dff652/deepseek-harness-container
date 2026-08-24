#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly HAPROXY_INDEX='haproxy:3.4.3-alpine3.24@sha256:fb87fc81943143b9acaea7442973e6ba654035fff76ffe7af6829dd1bcb0f7a5'
readonly HAPROXY_AMD64='sha256:c7f5037a567378929d0aba734eb78b73497209c72456519420ce5e68a42d60ac'
readonly HAPROXY_ARM64='sha256:0fe6e31a91ad42440ceba4419694189673f9773f90b985bd883db0054a7c5259'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v docker >/dev/null || fail 'docker is required for HAProxy config validation'
command -v python3 >/dev/null || fail 'python3 is required for HAProxy config rendering'
command -v openssl >/dev/null || fail 'openssl is required for disposable test PKI'
command -v jq >/dev/null || fail 'jq is required for HAProxy PoC lock validation'

tmp_dir=$(mktemp -d /tmp/dsh-haproxy-contract.XXXXXX)
readonly STAGING_VOLUME="dsh-haproxy-contract-${$}-${RANDOM}"
cleanup() {
  if docker volume inspect "$STAGING_VOLUME" >/dev/null 2>&1; then
    test "$(docker volume inspect "$STAGING_VOLUME" --format '{{index .Labels "io.deepseek-harness-container.test"}}')" = 'haproxy-contract' || exit 2
    docker volume rm "$STAGING_VOLUME" >/dev/null
  fi
  case "$tmp_dir" in
    /tmp/dsh-haproxy-contract.*) ;;
    *) return 2 ;;
  esac
  if [[ -d "$tmp_dir" && ! -L "$tmp_dir" ]]; then
    find "$tmp_dir" -xdev -depth -mindepth 1 -delete
    rmdir -- "$tmp_dir"
  fi
}
trap cleanup EXIT
mkdir -p -- "$tmp_dir/workspace"

export DSH_IMAGE=${CONTRACT_DSH_IMAGE:-local/dsh:0.1.1-rc.2-amd64}
export DSH_PLATFORM=${CONTRACT_PLATFORM:-linux/amd64}
export DSH_LAN_IP='192.0.2.10'
export DSH_WORKSPACE="$tmp_dir/workspace"
export HAPROXY_CONFIG="$tmp_dir/haproxy.cfg"
export HAPROXY_CERT="$tmp_dir/pki/tls.pem"
export DSH_HAPROXY_USERNAME='dsh-admin'
# Test-only 1000 rounds keep zero-warning deterministic under QEMU.
# shellcheck disable=SC2016 # crypt hashes must remain literal.
export DSH_HAPROXY_PASSWORD_HASH='$5$rounds=1000$dshpoc01$JV4p6OtCPE9397xXoWE1webmlCmF8waJmDLWnO5GFr/'
export HAPROXY_IMAGE=${CONTRACT_HAPROXY_IMAGE:-haproxy:3.4.3-alpine3.24@$HAPROXY_AMD64}

rendered="$tmp_dir/compose.json"
docker compose -f "$ROOT/compose.haproxy.yaml" config --format json >"$rendered"
python3 - "$rendered" "$DSH_IMAGE" "$DSH_PLATFORM" "$HAPROXY_IMAGE" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected_dsh_image = sys.argv[2]
expected_platform = sys.argv[3]
expected_haproxy_image = sys.argv[4]
services = document.get("services", {})
assert set(services) == {"dsh", "haproxy", "haproxy-init"}, services.keys()
dsh = services["dsh"]
proxy = services["haproxy"]
init = services["haproxy-init"]
assert proxy["image"] == expected_haproxy_image
assert init["image"] == proxy["image"]
assert dsh["image"] == expected_dsh_image
assert proxy["platform"] == expected_platform
assert dsh["platform"] == expected_platform
assert proxy["pull_policy"] == "never"
assert proxy["network_mode"] == "service:dsh"
assert proxy["read_only"] is True
assert proxy["user"] == "99:99"
assert proxy["cap_drop"] == ["ALL"]
assert proxy["cap_add"] == ["NET_BIND_SERVICE"]
assert proxy["security_opt"] == ["no-new-privileges:true"]
assert proxy["command"] == ["-f", "/run/haproxy/haproxy.cfg"]
assert "ports" not in proxy
assert proxy["depends_on"]["haproxy-init"]["condition"] == "service_completed_successfully"
assert init["network_mode"] == "none"
assert init["user"] == "0:0"
assert init["read_only"] is True
assert init["cap_drop"] == ["ALL"]
assert init["cap_add"] == ["CHOWN", "DAC_OVERRIDE", "FOWNER"]
assert init["security_opt"] == ["no-new-privileges:true"]
assert init["restart"] == "no"
assert dsh["ports"][0]["target"] == 443
assert dsh["ports"][0]["protocol"] == "tcp"
assert not any(str(p.get("target")) == "3080" for p in dsh.get("ports", []))
for name, service in services.items():
    text = json.dumps(service, sort_keys=True).lower()
    for forbidden in ("privileged", "network_mode: host", "/var/run/docker.sock", "sys_admin", "net_admin", "latest", "alpine:latest"):
        assert forbidden not in text, (name, forbidden)
print("PASS: HAProxy Compose topology and hardening contract")
PY

if grep -R -n --exclude='haproxy-contract.sh' 'insecure-password' \
    "$ROOT/compose.haproxy.yaml" "$ROOT/haproxy" "$ROOT/scripts/render-haproxy-config.py"; then
  fail 'HAProxy PoC must not permit plaintext userlist passwords'
fi
if grep -En '^[[:space:]]*bind[[:space:]].*(quic|proto[[:space:]]+quic)' \
    "$ROOT/haproxy/haproxy.cfg.tmpl"; then
  fail 'HAProxy PoC unexpectedly enables a QUIC listener'
fi
if grep -Fq 'host_only' "$ROOT/haproxy/haproxy.cfg.tmpl"; then
  fail 'HAProxy Host gate must not normalize and accept arbitrary ports'
fi
test "$(grep -Fc $'\ttimeout client 1h' "$ROOT/haproxy/haproxy.cfg.tmpl")" = 1 ||
  fail 'HAProxy client inactivity timeout does not preserve long agent streams'
test "$(grep -Fc $'\ttimeout server 1h' "$ROOT/haproxy/haproxy.cfg.tmpl")" = 1 ||
  fail 'HAProxy server inactivity timeout does not preserve long agent streams'
test "$(grep -Fc 'acl approved_host hdr(host) -m str __DSH_HOST_AUTHORITY__' \
  "$ROOT/haproxy/haproxy.cfg.tmpl")" = 2 || fail 'exact bare-IP and IP:443 Host ACLs are missing'

grep -Fq "$HAPROXY_INDEX" "$ROOT/compose.haproxy.yaml" || fail 'HAProxy index digest is not pinned'
grep -Fq 'AMD64 child' "$ROOT/compose.haproxy.yaml" || fail 'AMD64 child digest record is missing'
grep -Fq 'ARM64 child' "$ROOT/compose.haproxy.yaml" || fail 'ARM64 child digest record is missing'
grep -Fq "$HAPROXY_AMD64" "$ROOT/compose.haproxy.yaml" || fail 'HAProxy AMD64 child digest is not recorded'
grep -Fq "$HAPROXY_ARM64" "$ROOT/compose.haproxy.yaml" || fail 'HAProxy ARM64 child digest is not recorded'
jq -e --arg amd64 "$HAPROXY_AMD64" --arg arm64 "$HAPROXY_ARM64" '
  .status == "non-publishing-functional-poc" and
  .image.indexDigest == "sha256:fb87fc81943143b9acaea7442973e6ba654035fff76ffe7af6829dd1bcb0f7a5" and
  .image.platforms["linux/amd64"].manifestDigest == $amd64 and
  .image.platforms["linux/arm64"].manifestDigest == $arm64 and
  .image.platforms["linux/amd64"].highMatches == 2 and
  .image.platforms["linux/arm64"].highMatches == 2 and
  .scanSnapshot.rawEvidenceRetained == false and
  .findingReview["CVE-2026-14456"].pocQuicListenerConfigured == false and
  .findingReview["CVE-2026-14456"].decision == "pending-owner-review-no-exception" and
  .acceptance.nativeArm64Functional == "pending" and
  .acceptance.publicationPolicy == "blocked-unapproved-high-findings"
' "$ROOT/policy/haproxy-poc-lock.json" >/dev/null || fail 'HAProxy PoC lock is incoherent'

"$ROOT/scripts/haproxy-test-pki.sh" "$tmp_dir/pki" "$DSH_LAN_IP"
if "$ROOT/scripts/haproxy-test-pki.sh" "$tmp_dir/pki" "$DSH_LAN_IP" \
    >/dev/null 2>&1; then
  fail 'test PKI generator reused an existing output path'
fi
python3 "$ROOT/scripts/render-haproxy-config.py" --output "$HAPROXY_CONFIG"
[[ "$(stat -c '%a' "$HAPROXY_CONFIG")" == 600 ]] || fail 'rendered config is not owner-readable only'
# shellcheck disable=SC2016 # pattern intentionally matches a literal crypt prefix.
grep -Eq 'user dsh-admin password \$5\$' "$HAPROXY_CONFIG" || fail 'SHA-256 crypt userlist was not rendered'
if grep -Eq '__[A-Z0-9_]+__' "$HAPROXY_CONFIG"; then
  fail 'unresolved HAProxy template marker'
fi

if DSH_HAPROXY_USERNAME='bad user' \
    python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/rejected.cfg" \
    >/dev/null 2>&1; then
  fail 'renderer accepted an unsafe username'
fi
if DSH_LAN_IP='host.example' \
    python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/rejected.cfg" \
    >/dev/null 2>&1; then
  fail 'renderer accepted a non-IP authority'
fi
if DSH_LAN_IP='2001:db8::10' \
    python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/rejected.cfg" \
    >/dev/null 2>&1; then
  fail 'renderer accepted IPv6 that the Compose short port syntax cannot bind safely'
fi
if DSH_LAN_IP='0.0.0.0' \
    python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/rejected.cfg" \
    >/dev/null 2>&1; then
  fail 'renderer accepted a wildcard host bind instead of one approved LAN IP'
fi
if DSH_HAPROXY_PASSWORD_HASH='plaintext' \
    python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/rejected.cfg" \
    >/dev/null 2>&1; then
  fail 'renderer accepted a plaintext password'
fi

docker volume create --label 'io.deepseek-harness-container.test=haproxy-contract' "$STAGING_VOLUME" >/dev/null
docker run --rm \
  --platform "$DSH_PLATFORM" \
  --user 0:0 \
  --network none \
  --read-only \
  --cap-drop ALL \
  --cap-add CHOWN \
  --cap-add DAC_OVERRIDE \
  --cap-add FOWNER \
  --security-opt no-new-privileges:true \
  --mount "type=bind,src=$HAPROXY_CONFIG,dst=/input/haproxy.cfg,ro" \
  --mount "type=bind,src=$HAPROXY_CERT,dst=/input/tls.pem,ro" \
  --mount "type=volume,src=$STAGING_VOLUME,dst=/run/haproxy" \
  --entrypoint /bin/sh \
  "$HAPROXY_IMAGE" -eu -c \
  'test -s /input/haproxy.cfg && test -s /input/tls.pem &&
   cp /input/haproxy.cfg /run/haproxy/haproxy.cfg &&
   cp /input/tls.pem /run/haproxy/tls.pem &&
   chown 99:99 /run/haproxy/haproxy.cfg /run/haproxy/tls.pem &&
   chmod 0440 /run/haproxy/haproxy.cfg /run/haproxy/tls.pem'

docker run --rm \
  --platform "$DSH_PLATFORM" \
  --user 99:99 \
  --read-only \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=8m \
  --mount "type=volume,src=$STAGING_VOLUME,dst=/run/haproxy,ro" \
  --entrypoint haproxy \
  "$HAPROXY_IMAGE" -c -f /run/haproxy/haproxy.cfg

echo 'PASS: HAProxy renderer, IP-SAN fixture and non-root config validation'
