#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly BUILDER_NAME='dsh-arm64-qemu'
readonly BUILDKIT_REF='moby/buildkit:v0.29.0@sha256:0039c1d47e8748b5afea56f4e85f14febaf34452bd99d9552d2daa82262b5cc5'
readonly IMAGE_TAG='local/dsh:0.1.1-rc.2-amd64'
readonly NODE_BASE_REF='node:24.19.0-bookworm-slim@sha256:65932751ed4073ed02f5c04e494e4b2572a891b7dbea0568a863dc80341bf848'
readonly NODE_RUNTIME_REF='gcr.io/distroless/nodejs24-debian13@sha256:579735ae8373ff1ab6c4aa251480fd17ae6ec1b7f83b1bfc76bf6003d0fb242b'
readonly CADDY_REF='caddy:2.11.4@sha256:98eb57d882ccd5213d1688764db10c1ca2c58a1ca3a6717a3411ad798f7a423a'
readonly CADDY_ARCHIVE_TAG='caddy:dsh-offline-2.11.4-amd64-98eb57d882cc'
readonly ARTIFACT_ROOT="$REPO_ROOT/artifacts"

test "$(uname -m)" = x86_64
builder_output=$(docker buildx inspect "$BUILDER_NAME")
grep -Eq '^Driver:[[:space:]]+docker-container$' <<<"$builder_output"
grep -Fq "image=\"$BUILDKIT_REF\"" <<<"$builder_output"
grep -Eq 'Status:[[:space:]]+running' <<<"$builder_output"
grep -Eq 'Platforms:.*linux/amd64' <<<"$builder_output"

install -d -m 0755 "$ARTIFACT_ROOT"
ARTIFACT_DIR=$(mktemp -d "$ARTIFACT_ROOT/candidate-amd64.XXXXXX")
readonly ARTIFACT_DIR

docker buildx build \
  --builder "$BUILDER_NAME" \
  --platform linux/amd64 \
  --target runtime \
  --build-arg TARGETPLATFORM=linux/amd64 \
  --build-arg "NODE_BASE_REF=$NODE_BASE_REF" \
  --build-arg "NODE_RUNTIME_REF=$NODE_RUNTIME_REF" \
  --tag "$IMAGE_TAG" \
  --metadata-file "$ARTIFACT_DIR/dsh-build-metadata.json" \
  --load \
  "$REPO_ROOT"

test "$(docker image inspect "$IMAGE_TAG" --format '{{.Os}}/{{.Architecture}}')" = \
  'linux/amd64'
"$REPO_ROOT/tests/amd64-runtime.sh" "$IMAGE_TAG"
docker image save --output "$ARTIFACT_DIR/dsh-0.1.1-rc.2-amd64.tar" "$IMAGE_TAG"
docker image inspect "$IMAGE_TAG" > "$ARTIFACT_DIR/dsh-image-inspect.json"

docker pull --platform linux/amd64 "$CADDY_REF"
test "$(docker image inspect "$CADDY_REF" --format '{{.Os}}/{{.Architecture}}')" = \
  'linux/amd64'
"$REPO_ROOT/scripts/save-pinned-image.sh" "$CADDY_REF" linux/amd64 \
  "$CADDY_ARCHIVE_TAG" "$ARTIFACT_DIR/caddy-2.11.4-amd64.tar"
docker image inspect "$CADDY_REF" > "$ARTIFACT_DIR/caddy-image-inspect.json"

dsh_image_id=$(docker image inspect "$IMAGE_TAG" --format '{{.Id}}')
caddy_image_id=$(docker image inspect "$CADDY_REF" --format '{{.Id}}')
dsh_archive_sha256=$(sha256sum "$ARTIFACT_DIR/dsh-0.1.1-rc.2-amd64.tar" | cut -d' ' -f1)
caddy_archive_sha256=$(sha256sum "$ARTIFACT_DIR/caddy-2.11.4-amd64.tar" | cut -d' ' -f1)
manifest_digest=$(jq -r '."containerimage.digest" // empty' "$ARTIFACT_DIR/dsh-build-metadata.json")
config_path=$(tar -xOf "$ARTIFACT_DIR/dsh-0.1.1-rc.2-amd64.tar" manifest.json | jq -er '.[0].Config')
case "$config_path" in blobs/sha256/*) ;; *) echo "unexpected OCI config path: $config_path" >&2; exit 1;; esac
config_digest="sha256:${config_path##*/}"
test "$(tar -xOf "$ARTIFACT_DIR/dsh-0.1.1-rc.2-amd64.tar" "$config_path" | sha256sum | cut -d' ' -f1)" = \
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
  'del(
      .images.nodeBaseArm64,
      .images.nodeRuntimeArm64,
      .images.caddyArm64,
      .images.binfmt,
      .images.arm64Probe
    )
   | .status = "local-amd64-candidate-built-not-released"
   | .target = "linux/amd64"
   | .images.nodeBaseAmd64 = "docker.io/library/node:24.19.0-bookworm-slim@sha256:65932751ed4073ed02f5c04e494e4b2572a891b7dbea0568a863dc80341bf848"
   | .images.nodeRuntimeAmd64 = "gcr.io/distroless/nodejs24-debian13@sha256:579735ae8373ff1ab6c4aa251480fd17ae6ec1b7f83b1bfc76bf6003d0fb242b"
   | .images.caddyAmd64 = "docker.io/library/caddy:2.11.4@sha256:98eb57d882ccd5213d1688764db10c1ca2c58a1ca3a6717a3411ad798f7a423a"
   | .output = {
       buildEnvironment: "local-linux-amd64-native-buildx",
       builtAt: $builtAt,
       imageId: $imageId,
       manifestDigest: (if $manifestDigest == "" then null else $manifestDigest end),
       configDigest: $configDigest,
       dshArchiveSha256: $dshArchiveSha256,
       caddyImageId: $caddyImageId,
       caddyArchiveSha256: $caddyArchiveSha256,
       sbomSha256: null,
       provenanceSha256: null
     }' \
  "$REPO_ROOT/policy/image-lock.json" > "$ARTIFACT_DIR/amd64-candidate-lock.json"

cp "$REPO_ROOT/compose.yaml" "$REPO_ROOT/compose.amd64.yaml" \
  "$REPO_ROOT/Caddyfile" "$ARTIFACT_DIR/"
cp "$REPO_ROOT/.env.amd64.example" "$ARTIFACT_DIR/.env.example"
printf '%s\n' \
  'LOCAL AMD64 CANDIDATE ONLY: this is not ARM production evidence and includes no SBOM, provenance or signature.' \
  > "$ARTIFACT_DIR/CANDIDATE-NOT-RELEASE.txt"

(
  cd "$ARTIFACT_DIR"
  sha256sum \
    dsh-0.1.1-rc.2-amd64.tar \
    caddy-2.11.4-amd64.tar \
    compose.yaml compose.amd64.yaml Caddyfile .env.example \
    amd64-candidate-lock.json CANDIDATE-NOT-RELEASE.txt \
    dsh-build-metadata.json dsh-image-inspect.json \
    caddy-image-inspect.json > SHA256SUMS
)

printf 'Local amd64 candidate bundle written to %s\n' "$ARTIFACT_DIR"
