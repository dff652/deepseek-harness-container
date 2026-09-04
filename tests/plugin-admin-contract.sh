#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fail() { echo "FAIL: $*" >&2; exit 1; }

script="$ROOT/scripts/plugin-admin.sh"
compose="$ROOT/compose.plugin-admin.yaml"
dockerfile="$ROOT/Dockerfile"
[[ -f "$script" ]] || fail 'plugin-admin script is missing'
[[ -x "$script" ]] || fail 'plugin-admin script is not executable'
[[ -f "$compose" ]] || fail 'plugin-admin Compose file is missing'
grep -Fq 'FROM build AS plugin-admin' "$dockerfile" || fail 'plugin-admin Dockerfile target is missing'
grep -Fq 'COPY --chown=10001:10001 scripts/plugin-admin.sh' "$dockerfile" || fail 'plugin-admin entrypoint is not copied'
grep -Fq 'ENTRYPOINT ["/usr/local/bin/plugin-admin.sh"]' "$dockerfile" || fail 'plugin-admin entrypoint is not fixed'
grep -Fq 'ln -s /opt/corepack/v1/pnpm/11.7.0/bin/pnpm.mjs /opt/pnpm-bin/pnpm' "$dockerfile" ||
  fail 'plugin-admin exact pnpm launcher is missing'
grep -Fq 'PATH=/opt/pnpm-bin:' "$dockerfile" ||
  fail 'plugin-admin must use the cached exact pnpm binary, not the network-resolving Corepack shim'

bash -n "$script"
grep -Fq -- '--offline' "$script" || fail 'offline pnpm flag is missing'
grep -Fq -- '--ignore-scripts' "$script" || fail 'ignore-scripts guard is missing'
grep -Fq 'DEFAULT_DSH_HOME=/var/lib/dsh' "$script" || fail 'admin DSH_HOME boundary is missing'
grep -Fq 'must be a regular non-symlink file' "$script" || fail 'ordinary tarball check is missing'
grep -Fq 'SHA-256 does not match' "$script" || fail 'digest mismatch is not fail-closed'
grep -Fq 'add|remove|list' "$script" || fail 'action allowlist is missing'
grep -Fq 'node_dsh plugin --profile "$PROFILE" list' "$script" || fail 'list action is not forwarded to pnpm'
! grep -Fq 'list --offline' "$script" || fail 'pnpm list rejects install-only --offline'
! grep -Fq 'remove --offline' "$script" || fail 'pnpm remove rejects install-only --offline'
grep -Fq 'web|headless|disposable' "$script" || fail 'profile allowlist is missing'
grep -Fq 'PLUGIN_ADMIN_DUMP_CONFIG=1' "$script" || fail 'dump-config opt-in is missing'
grep -Fq 'RUN_DIR=$(mktemp -d' "$script" || fail 'unique evidence run directory is missing'
grep -Fq 'node_dsh_dump' "$script" || fail 'explicit dump environment path is missing'

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$script"
fi

runtime_section=$(sed -n '/^FROM --platform=.* AS runtime$/,$p' "$dockerfile")
! grep -Fq 'plugin-admin.sh' <<<"$runtime_section" || fail 'production runtime references plugin-admin'
! grep -Fq 'FROM plugin-admin' <<<"$runtime_section" || fail 'production runtime is based on plugin-admin'

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/inputs" "$tmp_dir/evidence"
export DSH_PLUGIN_INPUTS="$tmp_dir/inputs"
export DSH_PLUGIN_EVIDENCE="$tmp_dir/evidence"
export PLUGIN_ADMIN_PROFILE=headless
export PLUGIN_ADMIN_ACTION=list

if command -v docker >/dev/null 2>&1; then
  rendered="$tmp_dir/compose.json"
  docker compose -f "$compose" config --format json > "$rendered"
  python3 - "$rendered" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert set(doc["services"]) == {"plugin-admin"}, doc["services"].keys()
service = doc["services"]["plugin-admin"]
assert service["build"]["target"] == "plugin-admin"
assert service["platform"] == "linux/arm64"
assert service["network_mode"] == "none"
assert service["pull_policy"] == "never"
assert service["read_only"] is True
assert service["user"] == "10001:10001"
assert service["cap_drop"] == ["ALL"]
assert service["security_opt"] == ["no-new-privileges:true"]
assert "ports" not in service
assert service["environment"]["DSH_HOME"] == "/var/lib/dsh"
assert service["environment"]["PLUGIN_ADMIN_DUMP_CONFIG"] == "0"
assert service["environment"]["PLUGIN_ADMIN_HOME_VOLUME"] == "dsh-plugin-admin-candidate-home"
assert service["environment"]["DSH_AIAH_COMMAND"] == ""
volumes = service["volumes"]
assert any(v["target"] == "/var/lib/dsh" for v in volumes)
assert any(v["target"] == "/inputs" and v.get("read_only") is True for v in volumes)
assert any(v["target"] == "/evidence" and v.get("read_only") is not True for v in volumes)
assert "dsh-home" not in json.dumps(doc)
assert doc["volumes"]["plugin-admin-home"]["name"] == "dsh-plugin-admin-candidate-home"
text = json.dumps(doc).lower()
for forbidden in ("privileged", "docker.sock", "network_mode: host", "sys_admin", "net_admin", "latest"):
    assert forbidden not in text, forbidden
print("PASS: plugin-admin Compose security contract")
PY

custom_rendered="$tmp_dir/compose-custom.json"
DSH_PLUGIN_HOME_VOLUME=reviewed-candidate-home \
  docker compose -f "$compose" config --format json > "$custom_rendered"
python3 - "$custom_rendered" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert doc["volumes"]["plugin-admin-home"]["name"] == "reviewed-candidate-home"
assert doc["services"]["plugin-admin"]["environment"]["PLUGIN_ADMIN_HOME_VOLUME"] == "reviewed-candidate-home"
print("PASS: explicit candidate volume selection contract")
PY
fi

echo 'PASS: plugin-admin contract'
