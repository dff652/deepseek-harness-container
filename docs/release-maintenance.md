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

## GitHub Actions build evidence

The build-only workflows are independent of registry publication:

- `.github/workflows/build-amd64.yml` uses native `ubuntu-24.04`;
- `.github/workflows/build-arm64.yml` uses native `ubuntu-24.04-arm`.

Both run on pull requests without secrets and support an owner-triggered manual
candidate bundle. They build and smoke only their architecture, use
`contents: read`, upload temporary evidence only for `workflow_dispatch`, and
never log in, push, sign, create a registry manifest or release. A successful
build-only run does not satisfy vulnerability, SBOM, provenance, production ARM
or publication gates.

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

The latest non-publishing source-specific pair is native AMD64 run
[32664544119](https://github.com/dff652/deepseek-harness-container/actions/runs/32664544119)
and native ARM64 run
[32664545874](https://github.com/dff652/deepseek-harness-container/actions/runs/32664545874)
for commit `8b9ce04…`. Both passed runtime, HAProxy/Caddy classic-store
clean-load and bundle-hash gates; downloaded locks and artifacts were
independently verified. Their SBOM/provenance fields remain null, so they do
not satisfy or bypass the publication policy.

Distroless runtime-source native ARM64 run
[32557974575](https://github.com/dff652/deepseek-harness-container/actions/runs/32557974575)
passed build, runtime, native-module and bundle-hash gates for source commit
`feb4469…`. Its downloaded lock and every listed bundle checksum were independently
verified; SBOM/provenance remain null, so the run does not satisfy or bypass
the publication policy.

Native AMD64 run
[32559547026](https://github.com/dff652/deepseek-harness-container/actions/runs/32559547026)
passed the same non-publishing build/runtime/bundle boundary for source commit
`6bed724…`. Its downloaded checksums, OCI manifest/config, DSH/Caddy archive
hashes, architecture and candidate lock were independently verified. It also
retains null SBOM/provenance and does not reduce the vulnerability hold.

Against Grype DB built 2026-08-21, the historical strict empty-exception scan
found 24 unapproved High/Critical DSH/Bookworm matches and 35 Caddy matches.
The 2026-08-22 committed Distroless remediation reduced DSH to four matches on
both AMD64-native and ARM64-QEMU images, while the Caddy AMD64 snapshot remains
35. The current comparable AMD64 appliance total is therefore 39 match records
covering 34 unique advisory IDs. Sixteen Caddy matches have a scanner-provided
fixed version; none of the four Distroless runtime matches do. No finding is
waived automatically, ARM64 Caddy evidence must still be generated natively,
and the GitHub Docker Hub secrets remain absent. Follow the
[vulnerability triage runbook](vulnerability-triage.md) before any exact owned
and expiring exception is considered.

The isolated HAProxy `3.4.3-alpine3.24` comparison is not part of this Docker
Hub workflow. Its exact AMD64 and ARM64 children pass local functional tests
and each scan at two High records, so the comparable DSH+HAProxy count is six
records per architecture. It still fails the same empty-exception policy and
lacks native retained supply-chain plus real production-ARM evidence. Adopting
it would require an explicit gateway decision followed by architecture-specific
offline archives, SBOM/provenance/license integration and publication-workflow
changes; local PoC success must not silently alter the Caddy release track.

Repository creation, GitHub push, Docker Hub publication, formal release,
signing and production deployment remain independent auditable transitions.

## Rollback and retention

Retain the per-architecture image archives, image locks, inspect/build
metadata, Compose/Caddy inputs and `SHA256SUMS` for every accepted candidate.
Rollback selects a previously recorded digest; it does not rebuild an old tag
from a changed branch. Before changing a candidate manifest, record its current
index digest and both child digests so the previous state remains recoverable.
