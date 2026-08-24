#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly SOURCE_IMAGE=${SOURCE_IMAGE:-haproxy:3.4.3-alpine3.24@sha256:c7f5037a567378929d0aba734eb78b73497209c72456519420ce5e68a42d60ac}
readonly SOURCE_DIGEST=${SOURCE_IMAGE##*@}
readonly SOURCE_PLATFORM=${SOURCE_PLATFORM:-linux/amd64}
readonly CLEAN_LOAD_REQUIRED=${CLEAN_LOAD_REQUIRED:-0}
readonly KEEP_ARCHIVE_TAG=${KEEP_ARCHIVE_TAG:-0}
source_name=${SOURCE_IMAGE%@*}
source_leaf=${source_name##*/}
[[ "$source_leaf" == *:* ]] || {
  echo 'FAIL: SOURCE_IMAGE must include a version tag before its digest' >&2
  exit 1
}
readonly SOURCE_REPOSITORY=${source_name%:*}
readonly TEST_ARCHIVE_TAG=${ARCHIVE_TAG:-$SOURCE_REPOSITORY:dsh-offline-contract-${SOURCE_PLATFORM##*/}-${SOURCE_DIGEST#sha256:}}
readonly CONFLICT_TAG="$SOURCE_REPOSITORY:dsh-offline-conflict-${$}-${RANDOM}"
readonly PRIOR_TAG="local/dsh-offline-prior-${$}-${RANDOM}:test"
readonly CLEAN_REPOSITORY="local/dsh-offline-clean-${$}-${RANDOM}"
readonly CLEAN_SOURCE_TAG="$CLEAN_REPOSITORY:source"
readonly CLEAN_SOURCE_REF="$CLEAN_SOURCE_TAG@$SOURCE_DIGEST"
readonly CLEAN_ARCHIVE_TAG="$CLEAN_REPOSITORY:archive"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v docker >/dev/null || fail 'docker is required'
case "$CLEAN_LOAD_REQUIRED" in 0|1) ;; *) fail 'CLEAN_LOAD_REQUIRED must be 0 or 1' ;; esac
case "$KEEP_ARCHIVE_TAG" in 0|1) ;; *) fail 'KEEP_ARCHIVE_TAG must be 0 or 1' ;; esac
docker image inspect "$SOURCE_IMAGE" >/dev/null 2>&1 || fail "source image is not loaded: $SOURCE_IMAGE"
test "$(docker image inspect "$SOURCE_IMAGE" --format '{{.Os}}/{{.Architecture}}')" = \
  "$SOURCE_PLATFORM" || fail 'source image platform does not match SOURCE_PLATFORM'
SOURCE_IMAGE_ID=$(docker image inspect "$SOURCE_IMAGE" --format '{{.Id}}')
readonly SOURCE_IMAGE_ID
archive_tag_preexisting=0
if docker image inspect "$TEST_ARCHIVE_TAG" >/dev/null 2>&1; then
  test "$(docker image inspect "$TEST_ARCHIVE_TAG" --format '{{.Id}}')" = "$SOURCE_IMAGE_ID" ||
    fail 'pre-existing archive tag points to a different image'
  archive_tag_preexisting=1
fi
for fresh_tag in "$CONFLICT_TAG" "$PRIOR_TAG" "$CLEAN_SOURCE_TAG" "$CLEAN_ARCHIVE_TAG"; do
  docker image inspect "$fresh_tag" >/dev/null 2>&1 &&
    fail "refusing to reuse pre-existing test tag: $fresh_tag"
done

tmp_dir=$(mktemp -d /tmp/dsh-offline-archive.XXXXXX)
prior_id=''
archive=''
cleanup() {
  local status=$?
  trap - EXIT
  for cleanup_tag in "$CLEAN_SOURCE_TAG" "$CLEAN_ARCHIVE_TAG"; do
    if docker image inspect "$cleanup_tag" >/dev/null 2>&1; then
      docker image rm "$cleanup_tag" >/dev/null || status=2
    fi
  done
  if [[ "$KEEP_ARCHIVE_TAG" == 0 && "$archive_tag_preexisting" == 0 ]] &&
      docker image inspect "$TEST_ARCHIVE_TAG" >/dev/null 2>&1; then
    if [[ "$(docker image inspect "$TEST_ARCHIVE_TAG" --format '{{.Id}}')" == "$SOURCE_IMAGE_ID" ]]; then
      docker image rm "$TEST_ARCHIVE_TAG" >/dev/null || status=2
    else
      echo "FAIL: refusing to remove changed archive tag $TEST_ARCHIVE_TAG" >&2
      status=2
    fi
  fi
  if docker image inspect "$CONFLICT_TAG" >/dev/null 2>&1; then
    test "$(docker image inspect "$CONFLICT_TAG" --format '{{.Id}}')" = "$prior_id" || status=2
    docker image rm "$CONFLICT_TAG" >/dev/null || status=2
  fi
  if docker image inspect "$PRIOR_TAG" >/dev/null 2>&1; then
    test "$(docker image inspect "$PRIOR_TAG" --format '{{.Id}}')" = "$prior_id" || status=2
    docker image rm "$PRIOR_TAG" >/dev/null || status=2
  fi
  case "$tmp_dir" in /tmp/dsh-offline-archive.*) ;; *) exit 2 ;; esac
  if [[ -d "$tmp_dir" && ! -L "$tmp_dir" ]]; then
    find "$tmp_dir" -xdev -depth -mindepth 1 -delete || status=2
    rmdir -- "$tmp_dir" || status=2
  fi
  exit "$status"
}
trap cleanup EXIT

if "$ROOT/scripts/save-pinned-image.sh" \
    "registry.example:5000/repo@$SOURCE_DIGEST" "$SOURCE_PLATFORM" \
    'registry.example:5000/repo:dsh-offline-test' "$tmp_dir/no-version.tar" \
    >/dev/null 2>&1; then
  fail 'archive helper confused a registry port with a required source version tag'
fi

# A dedicated tag that already points elsewhere must fail closed, never be
# overwritten. The empty imported image exists only for this negative test.
tar --create --file "$tmp_dir/empty-rootfs.tar" --files-from /dev/null
docker import "$tmp_dir/empty-rootfs.tar" "$PRIOR_TAG" >/dev/null
prior_id=$(docker image inspect "$PRIOR_TAG" --format '{{.Id}}')
test "$prior_id" != "$SOURCE_IMAGE_ID"
docker image tag "$PRIOR_TAG" "$CONFLICT_TAG"
if "$ROOT/scripts/save-pinned-image.sh" "$SOURCE_IMAGE" "$SOURCE_PLATFORM" \
    "$CONFLICT_TAG" "$tmp_dir/rejected.tar" >/dev/null 2>&1; then
  fail 'archive helper overwrote a dedicated tag that pointed elsewhere'
fi
test "$(docker image inspect "$CONFLICT_TAG" --format '{{.Id}}')" = "$prior_id"
docker image rm "$CONFLICT_TAG" >/dev/null
docker image rm "$PRIOR_TAG" >/dev/null

# Force docker-save failure. The new dedicated tag remains as an intentional,
# retryable build output; a second invocation must safely reuse the same ID.
real_docker=$(command -v docker)
mkdir -m 700 "$tmp_dir/fail-bin"
# shellcheck disable=SC2016 # generated wrapper expands these at its runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'if [[ ${1:-} == image && ${2:-} == save ]]; then exit 97; fi' \
  'exec "${REAL_DOCKER:?}" "$@"' \
  > "$tmp_dir/fail-bin/docker"
chmod 700 "$tmp_dir/fail-bin/docker"
if PATH="$tmp_dir/fail-bin:$PATH" REAL_DOCKER="$real_docker" \
    "$ROOT/scripts/save-pinned-image.sh" "$SOURCE_IMAGE" "$SOURCE_PLATFORM" \
    "$TEST_ARCHIVE_TAG" "$tmp_dir/forced-failure.tar" >/dev/null 2>&1; then
  fail 'archive helper unexpectedly succeeded when docker save failed'
fi
test ! -e "$tmp_dir/forced-failure.tar"
test "$(docker image inspect "$TEST_ARCHIVE_TAG" --format '{{.Id}}')" = "$SOURCE_IMAGE_ID"

archive="$tmp_dir/image.tar"
if "$ROOT/scripts/save-pinned-image.sh" "$SOURCE_IMAGE" "$SOURCE_PLATFORM" \
    local/wrong-repository:3.4.3 "$archive" >/dev/null 2>&1; then
  fail 'archive helper accepted a different repository'
fi
"$ROOT/scripts/save-pinned-image.sh" "$SOURCE_IMAGE" "$SOURCE_PLATFORM" \
  "$TEST_ARCHIVE_TAG" "$archive"
if "$ROOT/scripts/save-pinned-image.sh" "$SOURCE_IMAGE" "$SOURCE_PLATFORM" \
    "$TEST_ARCHIVE_TAG" "$archive" >/dev/null 2>&1; then
  fail 'archive helper overwrote an existing output'
fi

tar -xOf "$archive" manifest.json | jq -e --arg tag "$TEST_ARCHIVE_TAG" \
  'length == 1 and .[0].RepoTags == [$tag]' >/dev/null
config_path=$(tar -xOf "$archive" manifest.json | jq -er '.[0].Config')
case "$config_path" in
  blobs/sha256/*) config_digest="sha256:${config_path##*/}" ;;
  [0-9a-f][0-9a-f]*.json) config_digest="sha256:${config_path%.json}" ;;
  *) fail 'archive config path is not content-addressed' ;;
esac
[[ "$config_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'archive config digest is malformed'
test "$(tar -xOf "$archive" "$config_path" | sha256sum | cut -d' ' -f1)" = \
  "${config_digest#sha256:}" || fail 'archive config blob checksum is invalid'
if [[ "$SOURCE_IMAGE_ID" == "$SOURCE_DIGEST" ]]; then
  tar -xOf "$archive" index.json | jq -e \
    --arg digest "$SOURCE_DIGEST" --arg refName "${TEST_ARCHIVE_TAG##*:}" '
    ([.manifests[] | select(.digest == $digest)] | length == 1) and
    ([.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $refName)]
      | length == 1 and .[0].digest == $digest) and
    (all(.manifests[];
      .digest == $digest or
      .annotations["io.containerd.manifest.subject"] == $digest))
  ' >/dev/null
else
  test "$config_digest" = "$SOURCE_IMAGE_ID" ||
    fail 'classic-store archive config does not match source image ID'
fi

# Simulate a fresh repository namespace without deleting the caller's source
# association. The archive deliberately carries a different tag in the same
# temporary repository; after both preparation tags are removed, only loading
# the archive may make the digest-qualified source reference resolvable.
if [[ "$CLEAN_LOAD_REQUIRED" == 1 ]]; then
  clean_archive="$tmp_dir/clean-image.tar"
  docker image tag "$SOURCE_IMAGE" "$CLEAN_SOURCE_TAG"
  docker image inspect "$CLEAN_SOURCE_REF" >/dev/null 2>&1 ||
    fail 'temporary digest-qualified source reference is not resolvable'
  "$ROOT/scripts/save-pinned-image.sh" "$CLEAN_SOURCE_REF" "$SOURCE_PLATFORM" \
    "$CLEAN_ARCHIVE_TAG" "$clean_archive"
  docker image rm "$CLEAN_SOURCE_TAG" >/dev/null
  docker image rm "$CLEAN_ARCHIVE_TAG" >/dev/null 2>&1 || true
  if docker image inspect "$CLEAN_SOURCE_REF" >/dev/null 2>&1; then
    fail 'temporary repository unexpectedly remained before clean load'
  fi
  docker load --input "$clean_archive" >/dev/null
  test "$(docker image inspect "$CLEAN_SOURCE_REF" --format '{{.Id}} {{.Os}}/{{.Architecture}}')" = \
    "$SOURCE_IMAGE_ID $SOURCE_PLATFORM"
fi

grep -Fq "scripts/save-pinned-image.sh\" \"\$CADDY_REF\" linux/amd64" \
  "$ROOT/scripts/build-amd64-candidate.sh" || fail 'local AMD64 Caddy archive can lose RepoTags'
grep -Fq "scripts/save-pinned-image.sh\" \"\$CADDY_REF\" linux/arm64" \
  "$ROOT/scripts/build-candidate.sh" || fail 'local ARM64 Caddy archive can lose RepoTags'

printf 'PASS: dedicated tagged archive preserves exact child (clean-load=%s)\n' \
  "$CLEAN_LOAD_REQUIRED"
