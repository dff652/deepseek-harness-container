# DeepSeek Harness Container collaboration rules

This repository owns the reproducible container and offline delivery layer for
DeepSeek Harness. It does not own upstream DSH source, provider business logic,
or the plugin packages maintained in sibling repositories.

## Ownership boundaries

- Build DSH from exact published npm artifacts and a committed lockfile.
- Consume plugin/provider artifacts by exact version and digest; do not copy
  their handlers or data models into this repository.
- Keep machine IPs, workspace paths, credentials, private CA keys and provider
  homes deployment-owned. Examples use documentation-only addresses.
- Treat the systemd deployment and this container deployment as separate
  products and acceptance records.

## Security defaults

- DSH listens only on container loopback. Caddy is the only LAN entry and
  shares the DSH network namespace.
- Never publish DSH port 3080, use host networking, run privileged, mount the
  Docker socket, mount the host root/home, or grant `SYS_ADMIN`/`NET_ADMIN`.
- Run DSH as a fixed non-root UID/GID with a read-only root filesystem. Mount
  only an approved workspace plus separate persistent application volumes.
- Do not bake passwords, API keys, SSH keys, client CA trust or private
  topology into images, Compose files, tests or documentation.
- Remote build or host operations require a separate authenticated,
  allowlisted and audited runner. Accept argv, not shell command strings.

## Version and release policy

- Pin the full DSH/Node/pnpm/Caddy/base-image/provider tuple. Never use
  `latest`, floating branches or unresolved digest placeholders in a release.
- Record image IDs, upstream digests, SBOM, provenance and SHA-256 for every
  offline bundle.
- An x86/QEMU build is a candidate only. Production acceptance requires a real
  ARM64 host, disconnected startup, browser/model/tool calls and cold boot.
- Commit, push, registry publication, signing, release and deployment are
  separate owner-authorized transitions.

## Verification

- Parse the final Compose and Caddy configurations from the shipped files.
- Assert negative boundaries: no 3080 publication, Docker socket, privileged,
  host network, broad host mount or dangerous capability.
- Verify `--no-build --pull never` startup with registry access unavailable.
- Test exact workspace writes and adjacent-directory zero-write, provider
  failure/reconnect/cleanup, Caddy 401/authorized 200, certificate trust and
  real DSH model/MCP calls.
- Preserve edits made by other agents. Workers own only explicitly assigned
  files and must not revert or rewrite unrelated work.
