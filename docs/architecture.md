# Architecture and product boundaries

## Purpose

This project will turn an exact DSH release family into an auditable Linux
ARM64 container appliance. It owns the container runtime closure and delivery
mechanics, while upstream DSH, plugin packages, MCP providers and deployment
secrets keep their own release boundaries.

The repository is currently an implementation candidate: its Dockerfile,
locked runtime closure, Compose/Caddy contract, build scripts and native ARM64
workflow exist and pass static checks. No statement below means that an image
build, production release or real ARM acceptance already exists.

## Ownership map

| Concern | Owner |
|---|---|
| DSH agent/runtime source | `deepseek-ai/deepseek-harness` upstream |
| Configuration-only plugin packages | sibling plugin repository |
| Provider behavior and data models | each provider project |
| Dockerfile, Compose, Caddy and image policy | this repository |
| IPs, workspaces, credentials, CA client trust | deployment owner |
| Docker Engine, kernel, cgroup and storage driver | target host owner |

This project consumes exact artifacts. It does not copy provider handlers,
credential stores or machine-specific paths into an image.

## Container topology

### Selected design

```text
host ARM_IP:443
      |
      v
Docker-published port on the DSH network namespace
      |
      +-- Caddy sidecar
      |     TLS, Basic Auth, local CA
      |     reverse_proxy 127.0.0.1:3080
      |
      `-- DSH container
            dsh web --host 127.0.0.1 --port 3080 --no-open
```

Caddy uses `network_mode: service:dsh`. Both processes therefore see the same
loopback, while the host publishes only port 443. At the external boundary,
Caddy's approved-IP site is an outer `Host` matcher; a separate HTTPS catch-all
returns 421 for every other Host. Within the approved route, Caddy rejects an
explicit `Sec-Fetch-Site: cross-site` and requires any supplied `Origin` to
equal the external HTTPS authority. Basic Auth identifies a caller but is not
a CSRF or DNS-rebinding defense.

Only after that request-trust gate passes may the loopback adapter set the
upstream `Host` authority and remove external `Origin`/Fetch-Metadata headers so
DSH can apply its loopback policy. Those rewrites must not be global shortcuts
around the external gate. A plugin route that needs original same-origin
headers requires a separate reviewed route and negative tests, rather than a
weaker catch-all proxy rule.

Because some literal-IP TLS clients omit SNI, the gateway sets Caddy's
`default_sni` to the same deployment IP. Without that setting, certificate
issuance can succeed while the TLS handshake still fails before HTTP routing.

The LAN IP does not need to be a DSH `--trusted-host` in this topology. That
flag is a Host/DNS-rebinding fence, not authentication, and must not be used to
justify publishing DSH directly.

### Is Caddy mandatory?

Not for the existing host/systemd installation: an SSH local-forward on that
host can reach its host-loopback DSH listener. Container loopback is different.
An SSH daemon on the host cannot directly reach `127.0.0.1:3080` inside the
DSH container's network namespace, and ordinary port publishing cannot make a
process bound only to container loopback accept traffic on the container's
Ethernet interface.

The container appliance therefore requires a same-namespace relay. Caddy is
the selected relay because the production requirement is durable access from
multiple managed LAN devices without a domain, with TLS and authentication.
An alternate single-operator profile could replace Caddy with a minimal,
reviewed same-namespace relay published only on host loopback and then use SSH
forwarding, but that is still a proxy component, not direct DSH IP access.
Direct raw-IP HTTP would weaken the entry controls or require patching DSH's
loopback policy and is not accepted.

### Rejected defaults

- DSH patched to `0.0.0.0` solely to cross a normal Compose bridge;
- `ports: 3080:3080` or LAN HTTP access;
- `network_mode: host`;
- one wide-privilege container containing DSH, Caddy, Docker daemon and build
  credentials;
- a remote Caddy gateway without an exact, source-restricted backend listener;
- public ingress before application authentication and tenant isolation exist.

### Lifecycle coupling

The sidecar and DSH container share a network namespace and form one appliance.
Upgrade and rollback recreate them together. Tests must cover DSH restart,
Caddy restart and full Compose recreation rather than assume the old namespace
attachment stays correct.

Binding `${DSH_LAN_IP}:443` is also a cold-start dependency. The static address
must exist before Compose creates the service. A host startup unit must wait for
`network-online.target`, verify the exact address and use bounded retries;
`restart: unless-stopped` alone does not recover a container that was never
created because the bind address was absent.

## Image design

### Build targets

One multi-stage Dockerfile should produce:

- `runtime`: exact DSH closure copied into a pinned shell-less Distroless Node
  runtime, with Compose `init: true` supplying the PID 1 helper;
- `dev-runtime`: the same base plus pinned Git, ripgrep, compilers and project
  test tools for an Agent that develops code.

The builder may contain Python, `make` and `g++` for native dependencies. The
production runtime copies only the reviewed closure and contains no shell or
package manager. The development target is a separate capability boundary and
retains the controlled toolchain. Both targets run as a fixed non-root UID/GID,
use a read-only root filesystem and write only to declared volumes and tmpfs.

### State

| Path | Backing | Purpose |
|---|---|---|
| `/var/lib/dsh` | named volume | DSH configuration, credentials and sessions |
| `/workspace` | one explicit bind mount | deployment-approved project tree |
| `/tmp` | size-limited tmpfs | transient runtime data |
| `/opt/providers` | image or read-only mount | exact provider executables |
| Caddy `/data` | separate named volume | local CA and certificates |

DSH state, provider state and workspace data are not merged into one broad host
mount. Empty named-volume ownership and host UID/GID matching must be tested on
the real target.

## Build and platform evidence

### Native ARM64

Native ARM64 glibc is the preferred production builder because install scripts,
`node-pty`, Landlock/bwrap behavior and runtime smoke execute on the target
architecture.

### x86 Buildx/QEMU

Buildx/QEMU can create a `linux/arm64` candidate and is useful for CI. It does
not prove native module execution, sandbox strength, browser behavior or cold
boot on the production kernel. Every QEMU-built candidate is blocked until the
real ARM gate passes.

### Base and dependency locks

A release replaces every placeholder with an exact manifest digest and records:

- Node build image plus Distroless runtime index/platform digests;
- DSH/npm integrity and complete pnpm lock;
- allowlisted dependency build scripts;
- Caddy image digest;
- plugin/provider artifact digests;
- produced image ID, SBOM, provenance and signature.

No release command resolves `latest`, a branch or registry metadata on the
disconnected target.

## Compose contract

The shipped candidate Compose expresses these core invariants:

```yaml
services:
  dsh:
    image: ${DSH_IMAGE:?set exact offline image}
    pull_policy: never
    command: [web, --host, 127.0.0.1, --port, '3080', --no-open]
    ports:
      - ${DSH_LAN_IP:?set DSH_LAN_IP}:443:443
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]

  caddy:
    image: caddy:2.11.4@sha256:<locked OCI index digest>
    pull_policy: never
    network_mode: service:dsh
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
```

This is a shortened excerpt of `compose.yaml`; the actual file includes exact
volumes, a readiness check, Caddy configuration and the locked Caddy identity.
`tests/compose-contract.sh` and `tests/negative-exposure.sh` parse and enforce
the complete candidate. Resource limits remain deployment-owned until the real
ARM host capacity is known and tested.

## Health and acceptance semantics

- DSH root HTTP 2xx proves only Web transport readiness. Do not assume an
  undocumented `/health` route.
- Caddy 401 proves the front door rejected an unauthenticated request, not that
  an authenticated browser works.
- Valid Basic Auth with a malicious `Origin`, cross-site Fetch Metadata or an
  unapproved `Host` must still fail at the gateway before any header rewrite.
- A healthy container does not prove models, settings, provider processes,
  sandboxing, workspace permissions or unattended cold boot.
- Final acceptance requires an authorized browser, a real model request, a
  visible MCP tool call, provider reconnect, zero writes outside the workspace
  and a real ARM power-cycle test.

## Project phases

1. **Docs scaffold:** completed; decisions and gates recorded.
2. **Local candidates:** current state; the native AMD64 regression image and
   Compose override passed disconnected runtime/native-module smoke plus local
   CA/gateway acceptance. The rebuilt QEMU ARM64 image passed disconnected
   native-module/Web smoke and the same local CA/gateway checks; no registry
   publication yet.
3. **Native ARM candidate:** GitHub native build/runtime and downloaded-bundle
   verification completed; production target and rollback acceptance remain.
4. **Public candidate distribution:** architecture-specific Docker Hub tags
   and a verified AMD64/ARM64 manifest, always marked candidate-only.
5. **Formal multi-architecture release:** sign and publish formal tags only
   after the production ARM and supply-chain gates pass. AMD64 support never
   weakens the ARM production gate.
