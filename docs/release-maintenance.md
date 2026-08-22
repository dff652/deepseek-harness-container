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
   secret/license/vulnerability gates. Generate SBOMs from both the actual DSH
   image and the exact Caddy child image; scanning only the lockfile is not an
   appliance gate.
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
`linux/amd64` and `linux/arm64`. The workflow refuses to replace any of the
three tags. A rebuilt candidate therefore needs a new `CANDIDATE_VERSION`
(for example `0.1.1-rc.1-r1`) while `DSH_VERSION` continues to record the
actual upstream package version.

Do not publish `latest`, silently replace an architecture-specific tag, or
create a dual-architecture manifest from different source commits. Formal
version tags and any moving stable channel require a separate release approval.

Before adding registry credentials, enable
[Docker Hub's repository-side tag immutability](https://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/)
for candidate tags. One suitable Go/RE2 expression is:

```text
^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?-(amd64-candidate|arm64-candidate|candidate)$
```

The workflow's pre-push existence check improves diagnostics but cannot remove
a registry race; server-side immutability is the enforcement boundary. Record
the Docker Hub setting in the publication evidence before the first push.

Registry pushes are not transactional. If one architecture tag is pushed and
a later push or manifest creation fails, retain the publication evidence and do
not overwrite the surviving immutable tag. Investigate the failure, increment
`CANDIDATE_VERSION` with a repository-owned rebuild suffix, rebuild both
architectures from one commit and publish a new three-tag set. Deleting the
partial remote tag is a separate destructive registry operation and is not the
default retry path.

## GitHub Actions publication

`.github/workflows/publish-dockerhub-candidate.yml` is manual-only and accepts
the exact confirmation value `publish-candidate`. Configure these GitHub
Actions secrets after the public repository exists:

- `DOCKERHUB_USERNAME`: Docker Hub namespace owner;
- `DOCKERHUB_TOKEN`: a scoped access token that can push only this repository.

The workflow has three trust stages:

1. A no-registry-secret preflight scans complete Git history with pinned
   Gitleaks and runs repository/policy tests.
2. Native AMD64 and ARM64 jobs build and run the network-disabled smoke, pull
   the exact Caddy child, generate Syft plus CycloneDX SBOMs for both images,
   scan the Syft documents with Grype, and enforce source/digest/license/
   vulnerability policies. Matrix fail-fast is disabled so one architecture's
   policy failure does not cancel collection of the other architecture's
   evidence. Evidence uploads even when policy fails; image archives upload
   only after it passes.
3. Only the dependent publication job receives Docker Hub credentials. It
   loads the two approved archives, refuses existing tags, pushes architecture
   tags, verifies source labels/platforms, and creates the final index from
   resolved child digests.

The published tags contain only the DSH runtime image. Caddy stays in the
Docker Official Image repository at its exact per-platform digest. It is
included in appliance SBOM/vulnerability checks, while disconnected delivery
uses the build scripts' separate Caddy archive. Do not describe the Docker Hub
DSH manifest by itself as a complete offline appliance bundle.

`policy/vulnerability-allowlist.json` starts empty. Every exception must match
an exact vulnerability ID, PURL, package and version and include owner,
tracking, reason, applicable architecture(s) and an unexpired date; wildcard,
expired, duplicate and unused entries fail for the selected architecture.
`policy/license-policy.json` applies the same expiring-review
model to known scanner gaps and allowlists the reviewed SPDX expressions for
the DSH runtime dependency path. Caddy's full inventory is retained even where
Go binary SBOM extraction cannot recover every dependency license; this is a
known evidence limitation, not permission to ignore detected forbidden terms.
The checker hard-requires High and Critical blocking and validates the report's
filter/ignore configuration plus the checksum-bearing Grype database source;
changing the JSON severity list cannot weaken that invariant.

### Current publication hold (2026-08-22)

The hardened local AMD64 runtime passed the disconnected DSH/native-module
smoke and its final filesystem no longer exposes npm, npx, Corepack, pnpm or
Yarn. Against Grype DB built
2026-08-21, the strict empty-exception policy still found 24 unapproved
High/Critical matches in the pinned Node/Debian image and 35 in the pinned
Caddy image. Caddy's Go-symbol fallback can over-report module reachability,
but no finding is waived automatically. These are 59 match records covering 50
unique advisory IDs, not 59 confirmed exploitable vulnerabilities. Sixteen
Caddy matches had a scanner-provided fixed version; none of the DSH/Bookworm
matches did. The evidence is AMD64-only and cannot be copied into an ARM64
review. Follow the [vulnerability triage runbook](vulnerability-triage.md) to
update the bases or, only after reachability/risk review, add exact owned and
expiring exceptions. GitHub Docker Hub secrets were also absent when this hold
was recorded.

Repository creation, GitHub push, Docker Hub publication, formal release,
signing and production deployment remain independent auditable transitions.

## Rollback and retention

Retain the per-architecture image archives, image locks, inspect/build
metadata, Compose/Caddy inputs and `SHA256SUMS` for every accepted candidate.
Rollback selects a previously recorded digest; it does not rebuild an old tag
from a changed branch. Before changing a candidate manifest, record its current
index digest and both child digests so the previous state remains recoverable.
