#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly ROOT
readonly SCRIPT="$ROOT/scripts/preflight-native-arm64-host.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test -x "$SCRIPT" || fail 'native ARM64 host preflight is not executable'
bash -n "$SCRIPT"
command -v shellcheck >/dev/null || fail 'shellcheck is required'
shellcheck -S error "$SCRIPT"

grep -Fq 'test "$(uname -m)" = aarch64' "$SCRIPT" || fail 'native architecture check missing'
grep -Fq 'status --porcelain' "$SCRIPT" || fail 'clean source check missing'
grep -Fq 'docker info' "$SCRIPT" || fail 'Docker daemon check missing'
grep -Fq 'docker buildx version' "$SCRIPT" || fail 'Buildx check missing'
grep -Fq '.images.buildkit.ref' "$SCRIPT" || fail 'BuildKit ledger pin missing'
grep -Fq 'docker image inspect "$BUILDKIT_REF"' "$SCRIPT" || fail 'local BuildKit image check missing'
grep -Fq '.tools.syft.version' "$SCRIPT" || fail 'Syft ledger pin missing'
grep -Fq '.tools.grype.version' "$SCRIPT" || fail 'Grype ledger pin missing'
grep -Fq '6291456' "$SCRIPT" || fail '6 GiB disk floor missing'
grep -Fq 'docker-container' "$SCRIPT" || fail 'existing builder driver check missing'

if grep -Eiq 'docker[[:space:]]+(pull|push|login)|buildx[[:space:]]+(create|rm)|curl|wget|sudo|apt(-get)?|dnf|yum|apk' "$SCRIPT"; then
  fail 'preflight contains a host mutation, download, or publication command'
fi

echo 'PASS: native ARM64 host preflight is read-only and ledger-pinned'
