#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly SOURCE_IMAGE=${SOURCE_IMAGE:-haproxy:3.4.3-alpine3.24@sha256:c7f5037a567378929d0aba734eb78b73497209c72456519420ce5e68a42d60ac}
readonly SOURCE_DIGEST=${SOURCE_IMAGE##*@}
readonly SOURCE_PLATFORM=${SOURCE_PLATFORM:-linux/amd64}
readonly TEST_REPOSITORY="local/dsh-offline-archive-${$}-${RANDOM}"
readonly TEST_SOURCE_TAG="$TEST_REPOSITORY:3.4.3"
readonly TEST_ARCHIVE_TAG="$TEST_REPOSITORY:dsh-offline-${SOURCE_PLATFORM##*/}-${SOURCE_DIGEST#sha256:}"
readonly PRIOR_TAG="local/dsh-offline-prior-${$}-${RANDOM}:test"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v docker >/dev/null || fail 'docker is required'
docker image inspect "$SOURCE_IMAGE" >/dev/null 2>&1 || fail "source image is not loaded: $SOURCE_IMAGE"
test "$(docker image inspect "$SOURCE_IMAGE" --format '{{.Os}}/{{.Architecture}}')" = \
  "$SOURCE_PLATFORM" || fail 'source image platform does not match SOURCE_PLATFORM'

tmp_dir=$(mktemp -d /tmp/dsh-offline-archive.XXXXXX)
prior_id=''
cleanup() {
  for tag in "$TEST_ARCHIVE_TAG" "$TEST_SOURCE_TAG"; do
    if docker image inspect "$tag" >/dev/null 2>&1; then
      test "$(docker image inspect "$tag" --format '{{.Id}}')" = "$SOURCE_DIGEST" || exit 2
      docker image rm "$tag" >/dev/null
    fi
  done
  if docker image inspect "$PRIOR_TAG" >/dev/null 2>&1; then
    test "$(docker image inspect "$PRIOR_TAG" --format '{{.Id}}')" = "$prior_id" || exit 2
    docker image rm "$PRIOR_TAG" >/dev/null
  fi
  case "$tmp_dir" in /tmp/dsh-offline-archive.*) ;; *) return 2 ;; esac
  if [[ -d "$tmp_dir" && ! -L "$tmp_dir" ]]; then
    find "$tmp_dir" -xdev -depth -mindepth 1 -delete
    rmdir -- "$tmp_dir"
  fi
}
trap cleanup EXIT

if "$ROOT/scripts/save-pinned-image.sh" \
    "registry.example:5000/repo@$SOURCE_DIGEST" "$SOURCE_PLATFORM" \
    'registry.example:5000/repo:dsh-offline-test' "$tmp_dir/no-version.tar" \
    >/dev/null 2>&1; then
  fail 'archive helper confused a registry port with a required source version tag'
fi

# Create a disposable repository name for a clean-name load simulation.
docker image tag "$SOURCE_IMAGE" "$TEST_SOURCE_TAG"
readonly TEST_SOURCE_REF="$TEST_SOURCE_TAG@$SOURCE_DIGEST"

# A dedicated tag that already points elsewhere must fail closed, never be
# overwritten. The empty imported image exists only for this negative test.
tar --create --file "$tmp_dir/empty-rootfs.tar" --files-from /dev/null
docker import "$tmp_dir/empty-rootfs.tar" "$PRIOR_TAG" >/dev/null
prior_id=$(docker image inspect "$PRIOR_TAG" --format '{{.Id}}')
test "$prior_id" != "$SOURCE_DIGEST"
docker image tag "$PRIOR_TAG" "$TEST_ARCHIVE_TAG"
if "$ROOT/scripts/save-pinned-image.sh" "$TEST_SOURCE_REF" "$SOURCE_PLATFORM" \
    "$TEST_ARCHIVE_TAG" "$tmp_dir/rejected.tar" >/dev/null 2>&1; then
  fail 'archive helper overwrote a dedicated tag that pointed elsewhere'
fi
test "$(docker image inspect "$TEST_ARCHIVE_TAG" --format '{{.Id}}')" = "$prior_id"
docker image rm "$TEST_ARCHIVE_TAG" >/dev/null
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
    "$ROOT/scripts/save-pinned-image.sh" "$TEST_SOURCE_REF" "$SOURCE_PLATFORM" \
    "$TEST_ARCHIVE_TAG" "$tmp_dir/forced-failure.tar" >/dev/null 2>&1; then
  fail 'archive helper unexpectedly succeeded when docker save failed'
fi
test ! -e "$tmp_dir/forced-failure.tar"
test "$(docker image inspect "$TEST_ARCHIVE_TAG" --format '{{.Id}}')" = "$SOURCE_DIGEST"

archive="$tmp_dir/image.tar"
if "$ROOT/scripts/save-pinned-image.sh" "$TEST_SOURCE_REF" "$SOURCE_PLATFORM" \
    local/wrong-repository:3.4.3 "$archive" >/dev/null 2>&1; then
  fail 'archive helper accepted a different repository'
fi
"$ROOT/scripts/save-pinned-image.sh" "$TEST_SOURCE_REF" "$SOURCE_PLATFORM" \
  "$TEST_ARCHIVE_TAG" "$archive"
if "$ROOT/scripts/save-pinned-image.sh" "$TEST_SOURCE_REF" "$SOURCE_PLATFORM" \
    "$TEST_ARCHIVE_TAG" "$archive" >/dev/null 2>&1; then
  fail 'archive helper overwrote an existing output'
fi

tar -xOf "$archive" manifest.json | jq -e --arg tag "$TEST_ARCHIVE_TAG" \
  'length == 1 and .[0].RepoTags == [$tag]' >/dev/null
tar -xOf "$archive" index.json | jq -e \
  --arg digest "$SOURCE_DIGEST" --arg refName "${TEST_ARCHIVE_TAG##*:}" '
    ([.manifests[] | select(.digest == $digest)] | length == 1) and
    ([.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $refName)]
      | length == 1 and .[0].digest == $digest) and
    (all(.manifests[];
      .digest == $digest or
      .annotations["io.containerd.manifest.subject"] == $digest))
  ' >/dev/null

# Remove both names to simulate a clean repository namespace, then load only
# the archive. A different-tag digest-qualified reference must resolve again.
docker image rm "$TEST_SOURCE_TAG" >/dev/null
docker image rm "$TEST_ARCHIVE_TAG" >/dev/null
if docker image inspect "$TEST_SOURCE_REF" >/dev/null 2>&1; then
  fail 'digest-qualified test repository unexpectedly remained before clean load'
fi
docker load --input "$archive" >/dev/null
test "$(docker image inspect "$TEST_SOURCE_REF" --format '{{.Id}} {{.Os}}/{{.Architecture}}')" = \
  "$SOURCE_DIGEST $SOURCE_PLATFORM"

grep -Fq "scripts/save-pinned-image.sh\" \"\$CADDY_REF\" linux/amd64" \
  "$ROOT/scripts/build-amd64-candidate.sh" || fail 'local AMD64 Caddy archive can lose RepoTags'
grep -Fq "scripts/save-pinned-image.sh\" \"\$CADDY_REF\" linux/arm64" \
  "$ROOT/scripts/build-candidate.sh" || fail 'local ARM64 Caddy archive can lose RepoTags'

printf 'PASS: dedicated tagged archive preserves exact child and resolves after clean load\n'
