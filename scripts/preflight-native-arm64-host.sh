#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only readiness check for a direct native ARM64 candidate build. Host
# provisioning and image pulls remain explicit administrator operations.

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly REPO_ROOT
readonly INPUTS="$REPO_ROOT/policy/release-inputs.json"
readonly BUILDER_NAME=${DSH_NATIVE_BUILDER_NAME:-dsh-native-arm64}
readonly MIN_FREE_KIB=${DSH_NATIVE_MIN_FREE_KIB:-6291456}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: preflight-native-arm64-host.sh

Read-only checks for a direct native ARM64 candidate build. The command does
not install packages, pull images, create builders, publish, or deploy.

Environment:
  DSH_NATIVE_BUILDER_NAME  builder checked when it already exists
  DSH_NATIVE_MIN_FREE_KIB  required free space (default: 6291456 / 6 GiB)
EOF
}

if (($#)); then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
fi

case "$BUILDER_NAME" in
  ''|*[!A-Za-z0-9_.-]*) fail 'DSH_NATIVE_BUILDER_NAME contains unsafe characters' ;;
esac
[[ "$MIN_FREE_KIB" =~ ^[1-9][0-9]*$ ]] ||
  fail 'DSH_NATIVE_MIN_FREE_KIB must be a positive integer'

for command_name in docker git jq python3 sha256sum tar timeout syft grype df; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

[[ -f "$INPUTS" && ! -L "$INPUTS" ]] || fail 'release input ledger is missing'
python3 "$REPO_ROOT/scripts/check-release-inputs.py"
test "$(uname -m)" = aarch64 || fail 'native ARM64 build requires uname -m=aarch64'
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail 'direct build requires a Git worktree'
test -z "$(git -C "$REPO_ROOT" status --porcelain)" ||
  fail 'worktree must be clean so evidence binds to one committed revision'

docker info >/dev/null || fail 'Docker daemon is unavailable'
docker buildx version >/dev/null || fail 'Docker Buildx is unavailable'

readonly SYFT_VERSION=$(jq -er '.tools.syft.version' "$INPUTS")
readonly GRYPE_VERSION=$(jq -er '.tools.grype.version' "$INPUTS")
readonly BUILDKIT_REF=$(jq -er '.images.buildkit.ref' "$INPUTS")

test "$(syft version -o json | jq -er '.version')" = "$SYFT_VERSION" ||
  fail "Syft must match ledger version $SYFT_VERSION"
test "$(grype version -o json | jq -er '.version')" = "$GRYPE_VERSION" ||
  fail "Grype must match ledger version $GRYPE_VERSION"

docker image inspect "$BUILDKIT_REF" >/dev/null 2>&1 ||
  fail "pinned BuildKit image is not local; load or pull $BUILDKIT_REF"

available_kib=$(df --output=avail -k "$REPO_ROOT" | tail -n 1 | tr -d '[:space:]')
[[ "$available_kib" =~ ^[0-9]+$ ]] || fail 'could not determine available disk space'
((available_kib >= MIN_FREE_KIB)) ||
  fail "at least $MIN_FREE_KIB KiB free space is required; found $available_kib KiB"

if builder_output=$(docker buildx inspect "$BUILDER_NAME" 2>/dev/null); then
  grep -Eq '^Driver:[[:space:]]+docker-container$' <<<"$builder_output" ||
    fail "pre-existing builder $BUILDER_NAME does not use docker-container"
  grep -Fq "$BUILDKIT_REF" <<<"$builder_output" ||
    fail "pre-existing builder $BUILDER_NAME does not use the ledger BuildKit digest"
  builder_state='existing-compatible'
else
  builder_state='absent-build-script-will-create'
fi

printf 'PASS: native ARM64 host preflight\n'
printf 'source_commit=%s\n' "$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
printf 'buildkit_ref=%s\n' "$BUILDKIT_REF"
printf 'syft_version=%s\n' "$SYFT_VERSION"
printf 'grype_version=%s\n' "$GRYPE_VERSION"
printf 'available_kib=%s\n' "$available_kib"
printf 'builder=%s:%s\n' "$BUILDER_NAME" "$builder_state"
