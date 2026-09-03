#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly ROOT
readonly CHECKER="$ROOT/scripts/check-release-inputs.py"
readonly UPDATER="$ROOT/scripts/update-release-inputs.py"
readonly MAINTENANCE="$ROOT/.github/workflows/release-inputs-maintenance.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v python3 >/dev/null || fail 'python3 is required'
test -x "$CHECKER" || fail 'release input checker is not executable'
test -x "$UPDATER" || fail 'release input updater is not executable'
python3 "$CHECKER" --validate-only
python3 "$CHECKER"
grep -Fq 'npm view @deepseek-ai/dsh dist-tags --json' "$MAINTENANCE" ||
  fail 'weekly DSH upstream signal capture is missing'
grep -Fq 'docker buildx imagetools inspect --raw "$ref"' "$MAINTENANCE" ||
  fail 'immutable image availability discovery is missing'
if grep -Eq 'permissions:[[:space:]]*(write|all)|docker[[:space:]]+(login|push)' "$MAINTENANCE"; then
  fail 'maintenance workflow gained write or publication capability'
fi
source_digest=$(sha256sum "$ROOT/policy/release-inputs.json" | cut -d' ' -f1)

test_tmp=$(mktemp -d /tmp/dsh-release-inputs-contract.XXXXXX)
cleanup() {
  if [[ -d "$test_tmp" && ! -L "$test_tmp" ]]; then
    find "$test_tmp" -xdev -depth -mindepth 1 -delete
    rmdir "$test_tmp"
  fi
}
trap cleanup EXIT

python3 - "$ROOT/policy/release-inputs.json" "$test_tmp" <<'PY'
import json
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text())
out = pathlib.Path(sys.argv[2])

alpha = json.loads(json.dumps(source))
alpha["release"]["dsh"]["version"] = "0.1.2-alpha.1"
(out / "alpha.json").write_text(json.dumps(alpha), encoding="utf-8")

floating = json.loads(json.dumps(source))
floating["images"]["caddy"]["platforms"]["linux/arm64"]["ref"] = "caddy:latest"
(out / "floating.json").write_text(json.dumps(floating), encoding="utf-8")

exception = json.loads(json.dumps(source))
exception["exceptions"] = [{"id": "CVE-example"}]
(out / "exception.json").write_text(json.dumps(exception), encoding="utf-8")

node_alpha = json.loads(json.dumps(source))
node_alpha["release"]["node"]["version"] = "25.0.0-alpha.1"
(out / "node-alpha.json").write_text(json.dumps(node_alpha), encoding="utf-8")

caddy_beta = json.loads(json.dumps(source))
caddy_beta["images"]["caddy"]["tag"] = "2.12.0-beta.1"
(out / "caddy-beta.json").write_text(json.dumps(caddy_beta), encoding="utf-8")

caddy_child_alpha = json.loads(json.dumps(source))
caddy_child_alpha["images"]["caddy"]["platforms"]["linux/arm64"]["ref"] = (
    "caddy:2.11.4-alpha.1@" +
    caddy_child_alpha["images"]["caddy"]["platforms"]["linux/arm64"]["digest"]
)
(out / "caddy-child-alpha.json").write_text(
    json.dumps(caddy_child_alpha), encoding="utf-8"
)
PY

if python3 "$CHECKER" --validate-only --inputs "$test_tmp/alpha.json" >/dev/null 2>&1; then
  fail 'alpha proposal was accepted'
fi
if python3 "$CHECKER" --validate-only --inputs "$test_tmp/floating.json" >/dev/null 2>&1; then
  fail 'floating image proposal was accepted'
fi
if python3 "$UPDATER" --root "$ROOT" "$test_tmp/exception.json" >/dev/null 2>&1; then
  fail 'proposal carrying exceptions was accepted by updater'
fi
if python3 "$CHECKER" --validate-only --inputs "$test_tmp/node-alpha.json" >/dev/null 2>&1; then
  fail 'Node alpha proposal was accepted'
fi
if python3 "$CHECKER" --validate-only --inputs "$test_tmp/caddy-beta.json" >/dev/null 2>&1; then
  fail 'Caddy beta proposal was accepted'
fi
if python3 "$UPDATER" --root "$ROOT" "$test_tmp/caddy-child-alpha.json" >/dev/null 2>&1; then
  fail 'Caddy alpha child ref was accepted under a stable top-level tag'
fi

python3 - "$ROOT" "$test_tmp" <<'PY'
import json
import pathlib
import shutil
import sys

source, output = map(pathlib.Path, sys.argv[1:])
variants = {
    "root-digest": ("native-amd64-lock.json", "nodeBaseAmd64", "node:99@sha256:" + "9" * 64),
    "root-alpha": (
        "native-arm64-lock.json",
        "caddyArm64",
        "caddy:2.11.4-alpha.1@sha256:1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba",
    ),
    "root-substring": (
        "native-arm64-lock.json",
        "caddyArm64",
        "caddy:2.11.40@sha256:1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba",
    ),
    "root-digest-only": (
        "native-arm64-lock.json",
        "caddyArm64",
        "caddy@sha256:1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba",
    ),
}
for name, (lock_name, key, replacement) in variants.items():
    destination = output / name
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(".git", "artifacts"))
    lock_path = destination / "policy" / lock_name
    lock = json.loads(lock_path.read_text())
    lock["images"][key] = replacement
    lock_path.write_text(json.dumps(lock), encoding="utf-8")
PY
if python3 "$test_tmp/root-digest/scripts/check-release-inputs.py" \
  --root "$test_tmp/root-digest" >/dev/null 2>&1; then
  fail 'native AMD64 lock image drift was accepted'
fi
if python3 "$test_tmp/root-alpha/scripts/check-release-inputs.py" \
  --root "$test_tmp/root-alpha" >/dev/null 2>&1; then
  fail 'native ARM64 lock alpha tag drift was accepted with the expected digest'
fi
if python3 "$test_tmp/root-substring/scripts/check-release-inputs.py" \
  --root "$test_tmp/root-substring" >/dev/null 2>&1; then
  fail 'native ARM64 lock substring tag drift was accepted with the expected digest'
fi
if python3 "$test_tmp/root-digest-only/scripts/check-release-inputs.py" \
  --root "$test_tmp/root-digest-only" >/dev/null 2>&1; then
  fail 'native ARM64 lock lost its required Caddy tag with the expected digest'
fi

test "$(sha256sum "$ROOT/policy/release-inputs.json" | cut -d' ' -f1)" = "$source_digest" ||
  fail 'release input contract changed the ledger'
echo 'PASS: release input schema, coherence, alpha/floating and exception guards'
