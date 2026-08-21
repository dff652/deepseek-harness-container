#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$ROOT/.github/workflows/publish-dockerhub-candidate.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'workflow_dispatch:' "$workflow" || fail 'publication is not manual'
grep -Fq "inputs.confirm == 'publish-candidate'" "$workflow" || fail 'confirmation gate missing'
grep -Fq 'runner: ubuntu-24.04' "$workflow" || fail 'native amd64 runner missing'
grep -Fq 'runner: ubuntu-24.04-arm' "$workflow" || fail 'native arm64 runner missing'
# shellcheck disable=SC2016 # Inspect the literal GitHub expression.
grep -Fq 'TARGETPLATFORM=${{ matrix.platform }}' "$workflow" || fail 'explicit target platform missing'
grep -Fq 'tests/amd64-runtime.sh' "$workflow" || fail 'amd64 runtime smoke missing'
grep -Fq 'tests/arm64-runtime.sh' "$workflow" || fail 'arm64 runtime smoke missing'
# shellcheck disable=SC2016 # Inspect literal workflow shell variables.
grep -Fq '${CANDIDATE_VERSION}-${ARCHITECTURE}-candidate' "$workflow" || fail 'architecture candidate tag missing'
# shellcheck disable=SC2016 # Inspect literal workflow shell variables.
grep -Fq '${CANDIDATE_VERSION}-candidate' "$workflow" || fail 'manifest candidate tag missing'
grep -Fq 'sort == ["amd64", "arm64"]' "$workflow" || fail 'dual-architecture manifest verification missing'
grep -Fq 'secrets.DOCKERHUB_TOKEN' "$workflow" || fail 'Docker Hub token secret missing'

if grep -Eq '(^|[^[:alnum:]_-])latest([^[:alnum:]_-]|$)' "$workflow"; then
  fail 'latest tag is forbidden for a candidate'
fi

echo 'PASS: Docker Hub publication is manual, native, dual-architecture and candidate-only'
