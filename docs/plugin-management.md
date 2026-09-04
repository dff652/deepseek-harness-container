# Offline plugin administration

The production `runtime` image remains shell-less and contains no npm/pnpm.
Plugin changes use the separate `plugin-admin` Dockerfile target. It carries
the same pinned DSH, Node and pnpm closure as the runtime build, accepts only a
reviewed local `.tgz`, and runs with `network_mode: none` plus pnpm's enforced
offline and ignore-scripts configuration. The add action also supplies those
two install flags explicitly.

The profile is restricted to `web`, `headless` or `disposable`. Actions are
restricted to `add`, `remove` and `list`; there is no publish, registry or
arbitrary shell action. The admin uses the same container path
`/var/lib/dsh` as runtime, but the Compose volume is independently named
`dsh-plugin-admin-candidate-home` by default. This path equality makes a
candidate handoff testable while the volume identity prevents accidental live
state reuse.

## Build the admin image

Build from the reviewed commit and exact architecture. Image construction may
need the approved build network for the pinned base/dependency inputs; the
administration run itself is offline.

```bash
platform=linux/arm64 # use linux/amd64 on an x86 build host
node_base_ref=$(jq -r --arg platform "$platform" \
  '.images.nodeBuild.platforms[$platform].ref' policy/release-inputs.json)
node_runtime_ref=$(jq -r --arg platform "$platform" \
  '.images.nodeRuntime.platforms[$platform].ref' policy/release-inputs.json)

docker build --platform "$platform" --target plugin-admin \
  --build-arg TARGETPLATFORM="$platform" \
  --build-arg NODE_BASE_REF="$node_base_ref" \
  --build-arg NODE_RUNTIME_REF="$node_runtime_ref" \
  --tag local/dsh-plugin-admin:0.1.1-rc.2 .
```

## Install an exact tarball

Prepare two host directories and place the ordinary, non-symlink tarball in the
input directory. The expected digest must come from the reviewed release
record.

```bash
mkdir -p plugin-inputs
install -d -m 0770 plugin-evidence
# The image runs as the same fixed uid/gid as the production runtime.
sudo chown 10001:10001 plugin-evidence
cp ./reviewed-plugin.tgz plugin-inputs/
sha256sum plugin-inputs/reviewed-plugin.tgz

export DSH_PLUGIN_INPUTS="$PWD/plugin-inputs"
export DSH_PLUGIN_EVIDENCE="$PWD/plugin-evidence"

docker compose -f compose.plugin-admin.yaml run --rm --no-deps \
  plugin-admin \
  --profile headless \
  --action add \
  --tarball /inputs/reviewed-plugin.tgz \
  --sha256 <64-hex-reviewed-digest>
```

The command fails before invoking DSH if the file is not a regular `.tgz` or
its SHA-256 differs. It also fails if `DSH_HOME` is overridden away from the
dedicated admin path. Each invocation creates a unique non-overwriting run
directory below `plugin-evidence` and prints that directory on success.
Evidence files are owned by uid/gid `10001`; inspect them with an account
granted access to that group or with an explicitly authorized privileged read.

## Inspect or remove

```bash
docker compose -f compose.plugin-admin.yaml run --rm --no-deps \
  plugin-admin --profile headless --action list

docker compose -f compose.plugin-admin.yaml run --rm --no-deps \
  plugin-admin --profile headless --action remove \
  --package-name @example/reviewed-plugin
```

Every run writes these files below a new unique run directory under
`DSH_PLUGIN_EVIDENCE`; the directory is printed on success and is retained on
failure:

- `dump-config.yaml`: DSH's composed profile configuration;
- `pnpm-lock.yaml`: the profile lockfile, or an explicit no-lock marker;
- `checksums.txt`: expected and observed tarball digest for `add`;
- `run-manifest.txt`: action, profile, DSH/Node/pnpm versions and offline
  boundary;
- `action.stdout`, `action.stderr`, `dump-config.stderr`: command evidence.

By default `dump-config.yaml` is a skip marker. A plugin whose composed patch
requires provider settings may be inspected with an explicit opt-in. Only the
following non-secret settings are allowlisted; package-manager actions still
run with a completely clean environment:

```bash
export PLUGIN_ADMIN_DUMP_CONFIG=1
export DSH_AIAH_COMMAND=/providers/aiah
export DSH_AGENT_MAIL_COMMAND=/providers/agent-mail-mcp
export DSH_AGENT_MAIL_HOME=/providers/agent-mail-home
export DSH_AGENT_MAIL_ID=container-admin
export DSH_AGENT_MAIL_HUB_URL=https://agent-mail.example.invalid/hub
```

Do not pass credentials, secret-file variables or URLs containing userinfo,
query tokens or fragments. The provider executable and home are not mounted by
this Compose file; this opt-in only verifies configuration composition.

Review the dump and lock before activating a runtime profile. Provider
executables, credentials and provider homes remain deployment-owned and are not
accepted as plugin-admin inputs.

## Current acceptance evidence

On 2026-09-04 the `linux/amd64` admin target was built with the exact AMD64
references from `policy/release-inputs.json`. With networking disabled, the
test installed `@dff652/dsh-ai-asset-hub@0.1.2` tarball SHA-256
`a36803b0863e03fbfc1b6c80e5c1300e467a3f2b924437d846c3d20c53b9e097`,
listed it, handed the same candidate volume to the shell-less production
runtime, and observed the expected `mcp-aiah` / `@deepseek-ai/dsh-mcp-client`
configuration. Remove and the final list also passed. A deliberately incorrect
digest failed before DSH add, and an explicit allowlisted dump-config run
passed.

This is local AMD64 candidate evidence only. It did not start the AIAH
provider, modify a live profile, publish an image or validate the admin target
on native ARM64. Native ARM64 plugin administration remains a #62 acceptance
step after pulling the reviewed commit and exact plugin tarball.

## Reset and rollback

Keep the evidence and a backup of the existing runtime `DSH_HOME` before any
handoff. The default candidate volume is safe for rehearsal. Selecting an
existing/live volume requires setting `DSH_PLUGIN_HOME_VOLUME` explicitly,
completing the backup and candidate review, and receiving separate deployment
authorization; the admin script itself cannot select a different container
`DSH_HOME` path. Never run `down --volumes` against the production Compose
project. A failed run returns non-zero and leaves its unique evidence directory
in place.
