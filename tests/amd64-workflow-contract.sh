#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$ROOT/.github/workflows/build-amd64.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test -f "$workflow" || fail "AMD64 workflow is missing"
grep -Fq 'pull_request:' "$workflow" || fail "pull request trigger missing"
grep -Fq 'workflow_dispatch:' "$workflow" || fail "manual trigger missing"
grep -A2 '^permissions:' "$workflow" | grep -Fq 'contents: read' || fail "workflow permissions are not read-only"
grep -Fq 'actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803' "$workflow" || fail "checkout Action is not pinned to the reviewed v6 commit"
grep -Fq 'runs-on: ubuntu-24.04' "$workflow" || fail "native AMD64 runner label missing"
# shellcheck disable=SC2016 # Inspect literal workflow shell syntax.
grep -Fq 'test "$(uname -m)" = x86_64' "$workflow" || fail "native x86_64 runner check missing"
grep -Fq 'platforms: linux/amd64' "$workflow" || fail "linux/amd64 build target missing"
grep -Fq 'NODE_BASE_REF=node:24.19.0-bookworm-slim@sha256:65932751ed4073ed02f5c04e494e4b2572a891b7dbea0568a863dc80341bf848' "$workflow" || fail "AMD64 Node build child is not pinned"
grep -Fq 'NODE_RUNTIME_REF=gcr.io/distroless/nodejs24-debian13@sha256:579735ae8373ff1ab6c4aa251480fd17ae6ec1b7f83b1bfc76bf6003d0fb242b' "$workflow" || fail "AMD64 Node runtime child is not pinned"
grep -Fq 'CADDY_REF: caddy:2.11.4@sha256:98eb57d882ccd5213d1688764db10c1ca2c58a1ca3a6717a3411ad798f7a423a' "$workflow" || fail "AMD64 Caddy child is not pinned"
grep -Fq 'CADDY_ARCHIVE_TAG: caddy:dsh-offline-2.11.4-amd64-98eb57d882cc' "$workflow" || fail "AMD64 dedicated Caddy archive tag is missing"
grep -Fq "scripts/save-pinned-image.sh \"\$CADDY_REF\" linux/amd64" "$workflow" || fail "AMD64 Caddy archive can lose its resolvable RepoTag"
grep -Fq 'HAPROXY_REF: haproxy:3.4.3-alpine3.24@sha256:c7f5037a567378929d0aba734eb78b73497209c72456519420ce5e68a42d60ac' "$workflow" || fail "AMD64 HAProxy child is not pinned"
grep -Fq 'driver-opts: image=moby/buildkit:v0.29.0@sha256:0039c1d47e8748b5afea56f4e85f14febaf34452bd99d9552d2daa82262b5cc5' "$workflow" || fail "BuildKit image is not pinned"
grep -Fq 'tests/amd64-runtime.sh' "$workflow" || fail "AMD64 runtime smoke missing"
grep -Fq 'tests/amd64-compose-contract.sh' "$workflow" || fail "AMD64 Compose contract missing"
grep -Fq 'tests/amd64-workflow-contract.sh' "$workflow" || fail "AMD64 workflow contract is not run"
grep -Fq 'tests/haproxy-contract.sh' "$workflow" || fail "HAProxy config contract is not run"
grep -Fq 'tests/haproxy-runtime.sh' "$workflow" || fail "HAProxy direct runtime contract is not run"
grep -Fq 'tests/haproxy-compose-runtime.sh' "$workflow" || fail "HAProxy Compose runtime contract is not run"
grep -Fq 'tests/offline-image-archive.sh' "$workflow" || fail "offline image archive clean-load contract is not run"
grep -Fq 'SOURCE_PLATFORM=linux/amd64 CLEAN_LOAD_REQUIRED=1' "$workflow" || fail "AMD64 workflow does not require a destructive clean-load proof"
grep -Fq 'DOCKER_BUILD_RECORD_UPLOAD: "false"' "$workflow" || fail "automatic PR build-record upload is not disabled"
grep -Fq 'available_kib' "$workflow" || fail "disk availability preflight missing"
grep -Fq 'docker-system-df-before.txt' "$workflow" || fail "Docker disk evidence missing"
grep -Fq 'docker-version.txt' "$workflow" || fail "Docker version evidence missing"
grep -Fq 'buildx-version.txt' "$workflow" || fail "Buildx version evidence missing"
grep -Fq 'builder-inspect.txt' "$workflow" || fail "builder evidence missing"
grep -Fq 'native-candidate-lock.json' "$workflow" || fail "native candidate lock is not generated"
grep -Fq 'native-github-candidate-built-not-released' "$workflow" || fail "candidate-only status missing"
grep -Fq 'github-actions/ubuntu-24.04-amd64-native-buildx' "$workflow" || fail "native AMD64 build environment missing"
grep -Fq "sourceCommit: \$sourceCommit" "$workflow" || fail "source commit is not recorded"
grep -Fq "githubRunId: \$githubRunId" "$workflow" || fail "GitHub run ID is not recorded"
grep -Fq "manifestDigest: \$manifestDigest" "$workflow" || fail "verified manifest digest is not recorded"
grep -Fq "configDigest: \$configDigest" "$workflow" || fail "verified config digest is not recorded"
grep -Fq "dshArchiveSha256: \$dshArchiveSha256" "$workflow" || fail "DSH archive hash is not recorded"
grep -Fq "caddyArchiveSha256: \$caddyArchiveSha256" "$workflow" || fail "Caddy archive hash is not recorded"
grep -Fq 'sbomSha256: null' "$workflow" || fail "missing SBOM state is not explicit"
grep -Fq 'provenanceSha256: null' "$workflow" || fail "missing provenance state is not explicit"
grep -Fq 'del(.images.binfmt, .images.arm64Probe)' "$workflow" || fail "QEMU-only lock keys are not removed"
grep -Fq 'CANDIDATE-NOT-RELEASE.txt' "$workflow" || fail "candidate release boundary marker missing"
grep -Fq 'cp compose.yaml compose.amd64.yaml Caddyfile .env.example' "$workflow" || fail "AMD64 Compose override is not bundled"
grep -Fq 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' "$workflow" || fail "manual artifact upload is not pinned"
# shellcheck disable=SC2016 # Inspect literal GitHub expression syntax.
grep -Fq 'name: dsh-container-amd64-${{ github.sha }}' "$workflow" || fail "manual artifact name is not source-specific"
grep -A2 'name: Assemble manual-download bundle' "$workflow" | grep -Fq "if: github.event_name == 'workflow_dispatch'" || fail "bundle assembly is not manual-only"
grep -A2 'name: Upload manual candidate' "$workflow" | grep -Fq "if: github.event_name == 'workflow_dispatch'" || fail "artifact upload is not manual-only"

if grep -Eq '(^|[[:space:]])docker[[:space:]]+(login|push)([[:space:]]|$)' "$workflow"; then
  fail "registry login or image push is present"
fi
if grep -Eq 'pull_request_target|docker/login-action|docker/buildx[[:space:]]+imagetools|type=registry|push:[[:space:]]*true|DOCKERHUB|packages:[[:space:]]*write|id-token:[[:space:]]*write|secrets\.|^[[:space:]]*environment:' "$workflow"; then
  fail "registry publication mechanism is present"
fi
if grep -Eq '(^|[^[:alnum:]_-])latest([^[:alnum:]_-]|$)' "$workflow"; then
  fail "floating latest tag is forbidden"
fi

echo "PASS: AMD64 workflow is native, pinned, candidate-only and manually bundleable"
