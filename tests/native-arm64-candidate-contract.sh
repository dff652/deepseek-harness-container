#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly ROOT
readonly SCRIPT="$ROOT/scripts/build-native-arm64-candidate.sh"
readonly PREFLIGHT_CONTRACT="$ROOT/tests/native-arm64-host-preflight-contract.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test -x "$SCRIPT" || fail 'native ARM64 candidate script is not executable'
bash "$PREFLIGHT_CONTRACT"
bash -n "$SCRIPT"
command -v shellcheck >/dev/null || fail 'shellcheck is required'
shellcheck -S error "$SCRIPT"

grep -Fq 'test "$(uname -m)" = aarch64' "$SCRIPT" || fail 'native aarch64 check missing'
grep -Fq 'policy/release-inputs.json' "$SCRIPT" || fail 'ledger input missing'
grep -Fq -- '--driver docker-container' "$SCRIPT" || fail 'dedicated docker-container builder missing'
grep -Fq -- '--driver-opt "image=$BUILDKIT_REF"' "$SCRIPT" || fail 'digest-pinned BuildKit builder missing'
grep -Fq 'grep -Fq "$BUILDKIT_REF"' "$SCRIPT" || fail 'builder digest verification missing'
grep -Fq 'timeout --signal=TERM --kill-after=30s' "$SCRIPT" || fail 'hard timeout boundary missing'
grep -Fq 'run_step env DSH_IMAGE="$IMAGE_TAG"' "$SCRIPT" || fail 'runtime gate timeout missing'
grep -Fq 'forced-runner-verified-git-archive' "$SCRIPT" || fail 'verified archive source mode missing'
grep -Fq -- '--platform linux/arm64' "$SCRIPT" || fail 'native ARM64 build target missing'
grep -Fq 'tests/compose-contract.sh' "$SCRIPT" || fail 'Compose static gate missing'
grep -Fq 'tests/negative-exposure.sh' "$SCRIPT" || fail 'negative exposure gate missing'
grep -Fq 'tests/native-workflow-contract.sh' "$SCRIPT" || fail 'native workflow gate missing'
grep -Fq 'tests/arm64-runtime.sh' "$SCRIPT" || fail 'ARM64 runtime gate missing'
grep -Fq 'tests/rc2-regression.sh' "$SCRIPT" || fail 'rc.2 regression gate missing'
grep -Fq 'audit-loaded-runtime-cve.sh' "$SCRIPT" || fail 'runtime CVE evidence gate missing'
grep -Fq 'tests/offline-image-archive.sh' "$SCRIPT" || fail 'offline archive gate missing'
grep -Fq 'tests/haproxy-contract.sh' "$SCRIPT" || fail 'gateway contract gate missing'
grep -Fq 'tests/haproxy-runtime.sh' "$SCRIPT" || fail 'gateway runtime gate missing'
grep -Fq 'tests/haproxy-compose-runtime.sh' "$SCRIPT" || fail 'gateway Compose gate missing'
grep -Fq 'SHA256SUMS' "$SCRIPT" || fail 'candidate checksum output missing'
grep -Fq 'dsh-sbom.syft.json' "$SCRIPT" || fail 'DSH SBOM evidence missing'
grep -Fq 'caddy-sbom.syft.json' "$SCRIPT" || fail 'Caddy SBOM evidence missing'
grep -Fq 'haproxy-sbom.syft.json' "$SCRIPT" || fail 'HAProxy SBOM evidence missing'
grep -Fq 'supply-chain-policy-summary.json' "$SCRIPT" || fail 'supply-chain policy gate missing'
grep -Fq 'BUILDX_METADATA_PROVENANCE=max' "$SCRIPT" || fail 'BuildKit provenance metadata missing'
grep -Fq 'external-native-arm64-candidate-built-not-released' "$SCRIPT" || fail 'candidate-only status missing'
grep -Fq 'external-native-arm64-evidence-blocked-not-released' "$SCRIPT" || fail 'blocked evidence status missing'
grep -Fq 'DSH_NATIVE_POLICY_MODE' "$SCRIPT" || fail 'explicit policy mode missing'
grep -Fq 'startswith("vulnerability: unapproved ")' "$SCRIPT" || fail 'collect mode vulnerability-only boundary missing'
grep -Fq 'docker buildx rm --force "$BUILDER_NAME"' "$SCRIPT" || fail 'owned builder cleanup missing'

if grep -Eiq 'qemu|binfmt|docker[[:space:]]+(login|push)|--privileged' "$SCRIPT"; then
  fail 'native ARM64 script contains emulation or publication assumptions'
fi

echo 'PASS: generic native ARM64 candidate script is pinned, gated and candidate-only'
