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
grep -Fq 'fail-fast: false' "$workflow" || fail 'matrix must retain both architecture evidence sets'
# shellcheck disable=SC2016 # Inspect the literal GitHub expressions.
grep -Fq 'LOCAL_TAG: local/dsh:${{ github.sha }}-${{ matrix.architecture }}' "$workflow" || fail 'source-commit local tag missing'
grep -Fq 'image-tag.txt' "$workflow" || fail 'publication must load the packaged local tag'
# shellcheck disable=SC2016 # Inspect the literal GitHub expression.
grep -Fq 'TARGETPLATFORM=${{ matrix.platform }}' "$workflow" || fail 'explicit target platform missing'
grep -Fq 'tests/amd64-runtime.sh' "$workflow" || fail 'amd64 runtime smoke missing'
grep -Fq 'tests/arm64-runtime.sh' "$workflow" || fail 'arm64 runtime smoke missing'
grep -Fq 'gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e' "$workflow" || fail 'pinned history secret scan missing'
grep -Fq 'anchore/sbom-action/download-syft@e22c389904149dbc22b58101806040fa8d37a610' "$workflow" || fail 'pinned Syft setup missing'
grep -Fq 'anchore/scan-action/download-grype@e1165082ffb1fe366ebaf02d8526e7c4989ea9d2' "$workflow" || fail 'pinned Grype setup missing'
grep -Fq 'dsh-sbom.syft.json' "$workflow" || fail 'DSH SBOM missing'
grep -Fq 'caddy-sbom.syft.json' "$workflow" || fail 'Caddy SBOM missing'
grep -Fq 'scripts/check-supply-chain-policy.py' "$workflow" || fail 'supply-chain policy gate missing'
grep -Fq 'policy/vulnerability-allowlist.json' "$workflow" || fail 'vulnerability exception policy missing'
grep -Fq 'Refuse replacement of immutable candidate tags' "$workflow" || fail 'immutable tag guard missing'

for tool in SYFT GRYPE GITLEAKS; do
  policy_key=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')
  version=$(jq -er --arg key "$policy_key" '.[$key].version' \
    "$ROOT/policy/supply-chain-tools.json")
  grep -Fq "${tool}_VERSION: ${version}" "$workflow" || \
    fail "$tool version differs from supply-chain tool policy"
done
# shellcheck disable=SC2016 # Inspect literal workflow shell variables.
grep -Fq '${CANDIDATE_VERSION}-${architecture}-candidate' "$workflow" || fail 'architecture candidate tag missing'
# shellcheck disable=SC2016 # Inspect literal workflow shell variables.
grep -Fq '${CANDIDATE_VERSION}-candidate' "$workflow" || fail 'manifest candidate tag missing'
grep -Fq '(.manifests | length) == 2' "$workflow" || fail 'exact dual-architecture manifest verification missing'
# shellcheck disable=SC2016 # Inspect literal workflow shell variables.
grep -Fq '"${amd64_tag}@${amd64_digest}"' "$workflow" || fail 'amd64 digest-pinned manifest input missing'
# shellcheck disable=SC2016 # Inspect literal workflow shell variables.
grep -Fq '"${arm64_tag}@${arm64_digest}"' "$workflow" || fail 'arm64 digest-pinned manifest input missing'
grep -Fq 'secrets.DOCKERHUB_TOKEN' "$workflow" || fail 'Docker Hub token secret missing'

policy_line=$(grep -n -m1 'scripts/check-supply-chain-policy.py' "$workflow" | cut -d: -f1)
login_line=$(grep -n -m1 'docker/login-action@' "$workflow" | cut -d: -f1)
if [[ -z "$policy_line" || -z "$login_line" || "$login_line" -le "$policy_line" ]]; then
  fail 'Docker Hub login occurs before supply-chain policy approval'
fi

if grep -Eq 'ignore-unfixed|only-fixed' "$workflow"; then
  fail 'unfixed HIGH/CRITICAL vulnerabilities must not be silently ignored'
fi

jq -e '
  .schemaVersion == 1
  and (.blockedSeverities | sort) == ["Critical", "High"]
  and .exceptions == []
' \
  "$ROOT/policy/vulnerability-allowlist.json" >/dev/null || \
  fail 'High/Critical policy and initial empty exception set must be explicit'

if grep -Eq '(^|[^[:alnum:]_-])latest([^[:alnum:]_-]|$)' "$workflow"; then
  fail 'latest tag is forbidden for a candidate'
fi

echo 'PASS: Docker Hub publication is gated, immutable, native, dual-architecture and candidate-only'
