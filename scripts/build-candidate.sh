#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly BUILDER_NAME='dsh-arm64-qemu'
readonly BUILDKIT_REF='moby/buildkit:v0.29.0@sha256:0039c1d47e8748b5afea56f4e85f14febaf34452bd99d9552d2daa82262b5cc5'
readonly IMAGE_TAG='local/dsh:0.1.1-rc.1-arm64'
readonly NODE_BASE_REF='node:24.19.0-bookworm-slim@sha256:c133efe216ffb6e785ed9a8be55a29fcb86775e8008ae0a9f0ed6af4f175bb03'
readonly NODE_RUNTIME_REF='gcr.io/distroless/nodejs24-debian13@sha256:8f5b4fe36a991614a46469e4ec06f65838a2bc22d61f560aac9d40ae62e9ac5a'
readonly CADDY_REF='caddy:2.11.4@sha256:1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba'
readonly ARTIFACT_ROOT="$REPO_ROOT/artifacts"

test -f /proc/sys/fs/binfmt_misc/qemu-aarch64
grep -qx 'enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64
grep -Eq '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64
builder_output=$(docker buildx inspect "$BUILDER_NAME")
grep -Eq '^Driver:[[:space:]]+docker-container$' <<<"$builder_output"
grep -Fq "image=\"$BUILDKIT_REF\"" <<<"$builder_output"
grep -Eq 'Status:[[:space:]]+running' <<<"$builder_output"
grep -Eq 'Platforms:.*linux/arm64' <<<"$builder_output"

install -d -m 0755 "$ARTIFACT_ROOT"
ARTIFACT_DIR=$(mktemp -d "$ARTIFACT_ROOT/candidate-arm64.XXXXXX")
readonly ARTIFACT_DIR

docker buildx build \
  --builder "$BUILDER_NAME" \
  --platform linux/arm64 \
  --target runtime \
  --build-arg TARGETPLATFORM=linux/arm64 \
  --build-arg "NODE_BASE_REF=$NODE_BASE_REF" \
  --build-arg "NODE_RUNTIME_REF=$NODE_RUNTIME_REF" \
  --tag "$IMAGE_TAG" \
  --metadata-file "$ARTIFACT_DIR/dsh-build-metadata.json" \
  --output "type=docker,dest=$ARTIFACT_DIR/dsh-0.1.1-rc.1-arm64.tar" \
  "$REPO_ROOT"

docker load --input "$ARTIFACT_DIR/dsh-0.1.1-rc.1-arm64.tar"
test "$(docker image inspect "$IMAGE_TAG" --format '{{.Os}}/{{.Architecture}}')" = \
  'linux/arm64'
test "$(docker run --rm --network none "$IMAGE_TAG" --version)" = '0.1.1-rc.1'
"$REPO_ROOT/tests/arm64-runtime.sh" "$IMAGE_TAG"
docker image inspect "$IMAGE_TAG" > "$ARTIFACT_DIR/dsh-image-inspect.json"

docker pull --platform linux/arm64 "$CADDY_REF"
test "$(docker image inspect "$CADDY_REF" --format '{{.Architecture}}')" = arm64
docker image save --output "$ARTIFACT_DIR/caddy-2.11.4-arm64.tar" "$CADDY_REF"
docker image inspect "$CADDY_REF" > "$ARTIFACT_DIR/caddy-image-inspect.json"

dsh_image_id=$(docker image inspect "$IMAGE_TAG" --format '{{.Id}}')
caddy_image_id=$(docker image inspect "$CADDY_REF" --format '{{.Id}}')
dsh_archive_sha256=$(sha256sum "$ARTIFACT_DIR/dsh-0.1.1-rc.1-arm64.tar" | cut -d' ' -f1)
caddy_archive_sha256=$(sha256sum "$ARTIFACT_DIR/caddy-2.11.4-arm64.tar" | cut -d' ' -f1)
manifest_digest=$(jq -r '."containerimage.digest" // empty' "$ARTIFACT_DIR/dsh-build-metadata.json")
config_path=$(tar -xOf "$ARTIFACT_DIR/dsh-0.1.1-rc.1-arm64.tar" manifest.json | jq -er '.[0].Config')
case "$config_path" in blobs/sha256/*) ;; *) echo "unexpected OCI config path: $config_path" >&2; exit 1;; esac
config_digest="sha256:${config_path##*/}"
test "$(tar -xOf "$ARTIFACT_DIR/dsh-0.1.1-rc.1-arm64.tar" "$config_path" | sha256sum | cut -d' ' -f1)" = \
  "${config_digest#sha256:}"
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq \
  --arg builtAt "$built_at" \
  --arg imageId "$dsh_image_id" \
  --arg manifestDigest "$manifest_digest" \
  --arg configDigest "$config_digest" \
  --arg dshArchiveSha256 "$dsh_archive_sha256" \
  --arg caddyImageId "$caddy_image_id" \
  --arg caddyArchiveSha256 "$caddy_archive_sha256" \
  '.status = "qemu-candidate-built-not-released"
   | .output = {
       buildEnvironment: "linux/amd64-buildx-qemu-aarch64",
       builtAt: $builtAt,
       imageId: $imageId,
       manifestDigest: (if $manifestDigest == "" then null else $manifestDigest end),
       configDigest: (if $configDigest == "" then $imageId else $configDigest end),
       dshArchiveSha256: $dshArchiveSha256,
       caddyImageId: $caddyImageId,
       caddyArchiveSha256: $caddyArchiveSha256,
       sbomSha256: null,
       provenanceSha256: null
     }' \
  "$REPO_ROOT/policy/image-lock.json" > "$ARTIFACT_DIR/arm64-candidate-lock.json"

cp "$REPO_ROOT/compose.yaml" "$REPO_ROOT/Caddyfile" \
  "$REPO_ROOT/.env.example" "$ARTIFACT_DIR/"
printf '%s\n' \
  'CANDIDATE ONLY: no SBOM, provenance, signature or production ARM acceptance is included.' \
  > "$ARTIFACT_DIR/CANDIDATE-NOT-RELEASE.txt"

(
  cd "$ARTIFACT_DIR"
  sha256sum \
    dsh-0.1.1-rc.1-arm64.tar \
    caddy-2.11.4-arm64.tar \
    compose.yaml Caddyfile .env.example arm64-candidate-lock.json \
    CANDIDATE-NOT-RELEASE.txt \
    dsh-build-metadata.json \
    dsh-image-inspect.json \
    caddy-image-inspect.json > SHA256SUMS
)

printf 'Candidate bundle written to %s\n' "$ARTIFACT_DIR"
