# Unpushed container and ARM64 maintenance review — 2026-09-03

## Scope and decision

The implementation review covers the complete local range
`e3437c8aa3aa60afaeafa38877c25e5b508181b6..21b35ae39c685da4ffeee7fb428be68ed2b9c326`,
not only the latest change:

| Commit | Scope |
| --- | --- |
| `df210df94c2812a7bf356e62ca39d2a88e85500e` | rc.2 gateway regression and live runtime-CVE evidence hardening |
| `8fdf5ade33c34527c0b6d6aada293b638ec4a334` | release-input ledger, read-only maintenance discovery and native ARM64 candidate pipeline |
| `21b35ae39c685da4ffeee7fb428be68ed2b9c326` | strict release-version/integrity validation and direct DSH lockfile coherence |

This record and its README index were added in `973d9f2`; any later doc-only
correction is also part of the final `origin/main...HEAD` review. Post-commit
checks inspect the current HEAD and worktree rather than treating `8fdf5ad` as
the branch tip.

The source changes have no known code-level blocker for an owner-authorized
push. A direct push to `main` does not start the current workflows: remote CI
requires a pull request before merge or a separate `workflow_dispatch` after
the source exists remotely. This is not approval to publish an image, sign a
release or deploy the appliance. The candidate publication and real ARM64
acceptance gates below remain open.

## Review findings

An independent negative review found that the initial ledger validator accepted
floating aliases and malformed integrity strings, and did not directly compare
the DSH package entry in `runtime/pnpm-lock.yaml` with the ledger. Commit
`21b35ae` closes those gaps and adds regression cases. No unresolved correctness
or security defect was found after that repair. Review specifically checked the
following boundaries:

- the release ledger rejects floating/prerelease references and detects exact
  tag/digest drift in Dockerfiles, workflows and committed locks, including
  same-digest tag substitution;
- scheduled maintenance has read-only repository permission and reports
  upstream signals without rewriting files or publishing images;
- build-only workflows do not receive registry credentials and publication is
  isolated behind a manual confirmation and dependent policy jobs;
- the native ARM64 entrypoint accepts either a clean Git worktree or the exact
  commit and checksum supplied by the forced runner, uses a digest-pinned
  BuildKit image, applies hard step/network timeouts and creates checksummed
  archives, SBOMs, vulnerability reports and provenance metadata;
- DSH remains non-root, loopback-only and unexposed on port 3080. The isolated
  HAProxy profile does not silently replace the default Caddy appliance.

The checked-in tests cover negative exposure, exact release inputs, lock drift,
runtime-CVE report integrity, gateway behavior and the non-publishing native
ARM64 contract. They do not substitute for a real native build or browser,
provider, workspace, restart and cold-boot acceptance.

## Verification evidence

The main-agent review ran the ledger checker, Compose/security contracts,
native and AMD64 workflow contracts, Docker Hub publication contract, rc.2 lock
contract, runtime-CVE fixtures, release-input and native ARM64 contracts,
HAProxy contract, ten supply-chain policy tests, Bash syntax, ShellCheck,
Python compilation and workflow YAML parsing. All completed successfully and
`git diff --check` was clean. The release-input contract also proved that
floating Node/pnpm/image aliases, non-version tool values, malformed npm and
Corepack SHA512 values, and runtime lock-integrity drift are rejected.

The independent verifier reran the local AMD64 runtime suite, rc.2 regression
contracts, runtime-CVE collection and HAProxy contract successfully. No native
ARM64 build or GitHub Actions run was produced for the current branch. The
branch has not been pushed, so the new workflow revisions have no remote-CI run
attached to this commit range.

## Open gates and rollback

Publication remains blocked because the reviewed rc.2 DSH/Caddy images contain
unresolved High/Critical scan records and the exception list is empty. Existing
native GitHub run IDs predate the current workflow changes. The company-side
ARM64 host also has not produced a candidate for the current branch. Its earlier
attempt against `8fdf5ad…` reached the fixed BuildKit pull, which timed out after
180 seconds; no approved builder/image was created, and the pinned Syft/Grype
tools are not installed there.

The next accepted sequence is:

1. push the reviewed source only after separate owner authorization, then use
   a pull request before merge or separately dispatch the read-only/build-only
   workflows to produce evidence;
2. deliver the pinned BuildKit, Syft and Grype inputs to the ARM64 host through
   an approved proxy, internal registry or checksummed offline transfer;
3. pass forced-runner preflight, build the exact reviewed commit and export the
   complete evidence archive;
4. remediate or explicitly review every blocked vulnerability, then perform
   disconnected real-ARM acceptance;
5. authorize publication, signing and deployment as separate transitions.

If a source push must be undone, revert the relevant commit and rerun the same
checks. Do not rewrite or reuse immutable candidate tags. No registry artifact
or production deployment was created by this review, so there is no runtime
rollback action at this stage.

## Delegation boundary

Splitting the public container review from the private host/runner review is
appropriate because the repositories have different ownership and secret
boundaries. Workers may inspect and test their assigned range, but the primary
agent owns cross-repository conclusions, shared documentation, exact staging,
final verification and commits. Remote host changes, pushes, publication and
deployment remain owner-authorized operations and are not delegated by default.
