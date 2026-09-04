#!/usr/bin/env bash
set -Eeuo pipefail

# One-shot, offline-only plugin administration. This script is the entrypoint
# of the dedicated plugin-admin image; it is deliberately not copied into the
# production runtime image.

readonly DSH_ENTRY=/opt/dsh/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js
readonly DEFAULT_DSH_HOME=/var/lib/dsh
readonly INPUT_ROOT=/inputs
readonly EVIDENCE_ROOT=/evidence

DSH_HOME=${DSH_HOME:-$DEFAULT_DSH_HOME}
HOME_VOLUME=${PLUGIN_ADMIN_HOME_VOLUME:-dsh-plugin-admin-candidate-home}
DUMP_CONFIG_ENABLED=${PLUGIN_ADMIN_DUMP_CONFIG:-0}
PROFILE=''
ACTION=''
TARBALL=''
EXPECTED_SHA256=''
PACKAGE_NAME=''

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage:
  plugin-admin.sh --profile <web|headless|disposable> --action add \
    --tarball /inputs/<package>.tgz --sha256 <64-hex>
  plugin-admin.sh --profile <web|headless|disposable> --action remove \
    --package-name <package-name>
  plugin-admin.sh --profile <web|headless|disposable> --action list

Actions are deliberately limited to add, remove and list. The image always
runs with network disabled and pnpm offline/ignore-scripts settings. Each run
writes action, checksum, dump-config and pnpm-lock evidence under /evidence.
EOF
}

while (($#)); do
  case "$1" in
    --profile)
      (($# >= 2)) || fail '--profile needs a value'
      [[ -z "$PROFILE" ]] || fail '--profile may be supplied once'
      PROFILE=$2
      shift 2
      ;;
    --action)
      (($# >= 2)) || fail '--action needs a value'
      [[ -z "$ACTION" ]] || fail '--action may be supplied once'
      ACTION=$2
      shift 2
      ;;
    --tarball)
      (($# >= 2)) || fail '--tarball needs a value'
      [[ -z "$TARBALL" ]] || fail '--tarball may be supplied once'
      TARBALL=$2
      shift 2
      ;;
    --sha256)
      (($# >= 2)) || fail '--sha256 needs a value'
      [[ -z "$EXPECTED_SHA256" ]] || fail '--sha256 may be supplied once'
      EXPECTED_SHA256=$2
      shift 2
      ;;
    --package-name)
      (($# >= 2)) || fail '--package-name needs a value'
      [[ -z "$PACKAGE_NAME" ]] || fail '--package-name may be supplied once'
      PACKAGE_NAME=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$PROFILE" ]] || fail '--profile is required'
[[ -n "$ACTION" ]] || fail '--action is required'
case "$PROFILE" in
  web|headless|disposable) ;;
  *) fail 'profile must be one of web, headless or disposable' ;;
esac
case "$ACTION" in
  add|remove|list) ;;
  *) fail 'action must be one of add, remove or list' ;;
esac

# The container path is fixed so candidate state has the same layout as the
# runtime. Volume identity, backup and handoff authorization are enforced by
# the Compose invocation and SOP rather than by accepting another home path.
[[ "$DSH_HOME" == "$DEFAULT_DSH_HOME" ]] ||
  fail "DSH_HOME must be $DEFAULT_DSH_HOME"
[[ "$HOME_VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] ||
  fail 'PLUGIN_ADMIN_HOME_VOLUME is not a safe volume name'
case "$DUMP_CONFIG_ENABLED" in
  0|1) ;;
  *) fail 'PLUGIN_ADMIN_DUMP_CONFIG must be 0 or 1' ;;
esac
[[ -d "$INPUT_ROOT" && ! -L "$INPUT_ROOT" ]] || fail '/inputs must be a real directory'
[[ -d "$EVIDENCE_ROOT" && ! -L "$EVIDENCE_ROOT" && -w "$EVIDENCE_ROOT" ]] ||
  fail '/evidence must be an existing writable directory'
[[ -f "$DSH_ENTRY" && ! -L "$DSH_ENTRY" ]] || fail 'DSH entrypoint is missing'
command -v node >/dev/null 2>&1 || fail 'node is required'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'
command -v realpath >/dev/null 2>&1 || fail 'realpath is required'

if [[ "$ACTION" == add ]]; then
  [[ -n "$TARBALL" ]] || fail 'add requires --tarball'
  [[ -n "$EXPECTED_SHA256" ]] || fail 'add requires --sha256'
  [[ -z "$PACKAGE_NAME" ]] || fail 'add does not accept --package-name'
  [[ "$TARBALL" == "$INPUT_ROOT"/* ]] || fail '--tarball must be under /inputs'
  [[ "$TARBALL" == *.tgz ]] || fail '--tarball must be an ordinary .tgz file'
  [[ -f "$TARBALL" && ! -L "$TARBALL" ]] || fail '--tarball must be a regular non-symlink file'
  TARBALL=$(realpath -e -- "$TARBALL") || fail '--tarball path cannot be resolved'
  [[ "$TARBALL" == "$INPUT_ROOT"/* && "$TARBALL" == *.tgz ]] ||
    fail '--tarball must resolve to a .tgz below /inputs'
  [[ -f "$TARBALL" && ! -L "$TARBALL" ]] || fail '--tarball must resolve to a regular file'
  [[ "$EXPECTED_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || fail '--sha256 must be 64 hexadecimal characters'
  EXPECTED_SHA256=${EXPECTED_SHA256,,}
else
  [[ -z "$TARBALL" && -z "$EXPECTED_SHA256" ]] ||
    fail '--tarball/--sha256 are only valid for add'
fi

if [[ "$ACTION" == remove ]]; then
  [[ -n "$PACKAGE_NAME" ]] || fail 'remove requires --package-name'
  [[ "$PACKAGE_NAME" =~ ^@?[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]] ||
    fail '--package-name is not a safe package name'
else
  [[ -z "$PACKAGE_NAME" ]] || fail '--package-name is only valid for remove'
fi

mkdir -p -- "$DSH_HOME"
RUN_DIR=$(mktemp -d "$EVIDENCE_ROOT/run.XXXXXX") || fail 'unable to create evidence run directory'
[[ -d "$RUN_DIR" && ! -L "$RUN_DIR" ]] || fail 'evidence run directory is unsafe'
readonly RUN_DIR
readonly PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
readonly ACTION_STDOUT="$RUN_DIR/action.stdout"
readonly ACTION_STDERR="$RUN_DIR/action.stderr"
readonly DUMP_CONFIG="$RUN_DIR/dump-config.yaml"
readonly DUMP_STDERR="$RUN_DIR/dump-config.stderr"
readonly LOCK_EVIDENCE="$RUN_DIR/pnpm-lock.yaml"
readonly CHECKSUM_EVIDENCE="$RUN_DIR/checksums.txt"
readonly RUN_MANIFEST="$RUN_DIR/run-manifest.txt"

node_dsh() {
  # env -i prevents credentials or deployment-owned variables from leaking
  # into the one-shot package-manager process. All command arguments are an
  # argv array; no shell command string is evaluated.
  env -i \
    DSH_HOME="$DSH_HOME" \
    HOME="$DSH_HOME" \
    NODE_ENV=production \
    COREPACK_HOME=/opt/corepack \
    PNPM_HOME=/pnpm \
    PNPM_CONFIG_OFFLINE=true \
    PNPM_CONFIG_IGNORE_SCRIPTS=true \
    PNPM_CONFIG_STORE_DIR="$DSH_HOME/.pnpm-store" \
    PATH="$PATH" \
    node "$DSH_ENTRY" "$@"
}

node_dsh_dump() {
  local -a dump_env=(
    "DSH_HOME=$DSH_HOME"
    "HOME=$DSH_HOME"
    'NODE_ENV=production'
    'COREPACK_HOME=/opt/corepack'
    'PNPM_HOME=/pnpm'
    'PNPM_CONFIG_OFFLINE=true'
    'PNPM_CONFIG_IGNORE_SCRIPTS=true'
    "PNPM_CONFIG_STORE_DIR=$DSH_HOME/.pnpm-store"
    "PATH=$PATH"
  )
  local variable value
  for variable in \
    DSH_AIAH_COMMAND \
    DSH_AGENT_MAIL_COMMAND \
    DSH_AGENT_MAIL_HOME \
    DSH_AGENT_MAIL_ID \
    DSH_AGENT_MAIL_HUB_URL; do
    if [[ -v "$variable" ]]; then
      value=${!variable}
      [[ -n "$value" ]] || continue
      case "$variable" in
        DSH_AIAH_COMMAND|DSH_AGENT_MAIL_COMMAND|DSH_AGENT_MAIL_HOME)
          [[ "$value" == /* ]] || fail "$variable must be an absolute path"
          ;;
        DSH_AGENT_MAIL_ID)
          [[ "$value" != human@local && "$value" =~ ^[A-Za-z0-9._@-]+$ ]] ||
            fail 'DSH_AGENT_MAIL_ID is not a safe non-human identity'
          ;;
        DSH_AGENT_MAIL_HUB_URL)
          [[ "$value" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/-]*)?$ ]] ||
            fail 'DSH_AGENT_MAIL_HUB_URL must be a credential-free HTTPS URL'
          ;;
      esac
      dump_env+=("$variable=$value")
    fi
  done
  env -i "${dump_env[@]}" node "$DSH_ENTRY" "$@"
}

if [[ "$ACTION" == add ]]; then
  ACTUAL_SHA256=$(sha256sum -- "$TARBALL" | awk '{print tolower($1)}')
  [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
    printf 'expected=%s\nactual=%s\nfile=%s\n' \
      "$EXPECTED_SHA256" "$ACTUAL_SHA256" "$(basename -- "$TARBALL")" > "$CHECKSUM_EVIDENCE"
    fail 'tarball SHA-256 does not match the reviewed digest'
  }
  printf 'expected=%s\nactual=%s\nfile=%s\n' \
    "$EXPECTED_SHA256" "$ACTUAL_SHA256" "$(basename -- "$TARBALL")" > "$CHECKSUM_EVIDENCE"
else
  printf 'action=%s\nno tarball supplied\n' "$ACTION" > "$CHECKSUM_EVIDENCE"
fi

case "$ACTION" in
  add)
    node_dsh plugin --profile "$PROFILE" add --offline --ignore-scripts -w "$TARBALL" \
      >"$ACTION_STDOUT" 2>"$ACTION_STDERR" ||
      fail 'dsh plugin add failed; see action.stdout/action.stderr'
    ;;
  remove)
    # pnpm remove rejects install-only CLI flags; the clean process environment
    # still enforces offline mode and disables lifecycle scripts.
    node_dsh plugin --profile "$PROFILE" remove "$PACKAGE_NAME" \
      >"$ACTION_STDOUT" 2>"$ACTION_STDERR" ||
      fail 'dsh plugin remove failed; see action.stdout/action.stderr'
    ;;
  list)
    # pnpm list is read-only and does not accept install-only flags. The
    # process still inherits the fail-closed offline/ignore-scripts config.
    node_dsh plugin --profile "$PROFILE" list \
      >"$ACTION_STDOUT" 2>"$ACTION_STDERR" ||
      fail 'dsh plugin list failed; see action.stdout/action.stderr'
    ;;
esac

if [[ "$DUMP_CONFIG_ENABLED" == 1 ]]; then
  node_dsh_dump --profile "$PROFILE" --dump-config >"$DUMP_CONFIG" 2>"$DUMP_STDERR" ||
    fail 'dsh --dump-config failed; see dump-config.stderr'
else
  printf '# dump-config skipped by default; set PLUGIN_ADMIN_DUMP_CONFIG=1 and provide only the documented provider variables\n' > "$DUMP_CONFIG"
  printf 'dump-config skipped (PLUGIN_ADMIN_DUMP_CONFIG=0)\n' > "$DUMP_STDERR"
fi

if [[ -f "$PROFILE_DIR/pnpm-lock.yaml" ]]; then
  cp -- "$PROFILE_DIR/pnpm-lock.yaml" "$LOCK_EVIDENCE"
else
  printf '# profile has no pnpm lockfile\n' > "$LOCK_EVIDENCE"
fi

{
  printf 'status=PASS\n'
  printf 'action=%s\n' "$ACTION"
  printf 'profile=%s\n' "$PROFILE"
  printf 'dsh_home=%s\n' "$DSH_HOME"
  printf 'home_volume=%s\n' "$HOME_VOLUME"
  printf 'network=none\n'
  printf 'pnpm=offline,ignore-scripts\n'
  printf 'dump_config=%s\n' "$DUMP_CONFIG_ENABLED"
  printf 'dsh_version='; node_dsh --version
  printf 'node_version='; node --version
  printf 'pnpm_version='; env -i COREPACK_HOME=/opt/corepack PNPM_HOME=/pnpm PATH="$PATH" pnpm --version
  printf 'evidence=dump-config.yaml,pnpm-lock.yaml,checksums.txt\n'
} > "$RUN_MANIFEST"

echo "PASS: plugin-admin $ACTION completed for profile $PROFILE; evidence: $RUN_DIR"
