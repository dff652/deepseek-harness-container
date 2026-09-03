#!/usr/bin/env bash
set -Eeuo pipefail

# Build and exercise a candidate on an external aarch64 host. This entrypoint
# only sees a checked-out worktree and a local Docker daemon. It does not
# install emulation support, publish images, sign artifacts, or deploy Compose.

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly REPO_ROOT
readonly INPUTS="$REPO_ROOT/policy/release-inputs.json"
readonly ARTIFACT_ROOT=${DSH_NATIVE_ARTIFACT_ROOT:-$REPO_ROOT/artifacts}
readonly BUILDER_NAME=${DSH_NATIVE_BUILDER_NAME:-dsh-native-arm64}
readonly KEEP_BUILDER=${DSH_NATIVE_KEEP_BUILDER:-0}
readonly POLICY_MODE=${DSH_NATIVE_POLICY_MODE:-gate}
readonly STEP_TIMEOUT_SECONDS=${DSH_NATIVE_STEP_TIMEOUT_SECONDS:-7200}
readonly NETWORK_TIMEOUT_SECONDS=${DSH_NATIVE_NETWORK_TIMEOUT_SECONDS:-300}
readonly VERIFIED_SOURCE_COMMIT=${DSH_NATIVE_VERIFIED_SOURCE_COMMIT:-}
readonly VERIFIED_SOURCE_ARCHIVE_SHA256=${DSH_NATIVE_VERIFIED_SOURCE_ARCHIVE_SHA256:-}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_step() {
  timeout --signal=TERM --kill-after=30s "${STEP_TIMEOUT_SECONDS}s" "$@"
}

usage() {
  cat >&2 <<'EOF'
usage: build-native-arm64-candidate.sh

Environment:
  DSH_NATIVE_ARTIFACT_ROOT  output parent (default: ./artifacts)
  DSH_NATIVE_BUILDER_NAME   dedicated Buildx builder name
  DSH_NATIVE_KEEP_BUILDER   set to 1 to retain a builder created by this run
  DSH_NATIVE_POLICY_MODE    gate (default) or collect blocked non-release evidence
  DSH_NATIVE_STEP_TIMEOUT_SECONDS     build/gate timeout (default: 7200)
  DSH_NATIVE_NETWORK_TIMEOUT_SECONDS  bootstrap/pull timeout (default: 300)

The command must run on a native aarch64 host. It leaves an environment-
specific candidate directory under the artifact root and never publishes or
deploys the image.
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
case "$KEEP_BUILDER" in 0|1) ;; *) fail 'DSH_NATIVE_KEEP_BUILDER must be 0 or 1' ;; esac
case "$POLICY_MODE" in gate|collect) ;; *) fail 'DSH_NATIVE_POLICY_MODE must be gate or collect' ;; esac
[[ "$STEP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{1,4}$ ]] ||
  fail 'DSH_NATIVE_STEP_TIMEOUT_SECONDS must be an integer from 10 to 99999'
((STEP_TIMEOUT_SECONDS >= 10)) || fail 'DSH_NATIVE_STEP_TIMEOUT_SECONDS must be at least 10'
[[ "$NETWORK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{1,3}$ ]] ||
  fail 'DSH_NATIVE_NETWORK_TIMEOUT_SECONDS must be an integer from 10 to 9999'
((NETWORK_TIMEOUT_SECONDS >= 10)) || fail 'DSH_NATIVE_NETWORK_TIMEOUT_SECONDS must be at least 10'

for command_name in docker git jq python3 sha256sum tar timeout syft grype; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
[[ -f "$INPUTS" && ! -L "$INPUTS" ]] || fail 'release input ledger is missing'
python3 "$REPO_ROOT/scripts/check-release-inputs.py"
test "$(uname -m)" = aarch64 || fail 'native ARM64 candidate requires uname -m=aarch64'
docker info >/dev/null || fail 'Docker daemon is unavailable'
docker buildx version >/dev/null || fail 'Docker Buildx is unavailable'

source_archive_sha256=''
source_mode=''
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  [[ -z "$VERIFIED_SOURCE_COMMIT" && -z "$VERIFIED_SOURCE_ARCHIVE_SHA256" ]] ||
    fail 'verified archive identity variables are only accepted outside a Git worktree'
  test -z "$(git -C "$REPO_ROOT" status --porcelain)" ||
    fail 'worktree must be clean so evidence binds to one committed source revision'
  SOURCE_COMMIT=$(git -C "$REPO_ROOT" rev-parse --verify HEAD)
  source_mode='clean-git-worktree'
else
  [[ "$VERIFIED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    fail 'an extracted archive requires DSH_NATIVE_VERIFIED_SOURCE_COMMIT'
  [[ "$VERIFIED_SOURCE_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'an extracted archive requires DSH_NATIVE_VERIFIED_SOURCE_ARCHIVE_SHA256'
  SOURCE_COMMIT=$VERIFIED_SOURCE_COMMIT
  source_archive_sha256=$VERIFIED_SOURCE_ARCHIVE_SHA256
  source_mode='forced-runner-verified-git-archive'
fi
readonly SOURCE_COMMIT source_mode source_archive_sha256

json_value() {
  jq -er "$1" "$INPUTS"
}

readonly DSH_VERSION=$(json_value '.release.dsh.version')
readonly NODE_BASE_REF=$(json_value '.images.nodeBuild.platforms["linux/arm64"].ref')
readonly NODE_RUNTIME_REF=$(json_value '.images.nodeRuntime.platforms["linux/arm64"].ref')
readonly CADDY_REF=$(json_value '.images.caddy.platforms["linux/arm64"].ref')
readonly CADDY_VERSION=$(json_value '.images.caddy.tag')
readonly CADDY_DIGEST=$(json_value '.images.caddy.platforms["linux/arm64"].digest')
readonly CADDY_ARCHIVE_TAG=$(json_value '.archiveTags.caddy["linux/arm64"]')
readonly HAPROXY_REF=$(json_value '.images.haproxy.platforms["linux/arm64"].ref')
readonly HAPROXY_ARCHIVE_TAG=$(json_value '.archiveTags.haproxy["linux/arm64"]')
readonly BUILDKIT_REF=$(json_value '.images.buildkit.ref')
readonly NODE_BASE_DIGEST=$(json_value '.images.nodeBuild.platforms["linux/arm64"].digest')
readonly NODE_RUNTIME_DIGEST=$(json_value '.images.nodeRuntime.platforms["linux/arm64"].digest')
readonly SYFT_VERSION=$(json_value '.tools.syft.version')
readonly GRYPE_VERSION=$(json_value '.tools.grype.version')
readonly IMAGE_TAG="local/dsh:${DSH_VERSION}-arm64-native-candidate"
readonly DSH_ARCHIVE_NAME="dsh-${DSH_VERSION}-arm64.tar"
readonly CADDY_ARCHIVE_NAME="caddy-$(json_value '.images.caddy.tag')-arm64.tar"
readonly HAPROXY_ARCHIVE_NAME="haproxy-$(json_value '.images.haproxy.tag')-arm64.tar"

mkdir -p -- "$ARTIFACT_ROOT"
[[ ! -L "$ARTIFACT_ROOT" && -d "$ARTIFACT_ROOT" ]] || fail 'artifact root must be a directory'
ARTIFACT_DIR=$(mktemp -d "$ARTIFACT_ROOT/native-arm64.XXXXXX")
readonly ARTIFACT_DIR
[[ ! -L "$ARTIFACT_DIR" && -d "$ARTIFACT_DIR" ]] || fail 'artifact directory is unsafe'

builder_created=0
cleanup() {
  local status=$?
  if [[ "$builder_created" == 1 && "$KEEP_BUILDER" == 0 ]]; then
    local inspect=''
    inspect=$(timeout --signal=TERM --kill-after=30s "${NETWORK_TIMEOUT_SECONDS}s" \
      docker buildx inspect "$BUILDER_NAME" 2>/dev/null || true)
    if grep -Eq '^Driver:[[:space:]]+docker-container$' <<<"$inspect" &&
      grep -Fq "$BUILDKIT_REF" <<<"$inspect"; then
      timeout --signal=TERM --kill-after=30s "${NETWORK_TIMEOUT_SECONDS}s" \
        docker buildx rm --force "$BUILDER_NAME" >/dev/null 2>&1 || status=2
    else
      echo "FAIL: refusing to remove a changed or unowned builder $BUILDER_NAME" >&2
      status=2
    fi
  fi
  if ((status != 0)); then
    printf 'FAILED: partial native ARM64 evidence retained at %s\n' "$ARTIFACT_DIR" >&2
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

date -u +%Y-%m-%dT%H:%M:%SZ > "$ARTIFACT_DIR/started-at.txt"
uname -a > "$ARTIFACT_DIR/host-uname.txt"
getconf GNU_LIBC_VERSION > "$ARTIFACT_DIR/host-glibc.txt" 2>&1 || true
docker version > "$ARTIFACT_DIR/docker-version.txt"
docker buildx version > "$ARTIFACT_DIR/buildx-version.txt"
docker info > "$ARTIFACT_DIR/docker-info.txt"
df -h > "$ARTIFACT_DIR/disk-before.txt"
docker system df > "$ARTIFACT_DIR/docker-system-df-before.txt"
test "$(syft version -o json | jq -er '.version')" = "$SYFT_VERSION" ||
  fail "Syft must match ledger version $SYFT_VERSION"
test "$(grype version -o json | jq -er '.version')" = "$GRYPE_VERSION" ||
  fail "Grype must match ledger version $GRYPE_VERSION"
syft version > "$ARTIFACT_DIR/syft-version.txt"
grype version > "$ARTIFACT_DIR/grype-version.txt"

# Static/security contracts are intentionally run before the expensive build.
bash "$REPO_ROOT/tests/compose-contract.sh"
bash "$REPO_ROOT/tests/negative-exposure.sh"
bash "$REPO_ROOT/tests/native-workflow-contract.sh"
timeout --signal=TERM --kill-after=30s "${NETWORK_TIMEOUT_SECONDS}s" \
  bash "$REPO_ROOT/tests/caddy-volume-init.sh"
python3 -m unittest "$REPO_ROOT/tests/supply-chain-policy.py"

if docker buildx inspect "$BUILDER_NAME" > "$ARTIFACT_DIR/builder-before-bootstrap.txt" 2>&1; then
  grep -Eq '^Driver:[[:space:]]+docker-container$' "$ARTIFACT_DIR/builder-before-bootstrap.txt" ||
    fail 'pre-existing builder does not use the docker-container driver'
  grep -Fq "$BUILDKIT_REF" "$ARTIFACT_DIR/builder-before-bootstrap.txt" ||
    fail 'pre-existing builder does not use the ledger BuildKit digest'
else
  timeout --signal=TERM --kill-after=30s "${NETWORK_TIMEOUT_SECONDS}s" docker buildx create \
    --name "$BUILDER_NAME" \
    --driver docker-container \
    --driver-opt "image=$BUILDKIT_REF"
  builder_created=1
fi
builder_output=$(timeout --signal=TERM --kill-after=30s "${NETWORK_TIMEOUT_SECONDS}s" \
  docker buildx inspect "$BUILDER_NAME" --bootstrap) ||
  fail "builder bootstrap exceeded ${NETWORK_TIMEOUT_SECONDS}s or failed"
printf '%s\n' "$builder_output" > "$ARTIFACT_DIR/builder-inspect.txt"
grep -Eq '^Driver:[[:space:]]+docker-container$' <<<"$builder_output" ||
  fail 'dedicated builder does not use the docker-container driver'
grep -Fq "$BUILDKIT_REF" <<<"$builder_output" ||
  fail 'dedicated builder does not use the ledger BuildKit digest'
grep -Eq 'Status:[[:space:]]+running' <<<"$builder_output" ||
  fail 'dedicated builder is not running'
grep -Eq 'Platforms:.*linux/arm64' <<<"$builder_output" ||
  fail 'dedicated builder does not advertise linux/arm64'

run_step env BUILDX_METADATA_PROVENANCE=max docker buildx build \
  --builder "$BUILDER_NAME" \
  --platform linux/arm64 \
  --target runtime \
  --build-arg TARGETPLATFORM=linux/arm64 \
  --build-arg "NODE_BASE_REF=$NODE_BASE_REF" \
  --build-arg "NODE_RUNTIME_REF=$NODE_RUNTIME_REF" \
  --label "org.opencontainers.image.revision=$SOURCE_COMMIT" \
  --tag "$IMAGE_TAG" \
  --metadata-file "$ARTIFACT_DIR/dsh-build-metadata.json" \
  --output "type=docker,dest=$ARTIFACT_DIR/$DSH_ARCHIVE_NAME" \
  "$REPO_ROOT"

run_step docker load --input "$ARTIFACT_DIR/$DSH_ARCHIVE_NAME" >/dev/null
test "$(docker image inspect "$IMAGE_TAG" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64
docker image inspect "$IMAGE_TAG" > "$ARTIFACT_DIR/dsh-image-inspect.json"
run_step docker run --rm --network none "$IMAGE_TAG" --version | grep -Fx "$DSH_VERSION"
run_step bash "$REPO_ROOT/tests/arm64-runtime.sh" "$IMAGE_TAG"
run_step env DSH_IMAGE="$IMAGE_TAG" bash "$REPO_ROOT/tests/rc2-regression.sh"
run_step bash "$REPO_ROOT/tests/runtime-cve-reachability.sh"

set +e
run_step bash "$REPO_ROOT/scripts/audit-loaded-runtime-cve.sh" "$IMAGE_TAG" linux/arm64 \
  "$ARTIFACT_DIR/runtime-cve-reachability.json" collect
audit_status=$?
set -e
case "$audit_status" in
  0) ;;
  *) fail "runtime CVE evidence collection failed with status $audit_status" ;;
esac

# Pull only exact child references from the ledger. Dedicated archive tags
# preserve a stable Compose name after an offline docker load.
timeout --signal=TERM --kill-after=30s "${NETWORK_TIMEOUT_SECONDS}s" \
  docker pull --platform linux/arm64 "$CADDY_REF" >/dev/null
test "$(docker image inspect "$CADDY_REF" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64
run_step bash "$REPO_ROOT/scripts/save-pinned-image.sh" "$CADDY_REF" linux/arm64 \
  "$CADDY_ARCHIVE_TAG" "$ARTIFACT_DIR/$CADDY_ARCHIVE_NAME"
docker image inspect "$CADDY_REF" > "$ARTIFACT_DIR/caddy-image-inspect.json"
run_step env SOURCE_IMAGE="$CADDY_REF" SOURCE_PLATFORM=linux/arm64 \
  ARCHIVE_TAG="$CADDY_ARCHIVE_TAG" CLEAN_LOAD_REQUIRED=1 KEEP_ARCHIVE_TAG=1 \
  bash "$REPO_ROOT/tests/offline-image-archive.sh"

timeout --signal=TERM --kill-after=30s "${NETWORK_TIMEOUT_SECONDS}s" \
  docker pull --platform linux/arm64 "$HAPROXY_REF" >/dev/null
test "$(docker image inspect "$HAPROXY_REF" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64
run_step bash "$REPO_ROOT/scripts/save-pinned-image.sh" "$HAPROXY_REF" linux/arm64 \
  "$HAPROXY_ARCHIVE_TAG" "$ARTIFACT_DIR/$HAPROXY_ARCHIVE_NAME"
docker image inspect "$HAPROXY_REF" > "$ARTIFACT_DIR/haproxy-image-inspect.json"
run_step env SOURCE_IMAGE="$HAPROXY_REF" SOURCE_PLATFORM=linux/arm64 \
  ARCHIVE_TAG="$HAPROXY_ARCHIVE_TAG" CLEAN_LOAD_REQUIRED=1 KEEP_ARCHIVE_TAG=1 \
  bash "$REPO_ROOT/tests/offline-image-archive.sh"

for image_spec in \
  "dsh=$IMAGE_TAG" \
  "caddy=$CADDY_REF" \
  "haproxy=$HAPROXY_REF"; do
  image_name=${image_spec%%=*}
  image_ref=${image_spec#*=}
  run_step env SYFT_CHECK_FOR_APP_UPDATE=false syft scan "$image_ref" \
    -o "syft-json=$ARTIFACT_DIR/$image_name-sbom.syft.json" \
    -o "cyclonedx-json=$ARTIFACT_DIR/$image_name-sbom.cdx.json"
  run_step env GRYPE_CHECK_FOR_APP_UPDATE=false grype \
    "sbom:$ARTIFACT_DIR/$image_name-sbom.syft.json" \
    -o json --file "$ARTIFACT_DIR/$image_name-vulnerabilities.json"
done

set +e
run_step python3 "$REPO_ROOT/scripts/check-supply-chain-policy.py" \
  --dsh-sbom "$ARTIFACT_DIR/dsh-sbom.syft.json" \
  --caddy-sbom "$ARTIFACT_DIR/caddy-sbom.syft.json" \
  --dsh-vulnerabilities "$ARTIFACT_DIR/dsh-vulnerabilities.json" \
  --caddy-vulnerabilities "$ARTIFACT_DIR/caddy-vulnerabilities.json" \
  --build-metadata "$ARTIFACT_DIR/dsh-build-metadata.json" \
  --dsh-inspect "$ARTIFACT_DIR/dsh-image-inspect.json" \
  --caddy-inspect "$ARTIFACT_DIR/caddy-image-inspect.json" \
  --license-policy "$REPO_ROOT/policy/license-policy.json" \
  --vulnerability-policy "$REPO_ROOT/policy/vulnerability-allowlist.json" \
  --tools-policy "$REPO_ROOT/policy/supply-chain-tools.json" \
  --architecture arm64 \
  --platform linux/arm64 \
  --dsh-version "$DSH_VERSION" \
  --caddy-version "$CADDY_VERSION" \
  --node-base-digest "$NODE_BASE_DIGEST" \
  --node-runtime-digest "$NODE_RUNTIME_DIGEST" \
  --caddy-digest "$CADDY_DIGEST" \
  --source-revision "$SOURCE_COMMIT" \
  --output "$ARTIFACT_DIR/supply-chain-policy-summary.json"
supply_chain_status=$?
set -e
jq '{
  schemaVersion: 1,
  image: "haproxy",
  blockedSeverities: ["High", "Critical"],
  blockedFindingCount: ([.matches[]? | select(
    .vulnerability.severity == "High" or .vulnerability.severity == "Critical"
  )] | length)
}' "$ARTIFACT_DIR/haproxy-vulnerabilities.json" \
  > "$ARTIFACT_DIR/haproxy-vulnerability-summary.json"
haproxy_blocked=$(jq -er '.blockedFindingCount' \
  "$ARTIFACT_DIR/haproxy-vulnerability-summary.json")
policy_blocked=0
if ((supply_chain_status != 0)); then
  if [[ "$POLICY_MODE" == collect ]] && jq -e '
    .status == "fail"
    and (.errors | length > 0)
    and ([.errors[] | startswith("vulnerability: unapproved ")] | all)
  ' "$ARTIFACT_DIR/supply-chain-policy-summary.json" >/dev/null; then
    policy_blocked=1
  else
    fail 'DSH/Caddy supply-chain policy rejected the candidate'
  fi
fi
if ((haproxy_blocked != 0)); then
  [[ "$POLICY_MODE" == collect ]] ||
    fail "HAProxy scan contains $haproxy_blocked High/Critical findings"
  policy_blocked=1
fi

# HAProxy remains an isolated non-publishing alternative, but its complete
# direct and Compose contracts are part of the candidate gateway evidence.
run_step env CONTRACT_DSH_IMAGE="$IMAGE_TAG" CONTRACT_PLATFORM=linux/arm64 \
  CONTRACT_HAPROXY_IMAGE="$HAPROXY_ARCHIVE_TAG" \
  bash "$REPO_ROOT/tests/haproxy-contract.sh"
run_step env HAPROXY_IMAGE="$HAPROXY_ARCHIVE_TAG" HAPROXY_PLATFORM=linux/arm64 \
  BACKEND_IMAGE="$IMAGE_TAG" BACKEND_PLATFORM=linux/arm64 \
  bash "$REPO_ROOT/tests/haproxy-runtime.sh"
run_step env DSH_IMAGE="$IMAGE_TAG" DSH_PLATFORM=linux/arm64 \
  HAPROXY_IMAGE="$HAPROXY_ARCHIVE_TAG" \
  bash "$REPO_ROOT/tests/haproxy-compose-runtime.sh"

docker version > "$ARTIFACT_DIR/docker-version.txt"
docker buildx version > "$ARTIFACT_DIR/buildx-version.txt"
df -h > "$ARTIFACT_DIR/disk-after.txt"
docker system df > "$ARTIFACT_DIR/docker-system-df-after.txt"

config_path=$(tar -xOf "$ARTIFACT_DIR/$DSH_ARCHIVE_NAME" manifest.json | jq -er '.[0].Config')
case "$config_path" in
  blobs/sha256/*) ;;
  *) fail "unexpected OCI config path: $config_path" ;;
esac
config_digest="sha256:${config_path##*/}"
test "$(tar -xOf "$ARTIFACT_DIR/$DSH_ARCHIVE_NAME" "$config_path" | sha256sum | cut -d' ' -f1)" = \
  "${config_digest#sha256:}"
manifest_digest=$(jq -r '."containerimage.digest" // empty' "$ARTIFACT_DIR/dsh-build-metadata.json")
if [[ -z "$manifest_digest" ]] && tar -tf "$ARTIFACT_DIR/$DSH_ARCHIVE_NAME" | grep -qx 'index.json'; then
  manifest_digest=$(tar -xOf "$ARTIFACT_DIR/$DSH_ARCHIVE_NAME" index.json | jq -r '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == "arm64")]
    | if length == 1 then .[0].digest else empty end
  ')
fi
[[ -z "$manifest_digest" || "$manifest_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail 'built manifest digest is malformed'

built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
candidate_status='external-native-arm64-candidate-built-not-released'
if ((policy_blocked != 0)); then
  candidate_status='external-native-arm64-evidence-blocked-not-released'
fi
readonly candidate_status
dsh_image_id=$(docker image inspect "$IMAGE_TAG" --format '{{.Id}}')
caddy_image_id=$(docker image inspect "$CADDY_REF" --format '{{.Id}}')
haproxy_image_id=$(docker image inspect "$HAPROXY_REF" --format '{{.Id}}')
dsh_archive_sha256=$(sha256sum "$ARTIFACT_DIR/$DSH_ARCHIVE_NAME" | cut -d' ' -f1)
caddy_archive_sha256=$(sha256sum "$ARTIFACT_DIR/$CADDY_ARCHIVE_NAME" | cut -d' ' -f1)
haproxy_archive_sha256=$(sha256sum "$ARTIFACT_DIR/$HAPROXY_ARCHIVE_NAME" | cut -d' ' -f1)
dsh_sbom_sha256=$(sha256sum "$ARTIFACT_DIR/dsh-sbom.syft.json" | cut -d' ' -f1)
caddy_sbom_sha256=$(sha256sum "$ARTIFACT_DIR/caddy-sbom.syft.json" | cut -d' ' -f1)
haproxy_sbom_sha256=$(sha256sum "$ARTIFACT_DIR/haproxy-sbom.syft.json" | cut -d' ' -f1)
provenance_sha256=$(sha256sum "$ARTIFACT_DIR/dsh-build-metadata.json" | cut -d' ' -f1)
policy_summary_sha256=$(sha256sum "$ARTIFACT_DIR/supply-chain-policy-summary.json" | cut -d' ' -f1)

jq \
  --arg sourceCommit "$SOURCE_COMMIT" \
  --arg sourceMode "$source_mode" \
  --arg sourceArchiveSha256 "$source_archive_sha256" \
  --arg builtAt "$built_at" \
  --arg candidateStatus "$candidate_status" \
  --arg policyMode "$POLICY_MODE" \
  --argjson dshCaddyPolicyExitStatus "$supply_chain_status" \
  --argjson haproxyBlockedFindingCount "$haproxy_blocked" \
  --arg imageTag "$IMAGE_TAG" \
  --arg imageId "$dsh_image_id" \
  --arg manifestDigest "$manifest_digest" \
  --arg configDigest "$config_digest" \
  --arg dshArchiveSha256 "$dsh_archive_sha256" \
  --arg caddyImageId "$caddy_image_id" \
  --arg caddyArchiveSha256 "$caddy_archive_sha256" \
  --arg haproxyImageId "$haproxy_image_id" \
  --arg haproxyArchiveSha256 "$haproxy_archive_sha256" \
  --arg dshSbomSha256 "$dsh_sbom_sha256" \
  --arg caddySbomSha256 "$caddy_sbom_sha256" \
  --arg haproxySbomSha256 "$haproxy_sbom_sha256" \
  --arg provenanceSha256 "$provenance_sha256" \
  --arg policySummarySha256 "$policy_summary_sha256" \
  --arg syftVersion "$SYFT_VERSION" \
  --arg grypeVersion "$GRYPE_VERSION" \
  --arg builderName "$BUILDER_NAME" \
  --arg buildkitRef "$BUILDKIT_REF" \
  --arg caddyRef "$CADDY_REF" \
  --arg caddyArchiveTag "$CADDY_ARCHIVE_TAG" \
  --arg haproxyRef "$HAPROXY_REF" \
  --arg haproxyArchiveTag "$HAPROXY_ARCHIVE_TAG" \
  --arg dshArchive "$DSH_ARCHIVE_NAME" \
  --arg caddyArchive "$CADDY_ARCHIVE_NAME" \
  --arg haproxyArchive "$HAPROXY_ARCHIVE_NAME" \
  '.schemaVersion = 1
   | .status = $candidateStatus
   | .target = "linux/arm64"
   | .source = {
       releaseInputs: "policy/release-inputs.json",
       commit: $sourceCommit,
       mode: $sourceMode,
       archiveSha256: (if $sourceArchiveSha256 == "" then null else $sourceArchiveSha256 end),
       builtAt: $builtAt
     }
   | .build = {
       environment: "external-native-linux-arm64-buildx",
       hostArchitecture: "aarch64",
       builderName: $builderName,
       buildkitRef: $buildkitRef
     }
   | .images = {
       dsh: {
         tag: $imageTag,
         imageId: $imageId,
         manifestDigest: (if $manifestDigest == "" then null else $manifestDigest end),
         configDigest: $configDigest,
         archive: $dshArchive,
         archiveSha256: $dshArchiveSha256
       },
       caddy: {
         ref: $caddyRef,
         archiveTag: $caddyArchiveTag,
         imageId: $caddyImageId,
         archive: $caddyArchive,
         archiveSha256: $caddyArchiveSha256
       },
       haproxy: {
         ref: $haproxyRef,
         archiveTag: $haproxyArchiveTag,
         imageId: $haproxyImageId,
         archive: $haproxyArchive,
         archiveSha256: $haproxyArchiveSha256,
         adoption: "isolated-non-publishing-poc"
       }
     }
   | .supplyChain = {
       policyMode: $policyMode,
       dshCaddyPolicyExitStatus: $dshCaddyPolicyExitStatus,
       haproxyBlockedFindingCount: $haproxyBlockedFindingCount,
       tools: {syftVersion: $syftVersion, grypeVersion: $grypeVersion},
       sbom: {
         dsh: {path: "dsh-sbom.syft.json", sha256: $dshSbomSha256},
         caddy: {path: "caddy-sbom.syft.json", sha256: $caddySbomSha256},
         haproxy: {path: "haproxy-sbom.syft.json", sha256: $haproxySbomSha256}
       },
       provenance: {path: "dsh-build-metadata.json", sha256: $provenanceSha256},
       policySummary: {path: "supply-chain-policy-summary.json", sha256: $policySummarySha256},
       vulnerabilityExceptions: "none-auto-accepted"
     }
   | .evidence = {
       runtimeCve: "runtime-cve-reachability.json",
       builderInspect: "builder-inspect.txt",
       dockerVersion: "docker-version.txt",
       buildxVersion: "buildx-version.txt",
       diskBefore: "disk-before.txt",
       diskAfter: "disk-after.txt",
       dockerSystemDfBefore: "docker-system-df-before.txt",
       dockerSystemDfAfter: "docker-system-df-after.txt"
     }' \
  "$INPUTS" > "$ARTIFACT_DIR/native-arm64-candidate-lock.json"

cp -- "$REPO_ROOT/compose.yaml" "$REPO_ROOT/compose.haproxy.yaml" \
  "$REPO_ROOT/Caddyfile" "$REPO_ROOT/.env.example" "$ARTIFACT_DIR/"
printf '%s\n' \
  'CANDIDATE ONLY: native external ARM64 build with retained SBOM, scan and BuildKit provenance evidence; no signature, publication or production acceptance is included.' \
  > "$ARTIFACT_DIR/CANDIDATE-NOT-RELEASE.txt"

(
  cd "$ARTIFACT_DIR"
  sha256sum -- \
    "$DSH_ARCHIVE_NAME" "$CADDY_ARCHIVE_NAME" "$HAPROXY_ARCHIVE_NAME" \
    compose.yaml compose.haproxy.yaml Caddyfile .env.example \
    native-arm64-candidate-lock.json CANDIDATE-NOT-RELEASE.txt \
    dsh-build-metadata.json dsh-image-inspect.json caddy-image-inspect.json \
    haproxy-image-inspect.json runtime-cve-reachability.json \
    dsh-sbom.syft.json dsh-sbom.cdx.json dsh-vulnerabilities.json \
    caddy-sbom.syft.json caddy-sbom.cdx.json caddy-vulnerabilities.json \
    haproxy-sbom.syft.json haproxy-sbom.cdx.json haproxy-vulnerabilities.json \
    haproxy-vulnerability-summary.json supply-chain-policy-summary.json \
    syft-version.txt grype-version.txt \
    builder-inspect.txt docker-version.txt buildx-version.txt docker-info.txt \
    host-uname.txt host-glibc.txt disk-before.txt disk-after.txt \
    docker-system-df-before.txt docker-system-df-after.txt started-at.txt \
    > SHA256SUMS
)

if ((policy_blocked != 0)); then
  printf 'BLOCKED: complete non-release ARM64 evidence bundle written to %s\n' "$ARTIFACT_DIR"
else
  printf 'Native ARM64 candidate bundle written to %s\n' "$ARTIFACT_DIR"
fi
