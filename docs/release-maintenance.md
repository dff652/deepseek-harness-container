# Dual-architecture image maintenance and publication

## Supported image tracks

The project maintains one application runtime for two Linux/glibc platforms:

| Track | Build evidence | Required runtime smoke | Production meaning |
| --- | --- | --- | --- |
| `linux/amd64` | local native x86_64 and GitHub `ubuntu-24.04` | version, Web readiness, UID 10001, no port 3080, Koffi, node-pty, Landlock and Sharp with networking disabled | development/regression candidate |
| `linux/arm64` | local Buildx/QEMU plus native GitHub `ubuntu-24.04-arm` | the same runtime boundary on ARM64 | candidate until the disconnected target host passes full acceptance |

Both tracks use the same Dockerfile, pnpm lock/build policy, DSH entrypoint and
security defaults. Architecture-specific files may select immutable Node and
Caddy child manifests, Compose platform values and evidence locks; they must
not fork application logic or loosen the security boundary.

## Version update order

For every DSH/Node/pnpm/Caddy update:

1. Verify the upstream DSH tag, commit, npm integrity and source-vs-package
   boundary.
2. Regenerate and review the complete pnpm lock and allowed-build policy.
3. Resolve exact Linux AMD64 and ARM64 child manifests for Node and Caddy.
4. Update Dockerfile defaults, architecture build scripts, Compose overlays,
   workflow matrices, policy records and documentation together.
5. Build and smoke the native AMD64 candidate first for fast regression.
6. Build the QEMU ARM64 candidate, then run the native GitHub ARM64 job.
7. Generate environment-specific image IDs, manifest/config digests, archive
   SHA-256 and inspection/build metadata. Never copy one environment's output
   lock into another.
8. Run static contracts, disconnected Compose, Caddy trust/negative tests and
   secret/license/vulnerability gates.
9. Publish candidate tags only after both native architecture jobs pass.
10. Promote to a formal version only after real disconnected ARM browser,
    model/MCP, workspace, restart and cold-boot acceptance plus the complete
    SBOM/provenance/signing gates.

Any shared Dockerfile, entrypoint, lockfile, security-policy or gateway change
supersedes older architecture candidates unless both images are rebuilt and
retested from the new source commit.

## Docker Hub tag contract

Candidate publication uses repository `dff652/deepseek-harness-container`:

```text
<dsh-version>-amd64-candidate
<dsh-version>-arm64-candidate
<dsh-version>-candidate
```

The architecture tags are immutable build inputs for the candidate manifest.
The unsuffixed `-candidate` tag must resolve to an OCI index containing exactly
`linux/amd64` and `linux/arm64`. It is allowed to move only when both
architecture candidates for the same DSH version have been rebuilt from the
same reviewed Git commit.

Do not publish `latest`, silently replace an architecture-specific tag, or
create a dual-architecture manifest from different source commits. Formal
version tags and any moving stable channel require a separate release approval.

## GitHub Actions publication

`.github/workflows/publish-dockerhub-candidate.yml` is manual-only and accepts
the exact confirmation value `publish-candidate`. Configure these GitHub
Actions secrets after the public repository exists:

- `DOCKERHUB_USERNAME`: Docker Hub namespace owner;
- `DOCKERHUB_TOKEN`: a scoped access token that can push only this repository.

The workflow builds on native AMD64 and ARM64 runners, runs the corresponding
network-disabled runtime smoke, pushes the two architecture candidate tags and
then creates and verifies the dual-architecture manifest. A failed architecture
job prevents manifest publication.

Repository creation, GitHub push, Docker Hub publication, formal release,
signing and production deployment remain independent auditable transitions.

## Rollback and retention

Retain the per-architecture image archives, image locks, inspect/build
metadata, Compose/Caddy inputs and `SHA256SUMS` for every accepted candidate.
Rollback selects a previously recorded digest; it does not rebuild an old tag
from a changed branch. Before changing a candidate manifest, record its current
index digest and both child digests so the previous state remains recoverable.
