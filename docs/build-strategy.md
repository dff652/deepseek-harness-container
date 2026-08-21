# ARM64 build strategy

## Decision

Use three independent evidence levels:

1. local x86 Buildx/QEMU for fast `linux/arm64` candidate builds;
2. GitHub-hosted `ubuntu-24.04-arm` for a native ARM64 CI build and smoke;
3. the production-class ARM64 host, disconnected from registries, for final
   import, browser/model/provider, restart and cold-boot acceptance.

Neither of the first two levels is production acceptance. The target kernel,
cgroup, storage, network readiness, Caddy PKI, workspace ownership and native
modules are deployment evidence and must be tested on the real host.

## DSH installation boundary

The upstream quick-start command is:

```sh
npx @deepseek-ai/dsh web
```

It is appropriate for an online trial. When the package is absent, `npx`
resolves and fetches it through npm, and the command above does not pin a
version. A production image instead declares
`@deepseek-ai/dsh@0.1.1-rc.1`, commits the complete pnpm lock/build policy,
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

The 14 GiB disk is an acceptance constraint. The workflow must record image,
cache and archive sizes and fail clearly if the dependency closure plus export
does not fit. A larger runner is not silently selected to hide that failure.

## Local native amd64 regression candidate

The shared Dockerfile accepts an explicit immutable Node child manifest. On
2026-08-21 the local x86_64 host built `local/dsh:0.1.1-rc.1-amd64` with Node
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

This is a local regression target. It validates the shared container and
gateway contract faster than QEMU, but it is not ARM64 build, kernel, cold-boot
or production evidence and is not a multi-architecture release. After the
shared entrypoint and network policy changed, the earlier QEMU output was
superseded; the replacement candidate now records image `sha256:bec5923e…`,
config `sha256:66089779…` and passes the network-disabled ARM64 module/Web
smoke plus the trusted-CA 401/200, bad-Host 421, bad-Origin 403 and no-3080
Compose/Caddy checks. Native GitHub and production ARM acceptance remain
pending.

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
air-gap installation interface. The manual native-runner workflow publishes
architecture-specific `-amd64-candidate` and `-arm64-candidate` tags before it
creates a verified two-platform `-candidate` manifest. It never publishes
`latest`; formal tags still require real ARM and supply-chain release gates.
See [dual-architecture maintenance and publication](release-maintenance.md).

Docker-archive output does not preserve registry-attached attestations. When a
candidate is not pushed, SBOM and provenance are carried as separately hashed
files. If a later authorized workflow pushes a digest to GHCR, its attached
attestations and an offline verification bundle must both be retained.

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

- [DSH rc.1 root package requirements](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.1/package.json)
- [Docker multi-platform builds](https://docs.docker.com/build/building/multi-platform/)
- [GitHub private-repository ARM64 announcement](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/)
- [GitHub-hosted runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GitHub Actions security guidance](https://docs.github.com/en/actions/reference/security/secure-use)
