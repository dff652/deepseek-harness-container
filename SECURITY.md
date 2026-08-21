# Security policy

## Current status

This repository has a locally accepted AMD64 regression candidate and a
rebuilt QEMU ARM64 candidate, but no current native or production ARM acceptance,
container image publication or production deployment. It does not accept production
credentials. Security reports must not assume that either candidate Compose
is a deployable release.

## Trust boundaries

The DSH Agent can execute code and use credentials available to its service
identity. Caddy authentication controls who reaches the UI; it does not create
per-user filesystem, process, model, provider or credential isolation.

Use separate containers, volumes, workspaces and identities for users who do
not share one trust boundary.

## Prohibited defaults

Release and example configurations must not include:

- `privileged: true`;
- `network_mode: host`;
- `/var/run/docker.sock` or another container-engine control socket;
- host `/`, `/root`, the entire `/home`, Docker data or raw block devices;
- `SYS_ADMIN`, `NET_ADMIN` or unreviewed devices;
- port 3080 published to the host or LAN;
- plaintext passwords, API keys, private keys or real internal topology;
- a universal SSH key, cloud credential or Docker config;
- unauthenticated Docker/runner TCP access;
- floating image/package versions.

Controlling a Docker socket is treated as host-level authority because it can
create privileged containers and mount host filesystems.

## Secrets

- Images contain no deployment secret.
- `.env`, private CA keys, provider homes and secret files remain ignored and
  deployment-owned.
- A Caddy bcrypt hash is supplied at deployment time and must preserve literal
  `$` characters. Plaintext passwords are never committed.
- Model/provider credentials use dedicated files, Compose secrets or an
  external secret store with the narrowest service identity.
- Client CA trust is distributed through an administrator-controlled channel;
  clicking through a browser certificate warning is not accepted.

## Filesystem and process isolation

- Mount one approved workspace, not a parent collection of unrelated projects.
- Keep the fixed container identity `10001:10001`; prepare the one approved host
  workspace for that identity and verify adjacent host paths remain unchanged.
- Keep DSH_HOME, provider state, workspace and Caddy PKI in separate volumes.
- Run DSH as non-root, drop all capabilities and use `no-new-privileges`.
- Permit the network-disabled, one-shot Caddy initializer only `CHOWN`, only on
  the two Caddy volumes; the long-running Caddy process remains UID/GID 1000.
- Use a PID 1 helper and verify provider children exit on stop, failure and
  removal.

## Network isolation

- Caddy is the only LAN listener and publishes the exact approved IP on 443.
- DSH remains on shared-container loopback and has no published 3080.
- Before loopback header adaptation, Caddy validates the approved external
  `Host`, rejects cross-site Fetch Metadata and requires any `Origin` to match
  the external HTTPS authority. Basic Auth is not CSRF protection.
- Restrict egress to approved DNS/NTP, model, MCP, database and artifact
  endpoints using host/gateway policy; a Compose bridge alone is not an
  egress allowlist.
- `host.docker.internal:host-gateway` is an exception for one reviewed host
  service, not authorization to scan or administer the host.
- Remote runners require authentication, an argv/working-directory allowlist,
  time/resource/output limits, audit logs and revocable non-human identity.

## Supply chain

Each candidate records the exact upstream digests, lockfiles, allowed install
scripts, image IDs and offline-bundle SHA-256 that actually exist for that
build environment. SBOM, provenance, license and vulnerability results are
release gates; the current QEMU ARM64 and AMD64 candidates explicitly
record them as pending
and must not imply that they were generated. A QEMU build cannot replace
native ARM runtime tests.

Registry publication, signing and deployment require separate approval even
after the local gates pass.

## Reporting

Until a private reporting channel is configured, do not put vulnerability
details, credentials or private deployment topology in a public issue. Contact
the repository owner through the existing private project channel.
