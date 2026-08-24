#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d /tmp/dsh-amd64-contract.XXXXXX)
case "$tmp_dir" in /tmp/dsh-amd64-contract.*) ;; *) exit 1;; esac
mkdir -p -- "$tmp_dir/workspace"
cleanup() {
  if [[ "$tmp_dir" == /tmp/dsh-amd64-contract.* ]]; then
    for rendered_file in "$tmp_dir/compose.json" "$tmp_dir/compose-custom-port.json"; do
      if [[ -f "$rendered_file" && ! -L "$rendered_file" ]]; then
        rm -- "$rendered_file"
      fi
    done
  fi
  if [[ "$tmp_dir" == /tmp/dsh-amd64-contract.* && -d "$tmp_dir/workspace" ]]; then
    rmdir -- "$tmp_dir/workspace"
  fi
  if [[ "$tmp_dir" == /tmp/dsh-amd64-contract.* && -d "$tmp_dir" ]]; then
    rmdir -- "$tmp_dir"
  fi
}
trap cleanup EXIT

export DSH_IMAGE='local/dsh:0.1.1-rc.1-amd64'
export DSH_LAN_IP='192.0.2.10'
unset DSH_HTTPS_PORT
export DSH_EXTERNAL_AUTHORITY='192.0.2.10'
export DSH_WORKSPACE="$tmp_dir/workspace"
export DSH_CADDY_USERNAME='dsh-admin'
export DSH_CADDY_PASSWORD_HASH='test-bcrypt-hash'

grep -Fq 'CADDY_IMAGE:-caddy:2.11.4@sha256:98eb57d882ccd5213d1688764db10c1ca2c58a1ca3a6717a3411ad798f7a423a' \
  "$ROOT/compose.amd64.yaml" || {
  echo 'FAIL: AMD64 Caddy default cannot be overridden by the verified offline tag' >&2
  exit 1
}
grep -Fq 'CADDY_IMAGE=caddy:dsh-offline-2.11.4-amd64-98eb57d882cc' \
  "$ROOT/.env.amd64.example" || {
  echo 'FAIL: AMD64 offline Caddy tag is missing from the environment example' >&2
  exit 1
}
grep -Fq 'DSH_HTTPS_PORT=443' "$ROOT/.env.amd64.example" || {
  echo 'FAIL: AMD64 offline environment example lacks the HTTPS port' >&2
  exit 1
}
grep -Fq 'DSH_EXTERNAL_AUTHORITY=' "$ROOT/.env.amd64.example" || {
  echo 'FAIL: AMD64 offline environment example lacks the exact authority' >&2
  exit 1
}

rendered="$tmp_dir/compose.json"
docker compose \
  -f "$ROOT/compose.yaml" \
  -f "$ROOT/compose.amd64.yaml" \
  config --format json >"$rendered"

python3 - "$rendered" <<'PY'
import json
import pathlib
import sys

services = json.loads(pathlib.Path(sys.argv[1]).read_text())["services"]
dsh = services["dsh"]
caddy = services["caddy"]
caddy_init = services["caddy-init"]
expected_caddy = (
    "caddy:2.11.4@sha256:"
    "98eb57d882ccd5213d1688764db10c1ca2c58a1ca3a6717a3411ad798f7a423a"
)
assert dsh["image"] == "local/dsh:0.1.1-rc.1-amd64"
assert dsh["platform"] == "linux/amd64"
assert caddy["platform"] == "linux/amd64"
assert caddy_init["platform"] == "linux/amd64"
assert caddy["image"] == expected_caddy
assert caddy_init["image"] == expected_caddy
assert dsh["pull_policy"] == caddy["pull_policy"] == "never"
assert caddy["network_mode"] == "service:dsh"
assert caddy["environment"]["DSH_EXTERNAL_AUTHORITY"] == "192.0.2.10"
assert str(dsh["ports"][0]["published"]) == "443"
assert str(dsh["ports"][0]["target"]) == "443"
assert not any(str(port.get("published")) == "3080" for port in dsh.get("ports", []))
assert "ports" not in caddy and "ports" not in caddy_init
print("PASS: amd64 Compose override preserves the appliance security boundary")
PY

export DSH_HTTPS_PORT='8443'
export DSH_EXTERNAL_AUTHORITY='192.0.2.10:8443'
custom_rendered="$tmp_dir/compose-custom-port.json"
docker compose \
  -f "$ROOT/compose.yaml" \
  -f "$ROOT/compose.amd64.yaml" \
  config --format json >"$custom_rendered"
python3 - "$custom_rendered" <<'PY'
import json
import pathlib
import sys

services = json.loads(pathlib.Path(sys.argv[1]).read_text())["services"]
dsh = services["dsh"]
caddy = services["caddy"]
port = dsh["ports"][0]
assert port["host_ip"] == "192.0.2.10", port
assert str(port["published"]) == "8443", port
assert str(port["target"]) == "443", port
assert caddy["environment"]["DSH_EXTERNAL_AUTHORITY"] == "192.0.2.10:8443"
assert not any(str(p.get("published")) == "3080" for p in dsh.get("ports", []))
print("PASS: amd64 custom HTTPS port and exact authority contract")
PY
