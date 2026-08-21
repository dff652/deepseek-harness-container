# DeepSeek Harness Container

<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="DeepSeek Harness Container: an offline-first AMD64 and ARM64 appliance with Caddy HTTPS on port 443 and DSH restricted to container loopback">
</p>

Reproducible, offline-first container delivery for DeepSeek Harness on Linux
AMD64 and ARM64, with an authenticated IP-only HTTPS entry and an explicit
development capability boundary.

## Project status

**Local AMD64, QEMU ARM64 and native GitHub ARM64 candidates built — the local
images passed the shared runtime, native-module, Compose and Caddy HTTPS gateway
acceptance; the native ARM candidate passed its build/runtime/bundle gates. No
container image has been published, released or deployed.**

The corrected amd64 candidate records DSH image ID `sha256:5a7c4f1a…` and OCI
config digest `sha256:5e82d2be…`; its runtime smoke
also loads Koffi, node-pty, Landlock and Sharp with networking disabled. The
local appliance run used the exported Caddy root CA (not `-k`) and proved
401 without credentials, 200 with credentials, 421 for an unapproved Host,
403 for a mismatched Origin, healthy services and no published port 3080.
The ARM candidate records image ID `sha256:bec5923e…` and config digest
`sha256:66089779…`; its QEMU appliance also proved the same trusted-CA
401/200, bad-Host 421, bad-Origin 403, healthy services and no published 3080.
GitHub [native ARM run 32499388906](https://github.com/dff652/deepseek-harness-container/actions/runs/32499388906)
then produced manifest `sha256:4712317a…` and config `sha256:e8473358…`; the
downloaded artifact was independently rehashed and matched its candidate lock.
Real disconnected production-ARM acceptance remains open.

This repository was created to separate the OCI/Compose release lifecycle from
the configuration-only plugin packages in the sibling
`deepseek-harness-plugins` project. The currently running host installation is
not changed by this scaffold. That existing DSH instance is a host/user-level
Node/pnpm installation managed by user systemd; it is not running inside the
Caddy container and is not converted to containers by creating this project.

The candidate targets this exact tuple:

| Component | Candidate pin | State |
|---|---:|---|
| DeepSeek Harness | `0.1.1-rc.1` | AMD64 native, ARM64 QEMU and GitHub native ARM candidates passed; production ARM pending |
| DSH tag/commit | `dsh-v0.1.1-rc.1` / `528c682e061696f5a160f363f236ecbf53cbd006` | Verified upstream identity |
| Node.js | `24.19.0` | Locked in runtime and base image |
| pnpm | `11.7.0` | Locked with Corepack integrity |
| Caddy | `2.11.4` | OCI index plus AMD64/ARM64 child digests locked |
| Production target | `linux/arm64`, glibc | QEMU and GitHub native candidates passed; production ARM pending |
| Local test target | `linux/amd64`, glibc | native runtime and Compose/Caddy acceptance passed |

No `latest`, branch head, machine path, private IP, credential or unresolved
release digest is accepted in a release candidate.

The GitHub tag page's automatic `zip` and `tar.gz` downloads are source-tree
snapshots. They are useful for source review and source builds, but they are
not prebuilt ARM64 installers and do not contain the npm dependency closure.
The container plan therefore consumes the exact published npm package plus a
committed pnpm lock/build policy. Its integrity-locked pnpm store is fetched in
the networked image-build stage, then used offline for installation; the
runtime and disconnected target perform no package download. A GitHub source
archive is never renamed and treated as an offline installer.

## Build a local candidate

The repository keeps one Dockerfile and architecture-specific immutable base
image references. On an x86_64 build host with the reviewed Buildx builder:

```sh
./scripts/build-amd64-candidate.sh
```

This writes a candidate-only directory under `artifacts/` containing the DSH
and Caddy Docker archives, Compose files, environment-specific image lock,
inspect/build metadata and `SHA256SUMS`. It also runs the network-disabled
native-module and Web smoke before packaging.

The ARM64 paths remain separate evidence levels:

- `scripts/build-candidate.sh` builds a local x86/QEMU ARM64 candidate;
- `.github/workflows/build-arm64.yml` builds and smokes on native
  `ubuntu-24.04-arm`;
- the disconnected production-class ARM host performs final import, browser,
  model/MCP, restart and cold-boot acceptance.

`scripts/prepare-local-builder.sh` changes host binfmt state and is required
only when intentionally enabling the reviewed local QEMU builder. Inspect it
before running it.

## Candidate publication

The manual Docker Hub workflow maintains three candidate-only tags:

```text
dff652/deepseek-harness-container:0.1.1-rc.1-amd64-candidate
dff652/deepseek-harness-container:0.1.1-rc.1-arm64-candidate
dff652/deepseek-harness-container:0.1.1-rc.1-candidate
```

The last tag is a manifest list containing exactly Linux AMD64 and ARM64. The
workflow builds on native GitHub runners, smokes each architecture before its
push and requires the literal confirmation `publish-candidate`. It needs the
repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. It never writes
`latest`; formal version tags remain gated by the release checklist and real
ARM acceptance.

See [dual-architecture maintenance and publication](docs/release-maintenance.md)
for the update order, tag policy and rollback contract.

## Design boundaries

1. Keep this as an independent public project with no deployment secrets. It owns Dockerfiles,
   Compose, Caddy, image locks, SBOM/provenance and offline bundles; it does not
   own DSH source, plugin logic or provider business logic.
2. Keep DSH on container loopback. A Caddy sidecar joins the DSH network
   namespace with `network_mode: service:dsh`; only the selected host IP on
   port 443 is published.
3. Treat x86 Buildx/QEMU output as a candidate only. Production acceptance must
   run on a real ARM64 host with networking disconnected.
4. Give an Agent explicit capabilities instead of “host escape”: one approved
   workspace, a versioned development toolchain and allowlisted service
   endpoints. Host administration and image builds use a separate runner.
5. Define “ready to use” as verified image import plus small deployment-owned
   initialization: fixed IP, bcrypt hash, absolute workspace, client CA trust
   and model/provider credentials. Secrets are never baked into an image.

## Intended architecture

```text
managed LAN browser
  -> https://ARM_IP:443 + Basic Auth + trusted local CA
  -> Caddy sidecar
       network_mode: service:dsh
  -> DSH 127.0.0.1:3080
       + persistent DSH_HOME
       + explicit /workspace
       + approved model/MCP endpoints
```

A one-shot, network-disabled `caddy-init` service creates only
`/data/caddy` and `/config/caddy` for UID/GID `1000:1000`; the long-running
Caddy process stays non-root. DSH remains fixed at `10001:10001`, so the host
workspace must be prepared for that identity.

The host never publishes port 3080. The default design also forbids host
networking, privileged containers, Docker socket mounts, broad host mounts and
`SYS_ADMIN`/`NET_ADMIN`.

Caddy is not required for the existing host/systemd installation: one
administrator can SSH-forward that host's DSH loopback listener. In the
container topology, however, host SSH cannot reach a loopback socket inside a
different network namespace. A same-namespace relay is still required; this
project deliberately uses Caddy so multiple managed LAN devices get an
authenticated HTTPS endpoint by IP while DSH keeps its upstream loopback trust
boundary. Publishing raw DSH HTTP by IP is not the accepted alternative.

## Documentation

- [Architecture and product boundaries](docs/architecture.md)
- [Offline ARM64 delivery SOP](docs/offline-airgap.md)
- [Local QEMU and GitHub ARM64 build strategy](docs/build-strategy.md)
- [Agent development capability boundary](docs/agent-development-boundary.md)
- [Python SDK headless deployment evaluation](docs/python-sdk-evaluation.md)
- [Security policy](SECURITY.md)
- [Dual-architecture maintenance and publication](docs/release-maintenance.md)

## Implemented candidate outputs

```text
Dockerfile
compose.yaml
compose.amd64.yaml
Caddyfile
runtime/
  package.json
  pnpm-lock.yaml
  pnpm-workspace.yaml
policy/
  image-lock.json
  native-arm64-lock.json
scripts/
  prepare-local-builder.sh
  build-candidate.sh
  build-amd64-candidate.sh
tests/
  amd64-compose-contract.sh
  amd64-runtime.sh
  compose-contract.sh
  negative-exposure.sh
  native-workflow-contract.sh
  caddy-volume-init.sh
  arm64-runtime.sh
  dockerhub-workflow-contract.sh
assets/readme/
  hero.svg
```

The build workflow lives at `.github/workflows/build-arm64.yml`. Repository
policy records both the rebuilt QEMU output and verified native GitHub output
as candidate-only. Each new ARM64 or AMD64 bundle generates an
environment-specific candidate lock;
SBOM and separate provenance fields remain null. Every artifact is explicitly
marked candidate-only and is not the complete release bundle described below.

## Release boundary

A successful image build is not a release. The first candidate must prove:

- exact image architecture, DSH/Node/pnpm/Caddy/provider identities;
- SBOM, provenance, license, vulnerability and secret gates;
- disconnected `docker compose up --no-build --pull never`;
- no published 3080 or dangerous host capability;
- Caddy unauthenticated 401, authenticated 200 and trusted client certificate;
- authenticated requests with malicious Host/Origin/cross-site metadata denied
  before loopback header adaptation;
- real browser settings, model request and MCP tool call;
- workspace-only writes, provider failure/reconnect and child cleanup;
- restart, exact-address cold boot and rollback on real ARM64.

Commit, push, repository visibility, registry publication, signing, release and
deployment remain separate owner-authorized operations.

## Upstream references

- [DeepSeek Harness `dsh-v0.1.1-rc.1`](https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.1.1-rc.1)
- [Docker Compose networking modes](https://docs.docker.com/compose/how-tos/networking/#change-the-network-mode)
- [Docker multi-platform builds](https://docs.docker.com/build/building/multi-platform/)
- [Docker daemon attack surface](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)
- [Caddy local HTTPS](https://caddyserver.com/docs/automatic-https#local-https)
- [Reviewed community container reference](https://github.com/runzhliu/deepseek-harness-docker)

The community project is implementation evidence, not an official DeepSeek
image and not this project's acceptance evidence.
