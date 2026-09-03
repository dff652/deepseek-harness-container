# Native ARM64 build-host SOP

This procedure is for a maintainer who logs in to a native `aarch64` Docker
host, pulls this repository and builds a review-bound candidate. It contains no
company hostname, route, credential, registry login, publication or production
deployment step.

## Outcome and boundaries

The host produces an environment-specific directory under `artifacts/` with
the DSH, Caddy and HAProxy image archives plus runtime, SBOM, vulnerability,
BuildKit and checksum evidence. The result is never a published release or
production acceptance.

This is an online build that produces offline-loadable archives. The host must
be able to obtain the digest-pinned BuildKit and child/base images and the
package-manager dependencies required by the Dockerfile. A disconnected build
requires those inputs and the BuildKit cache to be prepared separately.

## Project scripts

| Path | Purpose | Mutates the host |
| --- | --- | --- |
| `scripts/check-release-inputs.py` | Validate the version and digest ledger | No |
| `scripts/preflight-native-arm64-host.sh` | Check host, source, tools, disk and local BuildKit readiness | No |
| `scripts/build-native-arm64-candidate.sh` | Build, test, scan and assemble the ARM64 evidence bundle | Yes: Docker images, containers, cache and a temporary dedicated builder |
| `scripts/save-pinned-image.sh` | Save an exact child image into an offline archive | Called by the build entrypoint |
| `scripts/audit-loaded-runtime-cve.sh` | Collect live runtime CVE reachability evidence | Called by the build entrypoint |
| `tests/native-arm64-candidate-contract.sh` | Check the entrypoint and preflight safety contracts | No Docker build |

Do not run `scripts/prepare-local-builder.sh` on a native ARM64 host. It is for
the separately reviewed x86/QEMU path and changes host `binfmt` state.

## One-time host preparation

An administrator prepares these prerequisites before the maintainer build:

- native `aarch64` Linux with GNU userspace;
- Git, Python 3, jq, tar, sha256sum and GNU timeout/coreutils;
- a working Docker daemon and Docker Buildx;
- the exact Syft and Grype versions in `policy/release-inputs.json`;
- the exact BuildKit image reference in that ledger, present in the local Docker
  image store;
- at least 6 GiB free space for the first gate. More free space is recommended
  because image layers, BuildKit cache and three archives coexist;
- network/proxy or preseeded inputs for the pinned base and gateway images and
  dependency installation.

Use approved packages or checksum-verified offline media. The repository does
not install host tools or use remote `curl | sh` installers.

After cloning the repository, inspect the required values:

```sh
cd /path/to/deepseek-harness-container
jq -r '.images.buildkit.ref, .tools.syft.version, .tools.grype.version' \
  policy/release-inputs.json
```

If policy permits an online pull, the administrator may pull the printed full
BuildKit reference. If an offline archive is used, validate its origin and
checksum and confirm that the same full reference is inspectable by Docker.

## Select the reviewed source

Build an exact reviewed 40-character commit, not a moving branch or tag. Use a
fresh clone or a dedicated worktree so local edits are not discarded:

```sh
cd /path/to/deepseek-harness-container
git fetch --prune origin
commit=<reviewed-40-character-commit>
git switch --detach "$commit"
test "$(git rev-parse HEAD)" = "$commit"
test -z "$(git status --porcelain)"
```

## Preflight

Run the read-only preflight first:

```sh
./scripts/preflight-native-arm64-host.sh
```

It must print `PASS` and the source commit, exact BuildKit reference, Syft/Grype
versions, available disk and builder state. It does not pull an image or create
a builder. Correct the reported prerequisite and rerun it; do not loosen a
digest, version, TLS or source-cleanliness check.

## Build

The default `gate` mode stops when any unapproved High/Critical finding is
present:

```sh
DSH_NATIVE_NETWORK_TIMEOUT_SECONDS=900 \
  ./scripts/build-native-arm64-candidate.sh
```

For an initial non-publishing canary, `collect` mode may continue through the
gateway tests and write a complete checksummed evidence bundle when the only
DSH/Caddy policy errors are unapproved vulnerability findings:

```sh
DSH_NATIVE_POLICY_MODE=collect \
DSH_NATIVE_NETWORK_TIMEOUT_SECONDS=900 \
  ./scripts/build-native-arm64-candidate.sh
```

`collect` does not approve, suppress or allowlist a finding. A blocked bundle
has status `external-native-arm64-evidence-blocked-not-released`. Schema,
provenance, source, license, tool-configuration and collection failures still
fail immediately. The current release baseline has known unresolved findings,
so a blocked evidence result is expected until they are remediated or reviewed
under the repository policy.

Set `DSH_NATIVE_KEEP_BUILDER=1` only when an administrator intentionally wants
the build-created dedicated builder retained for diagnosis or reuse. Otherwise
the script removes only the builder it created and leaves pre-existing builders
untouched.

## Verify and retain the result

The command prints the exact artifact directory. Verify it before copying:

```sh
artifact=/absolute/path/printed/by/the/build
(
  cd "$artifact"
  sha256sum -c SHA256SUMS
  jq '{status, target, source, build, supplyChain}' \
    native-arm64-candidate-lock.json
)
```

Retain the complete directory together with the reviewed commit record. Do not
copy only the image tar. A run that fails before `SHA256SUMS` is written is
partial diagnostic evidence and must not be reused as a candidate.

## Repeat for a DSH or base-image upgrade

For every DSH, Node, Distroless, Caddy, HAProxy, BuildKit, lockfile or policy
change:

1. review and commit the updated ledger and lockfiles;
2. provision any newly pinned host tools or BuildKit image;
3. select the new full commit and obtain a clean worktree;
4. rerun preflight and build without overwriting the previous artifact;
5. verify checksums and compare the new lock, SBOM, scan and runtime evidence;
6. treat publication, signing and production deployment as separate approvals.
