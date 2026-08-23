#!/usr/bin/env bash
set -Eeuo pipefail

# Preserve a registry child selected by digest in a Docker archive that a
# clean, disconnected daemon can resolve again as name:tag@digest. `docker
# save` of a digest-only reference writes RepoTags:null, so it is forbidden.

readonly source_ref=${1:?usage: save-pinned-image.sh SOURCE_REF PLATFORM ARCHIVE_TAG OUTPUT}
readonly expected_platform=${2:?usage: save-pinned-image.sh SOURCE_REF PLATFORM ARCHIVE_TAG OUTPUT}
readonly archive_tag=${3:?usage: save-pinned-image.sh SOURCE_REF PLATFORM ARCHIVE_TAG OUTPUT}
readonly output=${4:?usage: save-pinned-image.sh SOURCE_REF PLATFORM ARCHIVE_TAG OUTPUT}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v docker >/dev/null || fail 'docker is required'
command -v jq >/dev/null || fail 'jq is required'
command -v sha256sum >/dev/null || fail 'sha256sum is required'
command -v tar >/dev/null || fail 'tar is required'

[[ "$source_ref" =~ @sha256:[0-9a-f]{64}$ ]] ||
  fail 'SOURCE_REF must select one exact sha256 child digest'
case "$source_ref" in
  -*|*$'\n'*|*$'\r'*) fail 'source image reference contains prohibited characters' ;;
esac
case "$archive_tag" in
  -*|*$'\n'*|*$'\r'*) fail 'image references contain prohibited characters' ;;
esac
case "$expected_platform" in
  linux/amd64|linux/arm64) ;;
  *) fail 'PLATFORM must be linux/amd64 or linux/arm64' ;;
esac
source_name=${source_ref%@*}
source_leaf=${source_name##*/}
archive_leaf=${archive_tag##*/}
[[ "$source_leaf" == *:* ]] || fail 'SOURCE_REF must include a version tag before its digest'
[[ "$archive_leaf" == *:* ]] || fail 'ARCHIVE_TAG must include a dedicated tag'
source_repo=${source_name%:*}
archive_repo=${archive_tag%:*}
test "$archive_repo" = "$source_repo" ||
  fail 'ARCHIVE_TAG must preserve the source repository for digest resolution after load'
test "$archive_tag" != "$source_name" ||
  fail 'ARCHIVE_TAG must be a dedicated tag, not the ordinary upstream version tag'
case "$output" in
  ''|/|.|..|*/|*/..|*/.) fail 'unsafe archive output path' ;;
esac
if [[ -e "$output" || -L "$output" ]]; then
  fail "archive output already exists: $output"
fi
test -d "$(dirname -- "$output")" || fail 'archive output directory does not exist'

source_id=$(docker image inspect "$source_ref" --format '{{.Id}}')
source_platform=$(docker image inspect "$source_ref" --format '{{.Os}}/{{.Architecture}}')
test "$source_platform" = "$expected_platform" ||
  fail "source platform is $source_platform, expected $expected_platform"

temporary_output=''
cleanup() {
  local status=$?
  if [[ -n "$temporary_output" && -f "$temporary_output" && ! -L "$temporary_output" ]]; then
    rm -- "$temporary_output"
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

temporary_output=$(mktemp "${output}.tmp.XXXXXX")
if docker image inspect "$archive_tag" >/dev/null 2>&1; then
  test "$(docker image inspect "$archive_tag" --format '{{.Id}}')" = "$source_id" ||
    fail 'dedicated archive tag already exists with a different image ID'
else
  # This project-owned tag is an intentional build output. Keep it after save:
  # removing the last same-repository tag can also drop digest-name resolution.
  docker image tag "$source_ref" "$archive_tag"
fi
test "$(docker image inspect "$archive_tag" --format '{{.Id}}')" = "$source_id" ||
  fail 'archive tag does not resolve to the selected child'

docker image save --output "$temporary_output" "$archive_tag"
jq -e --arg tag "$archive_tag" \
  'length == 1 and .[0].RepoTags == [$tag]' \
  < <(tar -xOf "$temporary_output" manifest.json) >/dev/null ||
  fail 'legacy archive manifest does not contain exactly one expected RepoTag entry'
config_path=$(tar -xOf "$temporary_output" manifest.json | jq -er '.[0].Config')
case "$config_path" in
  blobs/sha256/*)
    config_digest="sha256:${config_path##*/}"
    ;;
  [0-9a-f][0-9a-f]*.json)
    config_digest="sha256:${config_path%.json}"
    [[ "$config_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      fail 'legacy archive config path is not a sha256 digest'
    ;;
  *) fail 'archive config path is not content-addressed' ;;
esac
test "$(tar -xOf "$temporary_output" "$config_path" | sha256sum | cut -d' ' -f1)" = \
  "${config_digest#sha256:}" || fail 'archive config blob checksum is invalid'
archive_ref_name=${archive_tag##*:}
if jq -e --arg digest "${source_ref##*@}" --arg refName "$archive_ref_name" '
  ([.manifests[] | select(.digest == $digest)] | length == 1) and
  ([.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $refName)]
    | length == 1 and .[0].digest == $digest) and
  (all(.manifests[];
    .digest == $digest or
    .annotations["io.containerd.manifest.subject"] == $digest))
' < <(tar -xOf "$temporary_output" index.json) >/dev/null 2>&1; then
  archive_store=containerd
else
  # The classic Docker image store exports the legacy image config/layers and
  # a RepoTag, but not the pulled registry manifest identity. Its local image
  # ID is the config digest. The exact source child was still selected above;
  # the archive checksum and this config digest become the offline identity.
  test "$source_id" != "${source_ref##*@}" ||
    fail 'archive lost the selected child manifest from a content store'
  test "$config_digest" = "$source_id" ||
    fail 'classic-store archive config does not match the selected source image ID'
  archive_store=classic
fi
ln -- "$temporary_output" "$output"
rm -- "$temporary_output"
trap - EXIT

printf 'PASS: saved %s (%s, image %s, config %s, store %s) as archive tag %s to %s\n' \
  "$source_ref" "$expected_platform" "$source_id" "$config_digest" \
  "$archive_store" "$archive_tag" "$output"
