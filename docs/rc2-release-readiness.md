# DSH 0.1.1-rc.2 release-readiness record

## Decision

`0.1.1-rc.2` is accepted as a **local candidate**, not as a published image or
production ARM release. The default appliance remains DSH plus Caddy. HAProxy
remains an isolated alternative profile: its smaller current vulnerability
count is useful evidence, but does not by itself satisfy the gateway adoption,
license, provenance, real-ARM or publication gates.

No image was pushed, no Docker Hub repository or tag was created, no signing
key was used, and no production deployment was changed during this update.

## Upstream identity and dependency closure

The candidate independently pins both upstream identities:

| Item | Accepted value |
| --- | --- |
| DSH package | `@deepseek-ai/dsh@0.1.1-rc.2` |
| source tag | `dsh-v0.1.1-rc.2` |
| tag commit | `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e` |
| npm integrity | `sha512-UP1UIh6q3Gme/yXRn/QL2P8IsVlv8Shpg22TRJIZPsCRWLm4CBiA1MUvXmJAfsOEETBMLAl+xWPtFw6ICsN3wg==` |
| npm shasum | `1a5112369f1c46b13a6e6f21de8af5e6afd45074` |
| Node / pnpm | `24.19.0` / `11.7.0` |

The tag is lightweight and the referenced commit is unsigned. The npm package
metadata has no `gitHead`, so the source tag/commit and npm tarball integrity
are separate pins; this project does not claim a cryptographic binding between
them. The top-level rc.1 and rc.2 npm payloads differ only in package metadata;
the behavioral update is carried by the transitive DSH package set.

The regenerated lock contains 188 rc.2 `@deepseek-ai/dsh*` package entries,
zero rc.1 DSH entries and an exactly matching 188-entry
`minimumReleaseAgeExclude` set. `tests/rc2-lock-contract.sh` enforces that
closure, the root integrity and the current QEMU evidence lock.

## Local build and runtime evidence

| Platform | Build | DSH manifest | Config | Result |
| --- | --- | --- | --- | --- |
| `linux/amd64` | local native Buildx | `sha256:3cea6dff93407b8329c292cf35d4f9293ce3ded3bc330d581b11068c30277e99` | `sha256:783f744faa8d892487a15cb215cfd27f52ad0401b408693a7e6e446e23c6d97e` | PASS |
| `linux/arm64` | local x86 Buildx/QEMU | `sha256:0c1fe2ecb65625c0572751fe6c891b7e802220c0bbf7587938785717053a12a4` | `sha256:c35117619e33e0de091d537391348d732d2037e832b94e2c42f517e9671100a6` | candidate PASS |

The local bundle directories are `artifacts/candidate-amd64.8otTIG/` and
`artifacts/candidate-arm64.F6XyUd/`; they are ignored local evidence, not
committed or released artifacts. Every listed bundle member passed its
`SHA256SUMS`. Both images passed network-disabled loads of Sharp, Koffi,
node-pty and Landlock, DSH version/Web readiness, UID `10001`, read-only root,
no shell/package manager and writable request-image state under `DSH_HOME`.

Both Caddy and isolated HAProxy gateway profiles passed native AMD64 and QEMU
ARM64 runtime/Compose contracts, including trusted IP-SAN TLS, Basic Auth,
401/200/421/403, WebSocket, SSE, header filtering and no published container
port 3080. QEMU results do not replace native ARM or production-host evidence.

An isolated local AMD64 appliance was upgraded from rc.1 to rc.2 on HTTPS port
8443. It is a test deployment only. Its DSH container is healthy, non-root and
read-only; the container publishes no 3080 port, and the separately managed
host systemd DSH listeners on 3080 remained unchanged.

## Same-snapshot vulnerability evidence

Syft `1.51.0` and Grype `0.117.0` with database build
`2026-08-21T06:17:24Z` scanned the exact local image children. This raw scan
workspace is temporary and is **not** formal retained release evidence.

| Appliance component | AMD64 Critical / High | ARM64 Critical / High | Gate |
| --- | ---: | ---: | --- |
| DSH Distroless runtime | 1 / 3 | 1 / 3 | blocked |
| Caddy 2.11.4 | 8 / 27 | 8 / 27 | blocked |
| DSH + Caddy total | 9 / 30 | 9 / 30 | blocked |
| HAProxy 3.4.3-alpine3.24 | 0 / 2 | 0 / 2 | blocked |
| DSH + HAProxy total | 1 / 5 | 1 / 5 | blocked |

The committed vulnerability exception list remains empty. Findings may be
remediated by an accepted upstream/base update or reviewed one by one with an
exact package/version/architecture scope, accountable owner, tracking record,
reason and expiry. Count reduction is not an exception or publication approval.

## Non-mechanical rc.2 behavior requiring acceptance

The rc.2 update changes more than version metadata. Formal feature regression
must cover:

1. Permission defaults: a changed General default applies to a genuinely new
   session, while a confirmed reusable blank session retains its preset.
   Started and explicitly selected sessions remain pinned; Full Access still
   requires acknowledgement, and `/permission` plus the active marker persist.
2. Image handling: browser upload, EXIF and 16-bit normalization, metadata
   removal, oversize and image-count policy, original-dimension/scale behavior,
   text-only placeholders and a successful vision request.
3. Files API and persistence: upload/reuse across restart, inline fallback for
   gateways without `/files`, a single stale-ID retry, bounded oldest-`dsh-*`
   cleanup on quota failure, no API key in index/logs, writable new DSH_HOME
   paths and rollback loading of rc.2-written state.
4. Security and streaming: exact 401/200/421/403/Fetch Metadata behavior,
   WebSocket/SSE and no container 3080 publication.
5. Resource/platform behavior: concurrent large-image transforms under the
   configured memory/CPU limits and native module loads on real AMD64 and ARM64.

Local smoke and gateway tests close item 4 for the local candidates and cover
the native-module portion of item 5. They do not close model/provider-backed
image/Files flows, permission UI semantics, rollback, load pressure or real ARM.

## Remaining release gates

Publication stays fail-closed until all of the following are true:

- native GitHub AMD64 and ARM64 rc.2 builds complete from one reviewed commit;
- a disconnected real ARM64 host passes import, cold start, browser login,
  model/MCP, workspace, image/Files, restart and rollback acceptance;
- exact DSH and selected-gateway SBOM, scan, license and provenance evidence is
  retained, checksummed and accepted for both architectures;
- all High/Critical findings are remediated or have exact approved, owned and
  unexpired exceptions;
- the selected gateway decision is explicit; HAProxy remains isolated until
  its supply-chain and real-ARM gates match the default profile;
- Docker Hub repository policy/immutability and scoped credentials are
  configured, then candidate publication is separately authorized;
- signing, formal release, production deployment and any retirement of the
  host systemd installation are separately authorized and recorded.
