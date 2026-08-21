#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$ROOT/.github/workflows/build-arm64.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'runs-on: ubuntu-24.04-arm' "$workflow" || fail "native ARM runner label missing"
grep -Fq 'driver-opts: image=moby/buildkit:v0.29.0@sha256:0039c1d47e8748b5afea56f4e85f14febaf34452bd99d9552d2daa82262b5cc5' "$workflow" || fail "native BuildKit image is not pinned"
# shellcheck disable=SC2016 # Inspect literal workflow shell syntax.
grep -Fq 'test "$(uname -m)" = aarch64' "$workflow" || fail "native runner architecture is not enforced"
grep -Fq 'native-candidate-lock.json' "$workflow" || fail "native candidate lock is not generated"
grep -Fq 'del(.images.binfmt, .images.arm64Probe)' "$workflow" || fail "QEMU-only tool identities remain in the native lock"
grep -Fq 'buildx-version.txt' "$workflow" || fail "native Buildx version evidence missing"
grep -Fq 'builder-inspect.txt' "$workflow" || fail "native builder evidence missing"
grep -Fq 'native-github-candidate-built-not-released' "$workflow" || fail "native candidate status missing"
grep -Fq 'github-actions/ubuntu-24.04-arm-native-buildx' "$workflow" || fail "native build environment missing"
grep -Fq "config_path=\$(tar -xOf" "$workflow" || fail "native OCI config digest is not extracted from the archive"
# shellcheck disable=SC2016 # Inspect the literal jq variable in the workflow.
grep -Fq 'configDigest: $configDigest' "$workflow" || fail "native lock does not record the verified config digest"
# shellcheck disable=SC2016 # Inspect literal jq variable references.
grep -Fq 'dshArchiveSha256: $dshArchiveSha256' "$workflow" || fail "native DSH archive hash missing"
# shellcheck disable=SC2016 # Inspect literal jq variable references.
grep -Fq 'caddyArchiveSha256: $caddyArchiveSha256' "$workflow" || fail "native Caddy archive hash missing"

if grep -Eq 'cp .*policy/image-lock\.json.*bundle' "$workflow"; then
  fail "QEMU output lock is copied into the native candidate bundle"
fi

echo "PASS: native workflow produces environment-specific candidate metadata"
