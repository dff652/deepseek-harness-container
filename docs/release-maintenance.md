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

## Release input ledger and maintenance check

[`policy/release-inputs.json`](../policy/release-inputs.json) is the single
machine-readable review source for the DSH/Node/pnpm tuple, the Dockerfile
frontend, the per-platform Node/Caddy/HAProxy child digests, BuildKit and the
Syft/Grype/Gitleaks identities. Existing Dockerfiles, Compose files, scripts,
workflows and evidence locks remain readable by humans; they are checked
against this ledger so a partial version update fails closed.

Run the read-only check before opening or approving a maintenance change:

```sh
python3 scripts/check-release-inputs.py
```

For a proposed ledger, use
`python3 scripts/update-release-inputs.py path/to/proposal.json`. Without
`--apply` it only validates the proposal. Applying a proposal is an explicit
maintainer action and still requires updating every reported consumer followed
by the normal checker. The helper has no npm/registry lookup, never accepts
alpha/beta or floating image references, and refuses vulnerability exception
data. The scheduled
`.github/workflows/release-inputs-maintenance.yml` workflow only runs these
read-only checks plus a weekly upstream signal capture: it retains the current
DSH npm dist-tags and proves that every reviewed immutable image reference is
still resolvable. It cannot rewrite the repository or publish an image. This is
a discovery/drift alarm, not an automatic upgrade bot: selecting a version,
updating child digests and preparing a proposal remain explicit owner review.

## Version update order

For every DSH/Node/pnpm/Caddy update:

1. Update and review `policy/release-inputs.json` with the upstream DSH tag,
   commit, npm integrity and source-vs-package
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
(for example `0.1.1-rc.2-r1`) while `DSH_VERSION` continues to record the
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

### Current publication hold (2026-08-24)

The current source pins DSH `0.1.1-rc.2`. Local native AMD64 and x86/QEMU
ARM64 builds passed runtime, native-module, bundle-hash and the Caddy/HAProxy
gateway contracts. The exact local DSH manifests are `sha256:3cea6dff…`
(AMD64) and `sha256:0c1fe2ec…` (ARM64). Native GitHub rc.2 runs
[32699950087](https://github.com/dff652/deepseek-harness-container/actions/runs/32699950087)
and [32699954057](https://github.com/dff652/deepseek-harness-container/actions/runs/32699954057)
also passed on source `f69966b…`; their downloaded locks, archives, platforms,
manifest/config digests and environment-to-RepoTag mappings were independently
verified. Their SBOM/provenance fields remain null, so these runs do not bypass
the publication policy.

A same-tool/database scan of both exact rc.2 architectures found four blocked
DSH records and 35 blocked Caddy records per architecture. The comparable
default appliance therefore has 39 High/Critical records on each architecture.
The isolated HAProxy children each have two blocked records, so DSH plus
HAProxy has six per architecture. The allowlist remains empty. These counts
are temporary local evidence rather than retained release attestations and do
not authorize an exception or gateway switch.

Each architecture workflow now also runs the live runtime reachability
collector on the image it just built and retains the exact-digest JSON in its
candidate evidence. Non-publishing workflows accept either a zero-blocker or a
blocked report as evidence, but reject collection/schema failures. The Docker
Hub workflow runs the same command in `gate` mode after generating scanner
reports and before policy approval; any `evidence` or `unknown` status stops
the job. Fixture-only tests cannot satisfy this gate.

The local AMD64 test appliance now runs rc.2 on isolated HTTPS port 8443. It is
not a production deployment and did not replace or stop the host systemd DSH.
Seven network-disabled package-level rc.2 contracts now cover permission
configuration/reducers, image persistence/bounds, Files upload/fallback,
single stale-ID retry, index reuse, bounded cleanup and credential isolation.
Browser permission semantics, provider-backed vision/Files, rollback and
resource-pressure behavior still require formal regression acceptance. See
[the rc.2 readiness record](rc2-release-readiness.md) for the exact evidence
and open gates.

Historical native rc.1 AMD64 run
[32664544119](https://github.com/dff652/deepseek-harness-container/actions/runs/32664544119)
and ARM64 run
[32664545874](https://github.com/dff652/deepseek-harness-container/actions/runs/32664545874)
remain useful build-system evidence for source `8b9ce04…`, but neither can be
promoted as rc.2 evidence. Their SBOM/provenance fields are null.

GitHub Actions Docker Hub secrets remain absent. Repository push, Docker Hub
publication, formal release, signing and production deployment remain separate
owner-authorized, auditable transitions.

## Rollback and retention

Retain the per-architecture image archives, image locks, inspect/build
metadata, Compose/Caddy inputs and `SHA256SUMS` for every accepted candidate.
Rollback selects a previously recorded digest; it does not rebuild an old tag
from a changed branch. Before changing a candidate manifest, record its current
index digest and both child digests so the previous state remains recoverable.
