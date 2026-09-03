# Dual-architecture build strategy

## Decision

Use three independent evidence levels:

1. local x86 Buildx/QEMU for fast `linux/arm64` candidate builds;
2. GitHub-hosted `ubuntu-24.04-arm` for a native ARM64 CI build and smoke;
3. the production-class ARM64 host, disconnected from registries, for final
   import, browser/model/provider, restart and cold-boot acceptance.

Neither of the first two levels is production acceptance. The target kernel,
cgroup, storage, network readiness, Caddy PKI, workspace ownership and native
modules are deployment evidence and must be tested on the real host.

## External native ARM64 build host

An external `aarch64`/glibc Docker host may provide an additional native
candidate build. Run:

```sh
./scripts/build-native-arm64-candidate.sh
```

Registry/bootstrap operations default to a 300-second hard timeout and the
image build to 7200 seconds. Maintainers may lower these with
`DSH_NATIVE_NETWORK_TIMEOUT_SECONDS` and `DSH_NATIVE_STEP_TIMEOUT_SECONDS`;
timeouts are failures, never permission to reuse incomplete evidence. The
private forced-command runner may invoke the same script from a checksum- and
commit-verified `git archive`; direct users must use a clean Git worktree.

The entrypoint reads all versions and child digests from
`policy/release-inputs.json`, requires `uname -m=aarch64`, and creates or
verifies a dedicated digest-pinned `docker-container` Buildx builder. It does
not install emulation handlers, assume a company route, or accept arbitrary
remote shell text. A private runner wrapper is responsible for checkout,
authenticated access and an allowlisted argument vector. Exact ledger versions
of Syft and Grype are prerequisites; the entrypoint does not download tools.

The gates run serially: static Compose/security contracts, native runtime and
rc.2 package regressions, runtime-CVE evidence, exact Caddy/HAProxy archive
clean-load checks, actual-image SBOM/Grype policy, BuildKit provenance, and the
isolated gateway contracts. Each dynamic gate has an outer wall-clock timeout.
The resulting directory under `artifacts/` contains the DSH/Caddy/HAProxy
archives, SBOMs/scans, inspect/build evidence, candidate lock and `SHA256SUMS`. Its status is
`external-native-arm64-candidate-built-not-released`; no registry publication,
signature or production deployment is implied. A
pre-existing builder is never removed; a builder created by the script is
removed after the run unless `DSH_NATIVE_KEEP_BUILDER=1` is set.

## DSH installation boundary

The upstream quick-start command is:

```sh
npx @deepseek-ai/dsh web
```

It is appropriate for an online trial. When the package is absent, `npx`
resolves and fetches it through npm, and the command above does not pin a
version. A production image instead declares
`@deepseek-ai/dsh@0.1.1-rc.2`, commits the complete pnpm lock/build policy,
installs during the image build and directly executes the installed `dsh`
binary at runtime. Container startup performs no npm resolution or download.

The GitHub tag `zip` and `tar.gz` remain source snapshots, not platform
installers. They do not replace the npm runtime closure or its build steps.

## Local QEMU builder

The inspected development host is x86_64 with Docker 29.4.1, Buildx 0.31.1
and BuildKit 0.29.0. Before this implementation, its default builder advertised
only amd64 variants and no `qemu-aarch64` binfmt handler existed. An ARM64
Alpine probe therefore failed with `exec format error`.

Local enablement is an explicit host-admin operation:

- use the reviewed `tonistiigi/binfmt:qemu-v10.0.4` OCI index digest recorded
  by the preparation script;
- install only the `arm64` handler;
- require `/proc/sys/fs/binfmt_misc/qemu-aarch64` to be enabled with the `F`
  flag;
- prove a digest-pinned ARM64 probe reports `aarch64`;
- use a dedicated `docker-container` Buildx builder rather than changing the
  meaning of the default builder.

Two early registration attempts on 2026-08-21 made no host change because
Docker Hub requests ended with EOF. After registry recovery, the exact binfmt
reference installed only `arm64`; the probe reported `aarch64`, and the
dedicated digest-pinned BuildKit v0.29.0 builder reported `running` with
`linux/arm64`. The first QEMU candidate then built successfully and passed the
network-disabled version/Web/non-root/no-published-port smoke. A subsequent
local Compose run with `--no-build --pull never` used the exported Caddy root
CA and proved 401/200 authentication, 421 for an unapproved Host, 403 for a
mismatched Origin, healthy services and no published 3080. This is local
candidate evidence only, not a fully disconnected native or production ARM
acceptance.

## GitHub native ARM64

GitHub standard hosted ARM64 runners are available to private repositories.
The selected label is `ubuntu-24.04-arm`; the private-repository standard VM is
2 vCPU, 8 GiB memory and 14 GiB SSD and consumes the account's Actions minutes.
GitHub's 2026-01-29 announcement describes this runner as fully supported. The
preview marker in the current runner table applies to `ubuntu-26.04-arm`, not
the selected Ubuntu 24.04 label.

The first workflow should:

- run on pull requests without secrets, package write permission, publishing
  or signing;
- run one native `linux/arm64` build and local smoke;
- use full commit SHAs for every Action;
- record image ID, architecture, versions, build metadata and SHA-256;
- upload a Docker archive only on an explicitly permitted manual/tag path;
- keep GHCR publication, signing and release as later owner-authorized steps.

Native run [32553165653](https://github.com/dff652/deepseek-harness-container/actions/runs/32553165653)
completed these candidate gates for hardened source commit `84a8e5d…`. After
download, all bundle SHA-256 entries passed; the outer bundle hash was
`475cabe72feeecdf10ec5b7bafd035d8a772181ecb2faf575189963864600064`.
The tar index resolved exactly one `linux/arm64` manifest
(`sha256:716a9e62…`), whose blob and referenced config (`sha256:90145b53…`)
were independently rehashed. The committed
`policy/native-arm64-lock.json` preserves that environment-specific evidence.
Its SBOM/provenance fields remain null, so this is native build/runtime evidence,
not supply-chain approval or production-host acceptance.

Distroless runtime-source run
[32557974575](https://github.com/dff652/deepseek-harness-container/actions/runs/32557974575)
then rebuilt commit `feb4469…` with the pinned Distroless runtime. All native
build, runtime, static-contract and bundle-upload steps passed. The downloaded
bundle's listed `SHA256SUMS` entries passed; its generated lock records manifest
`sha256:cbc3de07…`, config `sha256:7cc4826b…`, the exact source/run and no
QEMU-only binfmt/probe claims. SBOM and provenance remain null, so publication
and production-host acceptance remain blocked.

Native run
[32664545874](https://github.com/dff652/deepseek-harness-container/actions/runs/32664545874)
rebuilt source `8b9ce04…` and passed the isolated HAProxy config/direct/Compose
contract plus destructive clean-load checks for the HAProxy and default Caddy
archive tags on GitHub's classic Docker image store. Its downloaded bundle
resolved DSH manifest `sha256:101a1b8a…`, config `sha256:0477a2f1…` and the
expected ARM64 Caddy archive tag. This closes the native CI functional gap,
not HAProxy adoption, publication or production-host acceptance.

The 14 GiB disk is an acceptance constraint. The workflow must record image,
cache and archive sizes and fail clearly if the dependency closure plus export
does not fit. A larger runner is not silently selected to hide that failure.

## Local native AMD64 regression candidates

The shared Dockerfile accepts an explicit immutable Node child manifest. As
historical rc.1 evidence, on 2026-08-21 the local x86_64 host built
`local/dsh:0.1.1-rc.1-amd64` with Node
amd64 child `sha256:65932751…` and packaged Caddy amd64 child
`sha256:98eb57d8…`. Network concurrency was bounded at four while all 504 lock
entries still passed the registry-backed supply-chain policy.

The first native amd64 start exposed an HMR timing path that required Node's
`--expose-internals`; the shared runtime now invokes the exact installed DSH
module with that explicit flag. The rebuilt image passed disconnected
version/Web smoke, UID 10001, no published 3080, and direct loading of Koffi,
node-pty, Landlock and Sharp. The amd64 Compose override then passed trusted-CA
401/200, bad-Host 421, bad-Origin 403 and healthy-service checks with
`--no-build --pull never`.

That rc.1 build remains a historical local regression target. It validates the shared container and
gateway contract faster than QEMU, but it is not ARM64 build, kernel, cold-boot
or production evidence and is not a multi-architecture release.

The current rc.2 remediation candidate keeps Bookworm only as a build stage
and uses the same exact Distroless Node 24 runtime children. Its native AMD64
manifest/config are `sha256:3cea6dff…` / `sha256:783f744f…`; its x86/QEMU
ARM64 manifest/config are `sha256:0c1fe2ec…` / `sha256:c3511761…`. Both passed
the network-disabled module/Web, request-image state, read-only-root,
shell-absence and UID 10001 checks. The Caddy and isolated HAProxy Compose
profiles also passed on native AMD64 and QEMU ARM64. A same-tool scan reports
four DSH High/Critical matches on each architecture. GitHub-native rc.2 runs
`32699950087` (AMD64) and `32699954057` (ARM64) subsequently passed their
source-specific build/runtime/bundle gates. All disconnected production-host
acceptance still must run before release. See the
[rc.2 readiness record](rc2-release-readiness.md) for exact evidence and open
feature/supply-chain gates.

The build workflows now run seven exact-rc.2 package contracts and a live
runtime CVE collector against the image they just loaded. The collector binds
the same-repository digest, platform, version, entrypoint, actual PID 1 argv,
ELF imports and expected loopback listener. Non-publishing builds retain
blocked reports as evidence but reject collection failures; the Docker Hub
workflow runs the same collector in fail-closed `gate` mode. The x86/QEMU
ARM64 report conservatively leaves the OpenSSL QUIC item `unknown` because the
emulator wraps PID 1 argv; this is not native ARM equivalence.
The existing rc.2 GitHub run IDs predate this unpushed workflow update, so they
must not be cited as live-collector evidence until a new authorized run passes.

## GitHub native AMD64

`.github/workflows/build-amd64.yml` is the non-publishing native counterpart to
the ARM64 workflow. Pull requests run static contracts plus the pinned AMD64
build/runtime smoke without secrets. An owner-triggered `workflow_dispatch`
may additionally assemble a 14-day offline candidate artifact containing the
exact DSH and Caddy archives, Compose/Caddy inputs, runner/build inspection,
environment-specific candidate lock and `SHA256SUMS`.

This workflow uses `ubuntu-24.04`, `contents: read`, pinned Action and BuildKit
identities and exact AMD64 child manifests. It does not log in to a registry,
push an image, create a manifest list, sign or release.

Native run
[32559547026](https://github.com/dff652/deepseek-harness-container/actions/runs/32559547026)
successfully built and smoked source commit `6bed724…`. The downloaded bundle
verified every `SHA256SUMS` entry and resolved exactly one Linux AMD64 manifest
(`sha256:c6e6afd4…`) with config `sha256:cf24849c…`; its DSH and Caddy archive
hashes also matched the generated lock. The lock contains no ARM/QEMU-only
fields and keeps SBOM/provenance null. This closes only the GitHub-native AMD64
build/runtime/bundle evidence gap, not the publication gate.

Latest run
[32664544119](https://github.com/dff652/deepseek-harness-container/actions/runs/32664544119)
rebuilt source `8b9ce04…`, passed the isolated HAProxy and default-Caddy
classic-store clean-load contracts, and produced DSH manifest
`sha256:fb8fad14…` with config `sha256:49d9d255…`. The downloaded bundle and
every internal checksum passed independent verification. The manual candidate
still bundles only the default Caddy appliance.

## GHCR and offline artifacts

Private GHCR is useful as an online build-zone registry, but a disconnected
production host cannot depend on it. The offline bundle remains the release
interface:

```text
DSH ARM64 Docker archive
Caddy ARM64 Docker archive
Compose and Caddy configuration
image lock and build metadata
SBOM and provenance/attestation material
SHA256SUMS
```

Docker Hub is an optional public candidate distribution channel, not the
air-gap installation interface. The manual workflow first completes native
AMD64/ARM64 runtime and supply-chain gates without registry credentials. It
transports the approved local images as short-retention Actions artifacts;
only a dependent publication job receives Docker Hub credentials, pushes the
architecture-specific tags, resolves their digests and creates a verified
two-platform `-candidate` manifest from those digests. It refuses to replace
an existing candidate tag and never publishes `latest`; formal tags still
require real ARM, signed attestations and the remaining release gates.
See [dual-architecture maintenance and publication](release-maintenance.md).

Registry-attached artifact preservation in a Docker archive depends on the
Engine, image store and export tool. The verified Docker 29/containerd-store
Caddy archive retains upstream subject manifests carrying SPDX/in-toto and
SLSA material, while GitHub's classic store exports the legacy config/layers
and RepoTag without that registry manifest identity. The portable air-gap
contract therefore starts from a digest-selected source but runs the loaded
image by a dedicated same-repository archive tag, verified against the bundle
SHA, config digest and platform. Those upstream subjects
are neither DSH build attestations nor a completed project verification gate.
Project SBOM and provenance therefore remain separately hashed evidence; a
later authorized registry publication must retain its attached attestations
and the offline verification bundle.

For the Docker Hub candidate path, "provenance" currently means separately
hashed BuildKit `mode=max` build metadata plus the source/image coherence
summary. It is not a signed registry attestation. Direct-push SBOM/provenance
attestations and signing belong to the separately authorized formal-release
workflow; the presence of unverified upstream subjects in a local archive is
not a substitute.

Actions artifacts are temporary transport, not the long-term registry or the
release authority. Tar the bundle before upload so file modes are not silently
lost, give it an explicit retention period and verify both GitHub's artifact
digest and the bundle's own `SHA256SUMS` after download.

## CI and runner security

- Prefer GitHub-hosted ephemeral native ARM VMs.
- Do not register the production ARM host as a self-hosted runner.
- Do not use `pull_request_target` to build untrusted checkout content.
- Give ordinary build jobs `contents: read` only.
- Never expose model/provider credentials, production Caddy state or signing
  identity to a pull-request job.
- Pin Actions, base images, npm/PyPI inputs and tool downloads by immutable
  identity.

## Upstream references

- [DSH rc.2 root package requirements](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.2/package.json)
- [Google Distroless supported images and security-update model](https://github.com/GoogleContainerTools/distroless)
- [Distroless Node.js runtime contents](https://github.com/GoogleContainerTools/distroless/blob/main/nodejs/README.md)
- [Docker multi-platform builds](https://docs.docker.com/build/building/multi-platform/)
- [GitHub private-repository ARM64 announcement](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/)
- [GitHub-hosted runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GitHub Actions security guidance](https://docs.github.com/en/actions/reference/security/secure-use)
