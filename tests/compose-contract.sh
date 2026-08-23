#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p -- "$tmp_dir/workspace"

# Documentation-only test values. They are reserved/test values and are never
# used as production credentials or topology.
export DSH_IMAGE='local/dsh:0.1.1-rc.1-arm64'
export DSH_LAN_IP='192.0.2.10'
export DSH_WORKSPACE="$tmp_dir/workspace"
export DSH_CADDY_USERNAME='dsh-admin'
export DSH_CADDY_PASSWORD_HASH='test-bcrypt-hash'

command -v docker >/dev/null || {
  echo 'FAIL: docker is required for Compose contract validation' >&2
  exit 1
}
grep -Fq 'CADDY_IMAGE:-caddy:2.11.4@sha256:1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba' \
  "$ROOT/compose.yaml" || {
  echo 'FAIL: ARM64 Caddy default cannot be overridden by the verified offline tag' >&2
  exit 1
}
grep -Fq 'CADDY_IMAGE=caddy:dsh-offline-2.11.4-arm64-1172d4213087' \
  "$ROOT/.env.example" || {
  echo 'FAIL: ARM64 offline Caddy tag is missing from the environment example' >&2
  exit 1
}

rendered="$tmp_dir/compose.json"
docker compose -f "$ROOT/compose.yaml" config --format json >"$rendered"

python3 - "$rendered" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text())
services = document.get("services", {})
assert set(services) == {"dsh", "caddy", "caddy-init"}, services.keys()
dsh = services["dsh"]
caddy = services["caddy"]
caddy_init = services["caddy-init"]

assert dsh["image"] == "local/dsh:0.1.1-rc.1-arm64", dsh["image"]
assert dsh["platform"] == "linux/arm64", dsh["platform"]
assert dsh["pull_policy"] == "never", dsh["pull_policy"]
assert dsh["command"] == ["web", "--host", "127.0.0.1", "--port", "3080", "--no-open"]
assert dsh["read_only"] is True
assert dsh["user"] == "10001:10001"
assert dsh["cap_drop"] == ["ALL"]
assert dsh["security_opt"] == ["no-new-privileges:true"]
assert caddy["network_mode"] == "service:dsh"
assert caddy["platform"] == "linux/arm64"
assert caddy["image"] == (
    "caddy:2.11.4@sha256:"
    "1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba"
)
assert caddy["pull_policy"] == "never"
assert caddy["read_only"] is True
assert caddy["user"] == "1000:1000"
assert caddy["cap_drop"] == ["ALL"]
assert caddy["cap_add"] == ["NET_BIND_SERVICE"]
assert caddy["security_opt"] == ["no-new-privileges:true"]
assert caddy["depends_on"]["caddy-init"]["condition"] == "service_completed_successfully"
assert caddy_init["image"] == caddy["image"]
assert caddy_init["network_mode"] == "none"
assert caddy_init["user"] == "0:0"
assert caddy_init["read_only"] is True
assert caddy_init["cap_drop"] == ["ALL"]
assert caddy_init["cap_add"] == ["CHOWN"]
assert caddy_init["security_opt"] == ["no-new-privileges:true"]
assert caddy_init["restart"] == "no"

ports = dsh.get("ports", [])
assert len(ports) == 1, ports
port = ports[0]
assert port["host_ip"] == "192.0.2.10", port
assert str(port["published"]) == "443", port
assert str(port["target"]) == "443", port
assert port["protocol"] == "tcp", port
assert not any(p.get("published") == 3080 for p in ports)
assert "ports" not in caddy, caddy.get("ports")
assert "ports" not in caddy_init, caddy_init.get("ports")

for name, service in services.items():
    text = json.dumps(service, sort_keys=True)
    for forbidden in ("network_mode: host", "privileged", "/var/run/docker.sock", "SYS_ADMIN", "NET_ADMIN", "/:/", "/root:/", "/home:/", ":/home"):
        assert forbidden not in text, (name, forbidden)
    assert "latest" not in text.lower(), (name, text)

print("PASS: Compose topology and security contract")
PY

echo "PASS: rendered Compose contract"
