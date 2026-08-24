#!/usr/bin/env bash
set -Eeuo pipefail

# Resolve one already-loaded, versioned image tag to its exact repository
# digest, run the live runtime/ELF audit, and retain the JSON report. Candidate
# build workflows use `collect`; publication uses fail-closed `gate`.

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly ROOT
readonly IMAGE_TAG=${1:?usage: audit-loaded-runtime-cve.sh IMAGE_TAG PLATFORM OUTPUT collect|gate}
readonly PLATFORM=${2:?usage: audit-loaded-runtime-cve.sh IMAGE_TAG PLATFORM OUTPUT collect|gate}
readonly OUTPUT=${3:?usage: audit-loaded-runtime-cve.sh IMAGE_TAG PLATFORM OUTPUT collect|gate}
readonly MODE=${4:?usage: audit-loaded-runtime-cve.sh IMAGE_TAG PLATFORM OUTPUT collect|gate}

fail() {
  echo "FAIL: $*" >&2
  exit 2
}

command -v docker >/dev/null || fail 'docker is required'
command -v jq >/dev/null || fail 'jq is required'
case "$PLATFORM" in linux/amd64|linux/arm64) ;; *) fail 'invalid platform' ;; esac
case "$MODE" in collect|gate) ;; *) fail 'mode must be collect or gate' ;; esac
case "$IMAGE_TAG" in *'@'*) fail 'IMAGE_TAG must be a versioned tag, not a digest reference' ;; esac
image_leaf=${IMAGE_TAG##*/}
[[ "$image_leaf" == *:* ]] || fail 'IMAGE_TAG must contain a version tag'
image_repo=${IMAGE_TAG%:*}
[[ -d "$(dirname -- "$OUTPUT")" ]] || fail 'output directory does not exist'
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail 'output path already exists'
docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || fail 'loaded image tag is unavailable'
test "$(docker image inspect "$IMAGE_TAG" --format '{{.Os}}/{{.Architecture}}')" = "$PLATFORM" ||
  fail 'loaded image platform does not match'

repo_digest=''
while IFS= read -r candidate; do
  [[ "$candidate" == "$image_repo"@sha256:* ]] || continue
  [[ -z "$repo_digest" ]] || fail 'loaded image has multiple matching repository digests'
  repo_digest=$candidate
done < <(docker image inspect "$IMAGE_TAG" --format '{{range .RepoDigests}}{{println .}}{{end}}')
[[ "$repo_digest" =~ ^.+@sha256:[0-9a-f]{64}$ ]] ||
  fail 'loaded image has no exact same-repository digest'
exact_ref="$IMAGE_TAG@${repo_digest##*@}"

temporary_output=$(mktemp "${OUTPUT}.tmp.XXXXXX")
cleanup() {
  local status=$?
  if [[ -f "$temporary_output" && ! -L "$temporary_output" ]]; then
    rm -- "$temporary_output" || status=2
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

set +e
"$ROOT/scripts/audit-runtime-cve-reachability.sh" "$exact_ref" "$PLATFORM" > "$temporary_output"
audit_status=$?
set -e
case "$audit_status" in 0|1) ;; *) fail "live runtime audit failed with status $audit_status" ;; esac
jq -e --arg ref "$exact_ref" --arg platform "$PLATFORM" '
  .schemaVersion == 1
  and .image.ref == $ref
  and .image.platform == $platform
  and .image.repoDigestMatch == "yes"
  and (.findings | length == 4)
' "$temporary_output" >/dev/null || fail 'live runtime audit report identity is invalid'
mv -- "$temporary_output" "$OUTPUT"
trap - EXIT

if [[ "$MODE" == gate && "$audit_status" != 0 ]]; then
  echo "FAIL: live runtime CVE reachability gate remains blocked; see $OUTPUT" >&2
  exit 1
fi
printf 'PASS: live runtime CVE audit retained (%s, decision=%s)\n' \
  "$MODE" "$(jq -r .decision "$OUTPUT")"
