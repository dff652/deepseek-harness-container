#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly HAPROXY_INDEX='haproxy:3.4.3-alpine3.24@sha256:fb87fc81943143b9acaea7442973e6ba654035fff76ffe7af6829dd1bcb0f7a5'
readonly HAPROXY_AMD64='sha256:c7f5037a567378929d0aba734eb78b73497209c72456519420ce5e68a42d60ac'
readonly HAPROXY_ARM64='sha256:0fe6e31a91ad42440ceba4419694189673f9773f90b985bd883db0054a7c5259'
readonly HAPROXY_AMD64_TAG='haproxy:dsh-offline-3.4.3-amd64-c7f5037a5673'
readonly HAPROXY_ARM64_TAG='haproxy:dsh-offline-3.4.3-arm64-0fe6e31a91ad'

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
export DSH_HTTPS_PORT=443
export DSH_WORKSPACE="$tmp_dir/workspace"
export HAPROXY_CONFIG="$tmp_dir/haproxy.cfg"
export HAPROXY_CERT="$tmp_dir/pki/tls.pem"
export DSH_HAPROXY_USERNAME='dsh-admin'
# Test-only 1000 rounds keep zero-warning deterministic under QEMU.
# shellcheck disable=SC2016 # crypt hashes must remain literal.
export DSH_HAPROXY_PASSWORD_HASH='$5$rounds=1000$dshpoc01$JV4p6OtCPE9397xXoWE1webmlCmF8waJmDLWnO5GFr/'
export HAPROXY_IMAGE=${CONTRACT_HAPROXY_IMAGE:-$HAPROXY_AMD64_TAG}

docker image inspect "$HAPROXY_IMAGE" >/dev/null 2>&1 ||
  fail "HAProxy offline tag is not loaded: $HAPROXY_IMAGE"
test "$(docker image inspect "$HAPROXY_IMAGE" --format '{{.Os}}/{{.Architecture}}')" = \
  "$DSH_PLATFORM" || fail 'HAProxy offline tag architecture does not match the contract platform'
case "$HAPROXY_IMAGE" in
  *@sha256:*|*latest|*:*@*) fail 'HAProxy contract requires a dedicated offline tag, not a digest-only reference' ;;
esac
[[ "$HAPROXY_IMAGE" =~ :dsh-offline-[[:alnum:]._-]+-(amd64|arm64)-[0-9a-f]{12,64}$ ]] ||
  fail 'HAProxy image does not use a parseable architecture-specific offline tag'
grep -Fq "HAPROXY_IMAGE=$HAPROXY_ARM64_TAG" "$ROOT/.env.haproxy.example" ||
  fail 'ARM64 offline image tag is not recorded in the environment example'
grep -Fq "HAPROXY_IMAGE=$HAPROXY_AMD64_TAG" "$ROOT/.env.haproxy.example" ||
  fail 'AMD64 offline image tag is not recorded in the environment example'
grep -Fxq 'DSH_HTTPS_PORT=443' "$ROOT/.env.haproxy.example" ||
  fail 'HAProxy environment example does not keep the candidate on host TCP 443'

rendered="$tmp_dir/compose.json"
docker compose -f "$ROOT/compose.haproxy.yaml" config --format json >"$rendered"
python3 - "$rendered" "$DSH_IMAGE" "$DSH_PLATFORM" "$HAPROXY_IMAGE" <<'PY'
import json
import pathlib
import re
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
assert expected_platform in {"linux/amd64", "linux/arm64"}
assert dsh["user"] == "10001:10001"
assert dsh["read_only"] is True
assert dsh["restart"] == "unless-stopped"
assert dsh["healthcheck"]["test"][:3] == ["CMD", "node", "-e"]
assert dsh["healthcheck"]["interval"] == "10s"
assert dsh["healthcheck"]["timeout"] == "5s"
assert dsh["healthcheck"]["start_period"] == "20s"
assert len(dsh["ports"]) == 1
port = dsh["ports"][0]
assert port["host_ip"] == "192.0.2.10"
assert port["target"] == 443 and str(port["published"]) == "443"
assert port["protocol"] == "tcp"
assert not any(str(item.get("target")) == "3080" for item in dsh.get("ports", []))
assert proxy["pull_policy"] == "never"
assert proxy["network_mode"] == "service:dsh"
assert proxy["read_only"] is True
assert proxy["user"] == "99:99"
assert proxy["cap_drop"] == ["ALL"]
assert proxy["cap_add"] == ["NET_BIND_SERVICE"]
assert proxy["security_opt"] == ["no-new-privileges:true"]
assert proxy["command"] == ["-f", "/run/haproxy/haproxy.cfg"]
assert proxy["restart"] == "unless-stopped"
assert proxy["healthcheck"]["test"] == ["CMD", "haproxy", "-c", "-f", "/run/haproxy/haproxy.cfg"]
assert proxy["healthcheck"]["interval"] == "10s"
assert proxy["healthcheck"]["timeout"] == "5s"
assert proxy["healthcheck"]["start_period"] == "5s"
assert "ports" not in proxy
assert proxy["depends_on"]["haproxy-init"]["condition"] == "service_completed_successfully"
assert init["network_mode"] == "none"
assert init["user"] == "0:0"
assert init["read_only"] is True
assert init["cap_drop"] == ["ALL"]
assert init["cap_add"] == ["CHOWN", "DAC_OVERRIDE", "FOWNER"]
assert init["security_opt"] == ["no-new-privileges:true"]
assert init["restart"] == "no"
init_mounts = {item["target"]: item for item in init["volumes"]}
assert init_mounts["/input/haproxy.cfg"]["read_only"] is True
assert init_mounts["/input/tls.pem"]["read_only"] is True
assert init_mounts["/run/haproxy"].get("read_only", False) is False
assert proxy["volumes"] == [{"type": "volume", "source": "haproxy-runtime", "target": "/run/haproxy", "read_only": True, "volume": {}}]
assert dsh["volumes"][0]["source"] == "dsh-home"
assert dsh["volumes"][0]["target"] == "/var/lib/dsh"
assert dsh["volumes"][1]["type"] == "bind" and dsh["volumes"][1]["target"] == "/workspace"
volumes = document["volumes"]
assert volumes["dsh-home"]["labels"]["io.deepseek-harness-container.volume-scope"] == "persistent-dsh-home"
assert volumes["haproxy-runtime"]["labels"]["io.deepseek-harness-container.volume-scope"] == "restart-scoped-gateway"
assert "@sha256:" not in expected_haproxy_image
assert re.search(r":dsh-offline-[A-Za-z0-9._-]+-(amd64|arm64)-[0-9a-f]{12,64}$", expected_haproxy_image)
tag_arch = re.search(r"-(amd64|arm64)-[0-9a-f]{12,64}$", expected_haproxy_image).group(1)
assert tag_arch == expected_platform.rsplit("/", 1)[1]
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
grep -Fq '# QUIC contract: the upstream binary may be built with OpenSSL QUIC support' \
  "$ROOT/haproxy/haproxy.cfg.tmpl" || fail 'OpenSSL QUIC-disabled contract evidence is missing'
if grep -En '^[[:space:]]*(bind|server)[[:space:]].*(udp|quic|quic4|quic6)' \
    "$ROOT/haproxy/haproxy.cfg.tmpl"; then
  fail 'HAProxy template contains a UDP or QUIC endpoint'
fi
grep -Fq 'ssl-min-ver TLSv1.2' "$ROOT/haproxy/haproxy.cfg.tmpl" ||
  fail 'HAProxy TLS minimum is not pinned to TLS 1.2'
if grep -Fq 'host_only' "$ROOT/haproxy/haproxy.cfg.tmpl"; then
  fail 'HAProxy Host gate must not normalize and accept arbitrary ports'
fi
test "$(grep -Fc $'\ttimeout client 1h' "$ROOT/haproxy/haproxy.cfg.tmpl")" = 1 ||
  fail 'HAProxy client inactivity timeout does not preserve long agent streams'
test "$(grep -Fc $'\ttimeout server 1h' "$ROOT/haproxy/haproxy.cfg.tmpl")" = 1 ||
  fail 'HAProxy server inactivity timeout does not preserve long agent streams'
test "$(grep -Fc 'acl approved_host hdr(host) -m str __DSH_HOST_AUTHORITY__' \
  "$ROOT/haproxy/haproxy.cfg.tmpl")" = 1 || fail 'exact rendered Host ACL is missing or duplicated'
test "$(grep -Fc 'acl approved_origin hdr(Origin) -m str' \
  "$ROOT/haproxy/haproxy.cfg.tmpl")" = 1 || fail 'exact rendered Origin ACL is missing or duplicated'

grep -Fq "$HAPROXY_INDEX" "$ROOT/compose.haproxy.yaml" || fail 'HAProxy index digest is not pinned'
grep -Fq 'AMD64 child' "$ROOT/compose.haproxy.yaml" || fail 'AMD64 child digest record is missing'
grep -Fq 'ARM64 child' "$ROOT/compose.haproxy.yaml" || fail 'ARM64 child digest record is missing'
grep -Fq "$HAPROXY_AMD64" "$ROOT/compose.haproxy.yaml" || fail 'HAProxy AMD64 child digest is not recorded'
grep -Fq "$HAPROXY_ARM64" "$ROOT/compose.haproxy.yaml" || fail 'HAProxy ARM64 child digest is not recorded'
jq -e '.services.dsh.ports | all(.[]; .protocol == "tcp" and (.target == 443) and ((.published | tostring) == "443"))' \
  "$rendered" >/dev/null || fail 'Compose exposes a non-TCP or non-443 HAProxy port'
jq -e '.services.dsh.ports | all(.[]; .protocol != "udp" and .target != 3080)' \
  "$rendered" >/dev/null || fail 'Compose exposes UDP or DSH port 3080'
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
openssl verify -CAfile "$tmp_dir/pki/ca.crt" -verify_ip "$DSH_LAN_IP" \
  "$tmp_dir/pki/server.crt" >/dev/null || fail 'generated certificate does not verify for the approved IP SAN'
openssl x509 -in "$tmp_dir/pki/server.crt" -noout -ext subjectAltName |
  grep -Fq "IP Address:$DSH_LAN_IP" || fail 'generated certificate lacks the approved IP SAN'
if "$ROOT/scripts/haproxy-test-pki.sh" "$tmp_dir/ipv6" '2001:db8::10' \
    >/dev/null 2>&1; then
  fail 'test PKI generator accepted an unsupported IPv6 authority'
fi
python3 "$ROOT/scripts/render-haproxy-config.py" --output "$HAPROXY_CONFIG"
[[ "$(stat -c '%a' "$HAPROXY_CONFIG")" == 600 ]] || fail 'rendered config is not owner-readable only'
# shellcheck disable=SC2016 # pattern intentionally matches a literal crypt prefix.
grep -Eq 'user dsh-admin password \$5\$' "$HAPROXY_CONFIG" || fail 'SHA-256 crypt userlist was not rendered'
if grep -Eq '__[A-Z0-9_]+__' "$HAPROXY_CONFIG"; then
  fail 'unresolved HAProxy template marker'
fi
if grep -Fq '192.0.2.10:443' "$HAPROXY_CONFIG"; then
  fail 'default HTTPS authority should be canonicalized to the bare IP'
fi
DSH_HTTPS_PORT=8443 python3 "$ROOT/scripts/render-haproxy-config.py" \
  --output "$tmp_dir/haproxy-8443.cfg"
grep -Fq 'hdr(host) -m str 192.0.2.10:8443' "$tmp_dir/haproxy-8443.cfg" ||
  fail 'non-default HTTPS port is absent from the exact Host ACL'
grep -Fq 'https://192.0.2.10:8443' "$tmp_dir/haproxy-8443.cfg" ||
  fail 'non-default HTTPS port is absent from the exact Origin ACL'

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
if DSH_HTTPS_PORT=0 \
    python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/rejected.cfg" \
    >/dev/null 2>&1; then
  fail 'renderer accepted an invalid HTTPS port'
fi
if DSH_HAPROXY_PASSWORD_HASH='plaintext' \
    python3 "$ROOT/scripts/render-haproxy-config.py" --output "$tmp_dir/rejected.cfg" \
    >/dev/null 2>&1; then
  fail 'renderer accepted a plaintext password'
fi

build_options=$(docker run --rm --platform "$DSH_PLATFORM" --entrypoint haproxy \
  "$HAPROXY_IMAGE" -vv)
grep -Fq 'USE_QUIC=1' <<<"$build_options" ||
  fail 'HAProxy image build evidence did not report its OpenSSL QUIC capability'
printf '%s\n' 'PASS: OpenSSL QUIC support is compiled but the candidate contract configures no QUIC listener or UDP 443 exposure'

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
