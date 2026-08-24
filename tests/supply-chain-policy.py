#!/usr/bin/env python3
"""Adversarial tests for the candidate supply-chain policy checker."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts/check-supply-chain-policy.py"
SOURCE_REVISION = "a" * 40
NODE_DIGEST = "sha256:" + "b" * 64
NODE_RUNTIME_DIGEST = "sha256:" + "f" * 64
CADDY_DIGEST = "sha256:" + "c" * 64
DSH_MANIFEST = "sha256:" + "d" * 64


def base_documents() -> dict[str, object]:
    dsh_source = {
        "imageID": "sha256:dsh-image",
        "repoDigests": [f"local/dsh@{DSH_MANIFEST}"],
        "architecture": "amd64",
        "os": "linux",
        "labels": {
            "org.opencontainers.image.version": "0.1.1-rc.2",
            "org.opencontainers.image.revision": SOURCE_REVISION,
        },
    }
    caddy_source = {
        "imageID": "sha256:caddy-image",
        "repoDigests": [f"caddy@{CADDY_DIGEST}"],
        "architecture": "amd64",
        "os": "linux",
        "labels": {"org.opencontainers.image.version": "v2.11.4"},
    }
    return {
        "tools": {
            "syft": {"version": "1.51.0"},
            "grype": {"version": "0.117.0"},
        },
        "license_policy": {
            "scopePathPrefix": "/opt/dsh/runtime/node_modules/",
            "allowedSpdxExpressions": ["MIT", "Apache-2.0"],
            "globallyDeniedSpdxExpressions": ["AGPL-3.0-only"],
            "missingLicenseExceptions": [],
        },
        "vulnerability_policy": {
            "blockedSeverities": ["High", "Critical"],
            "exceptions": [],
        },
        "dsh_sbom": {
            "descriptor": {"name": "syft", "version": "1.51.0"},
            "source": {"type": "image", "metadata": dsh_source},
            "artifacts": [
                {
                    "name": "@deepseek-ai/dsh",
                    "version": "0.1.1-rc.2",
                    "purl": "pkg:npm/%40deepseek-ai/dsh@0.1.1-rc.2",
                    "licenses": [{"spdxExpression": "MIT"}],
                    "locations": [
                        {"path": "/opt/dsh/runtime/node_modules/dsh/package.json"}
                    ],
                }
            ],
        },
        "caddy_sbom": {
            "descriptor": {"name": "syft", "version": "1.51.0"},
            "source": {"type": "image", "metadata": caddy_source},
            "artifacts": [
                {
                    "name": "github.com/caddyserver/caddy/v2",
                    "version": "v2.11.4",
                    "purl": "pkg:golang/github.com/caddyserver/caddy/v2@v2.11.4",
                    "licenses": [{"spdxExpression": "Apache-2.0"}],
                    "locations": [{"path": "/usr/bin/caddy"}],
                }
            ],
        },
        "build_metadata": {
            "containerimage.digest": DSH_MANIFEST,
            "containerimage.descriptor": {
                "platform": {"architecture": "amd64", "os": "linux"}
            },
            "buildx.build.provenance": {
                "buildType": "https://mobyproject.org/buildkit@v1",
                "materials": [
                    {
                        "digest": {"sha256": NODE_DIGEST.removeprefix("sha256:")}
                    },
                    {
                        "digest": {
                            "sha256": NODE_RUNTIME_DIGEST.removeprefix("sha256:")
                        }
                    }
                ],
                "invocation": {"environment": {"platform": "linux/amd64"}},
            },
        },
        "dsh_inspect": [
            {
                "Id": "sha256:dsh-image",
                "Os": "linux",
                "Architecture": "amd64",
                "RepoDigests": [f"local/dsh@{DSH_MANIFEST}"],
                "Config": {
                    "Labels": {"org.opencontainers.image.revision": SOURCE_REVISION}
                },
            }
        ],
        "caddy_inspect": [
            {
                "Id": "sha256:caddy-image",
                "Os": "linux",
                "Architecture": "amd64",
                "RepoDigests": [f"caddy@{CADDY_DIGEST}"],
                "Config": {"Labels": {}},
            }
        ],
        "dsh_vulnerabilities": vulnerability_report(dsh_source),
        "caddy_vulnerabilities": vulnerability_report(caddy_source),
    }


def vulnerability_report(source: dict[str, object]) -> dict[str, object]:
    return {
        "descriptor": {
            "name": "grype",
            "version": "0.117.0",
            "timestamp": "2026-08-22T00:00:00Z",
            "configuration": grype_configuration(),
            "db": {
                "status": {
                    "valid": True,
                    "built": "2026-08-21T00:00:00Z",
                    "from": (
                        "https://grype.example.invalid/db.tar.zst?"
                        f"checksum=sha256%3A{'e' * 64}"
                    ),
                }
            },
        },
        "source": {"target": {"imageID": source["imageID"]}},
        "matches": [],
    }


def grype_configuration() -> dict[str, object]:
    def ignore(name: str, package_type: str, upstream: str) -> dict[str, object]:
        return {
            "vulnerability": "",
            "include-aliases": False,
            "namespace": "",
            "fix-state": "",
            "package": {
                "name": name,
                "version": "",
                "type": package_type,
                "upstream-name": upstream,
            },
            "vex-status": "",
            "vex-justification": "",
            "match-type": "exact-indirect-match",
        }

    return {
        "only-fixed": False,
        "only-notfixed": False,
        "ignore-wontfix": "",
        "exclude": [],
        "vex-documents": [],
        "vex-add": [],
        "show-suppressed": False,
        "by-cve": False,
        "add-cpes-if-none": False,
        "match-upstream-kernel-headers": False,
        "distro": "",
        "platform": "",
        "from": None,
        "search": {
            "scope": "squashed",
            "indexed-archives": True,
        },
        "ignore": [
            ignore("kernel-headers", "rpm", "kernel"),
            ignore("linux(-.*)?-headers-.*", "deb", "linux.*"),
            ignore("linux-libc-dev", "deb", "linux"),
            ignore("linux-kbuild-.*", "deb", "linux.*"),
        ],
        "db": {
            "validate-by-hash-on-start": True,
            "validate-age": True,
        },
    }


class SupplyChainPolicyTests(unittest.TestCase):
    def run_case(self, documents: dict[str, object]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths: dict[str, Path] = {}
            for name, document in documents.items():
                path = root / f"{name}.json"
                path.write_text(json.dumps(document), encoding="utf-8")
                paths[name] = path
            output = root / "summary.json"
            command = [
                str(CHECKER),
                "--dsh-sbom",
                str(paths["dsh_sbom"]),
                "--caddy-sbom",
                str(paths["caddy_sbom"]),
                "--dsh-vulnerabilities",
                str(paths["dsh_vulnerabilities"]),
                "--caddy-vulnerabilities",
                str(paths["caddy_vulnerabilities"]),
                "--build-metadata",
                str(paths["build_metadata"]),
                "--dsh-inspect",
                str(paths["dsh_inspect"]),
                "--caddy-inspect",
                str(paths["caddy_inspect"]),
                "--license-policy",
                str(paths["license_policy"]),
                "--vulnerability-policy",
                str(paths["vulnerability_policy"]),
                "--tools-policy",
                str(paths["tools"]),
                "--architecture",
                "amd64",
                "--platform",
                "linux/amd64",
                "--dsh-version",
                "0.1.1-rc.2",
                "--caddy-version",
                "2.11.4",
                "--node-base-digest",
                NODE_DIGEST,
                "--node-runtime-digest",
                NODE_RUNTIME_DIGEST,
                "--caddy-digest",
                CADDY_DIGEST,
                "--source-revision",
                SOURCE_REVISION,
                "--output",
                str(output),
            ]
            result = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertTrue(output.is_file())
            return result

    def test_valid_evidence_passes(self) -> None:
        result = self.run_case(base_documents())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrong_revision_fails(self) -> None:
        docs = base_documents()
        docs["dsh_inspect"][0]["Config"]["Labels"][
            "org.opencontainers.image.revision"
        ] = "wrong"
        self.assertNotEqual(self.run_case(docs).returncode, 0)

    def test_wrong_platform_fails(self) -> None:
        docs = base_documents()
        docs["build_metadata"]["buildx.build.provenance"]["invocation"][
            "environment"
        ]["platform"] = "linux/arm64"
        self.assertNotEqual(self.run_case(docs).returncode, 0)

    def test_unapproved_license_fails(self) -> None:
        docs = base_documents()
        docs["dsh_sbom"]["artifacts"][0]["licenses"] = [
            {"spdxExpression": "AGPL-3.0-only"}
        ]
        self.assertNotEqual(self.run_case(docs).returncode, 0)

    def test_unapproved_high_vulnerability_fails(self) -> None:
        docs = base_documents()
        docs["dsh_vulnerabilities"]["matches"] = [high_vulnerability()]
        self.assertNotEqual(self.run_case(docs).returncode, 0)

    def test_weakened_severity_or_scanner_filter_fails(self) -> None:
        severity_docs = base_documents()
        severity_docs["vulnerability_policy"]["blockedSeverities"] = ["Critical"]
        self.assertNotEqual(self.run_case(severity_docs).returncode, 0)

        filter_docs = base_documents()
        filter_docs["dsh_vulnerabilities"]["descriptor"]["configuration"][
            "only-fixed"
        ] = True
        self.assertNotEqual(self.run_case(filter_docs).returncode, 0)

        ignore_docs = base_documents()
        ignore_docs["dsh_vulnerabilities"]["descriptor"]["configuration"][
            "ignore"
        ].append(
            {
                "vulnerability": "CVE-*",
                "package": {},
                "match-type": "exact-indirect-match",
            }
        )
        self.assertNotEqual(self.run_case(ignore_docs).returncode, 0)

    def test_exact_unexpired_vulnerability_exception_passes(self) -> None:
        docs = base_documents()
        docs["dsh_vulnerabilities"]["matches"] = [high_vulnerability()]
        docs["vulnerability_policy"]["exceptions"] = [
            {
                "id": "CVE-2099-0001",
                "purl": "pkg:npm/example@1.0.0",
                "package": "example",
                "version": "1.0.0",
                "reason": "Not reachable in candidate runtime.",
                "owner": "maintainer",
                "tracking": "TEST-1",
                "expiresAt": "2099-12-31",
                "architectures": ["amd64"],
            },
            {
                "id": "CVE-2099-9999",
                "purl": "pkg:npm/arm-only@1.0.0",
                "package": "arm-only",
                "version": "1.0.0",
                "reason": "Applies only to the other architecture.",
                "owner": "maintainer",
                "tracking": "TEST-ARM",
                "expiresAt": "2099-12-31",
                "architectures": ["arm64"],
            },
        ]
        result = self.run_case(docs)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unused_duplicate_or_unscoped_exception_fails(self) -> None:
        valid_exception = {
            "id": "CVE-2099-0001",
            "purl": "pkg:npm/example@1.0.0",
            "package": "example",
            "version": "1.0.0",
            "reason": "test",
            "owner": "maintainer",
            "tracking": "TEST-3",
            "expiresAt": "2099-12-31",
            "architectures": ["amd64"],
        }

        unused_docs = base_documents()
        unused_docs["vulnerability_policy"]["exceptions"] = [valid_exception]
        self.assertNotEqual(self.run_case(unused_docs).returncode, 0)

        duplicate_docs = base_documents()
        duplicate_docs["dsh_vulnerabilities"]["matches"] = [high_vulnerability()]
        duplicate_docs["vulnerability_policy"]["exceptions"] = [
            valid_exception,
            dict(valid_exception),
        ]
        self.assertNotEqual(self.run_case(duplicate_docs).returncode, 0)

        unscoped_docs = base_documents()
        unscoped_docs["dsh_vulnerabilities"]["matches"] = [high_vulnerability()]
        unscoped_exception = dict(valid_exception)
        unscoped_exception["architectures"] = []
        unscoped_docs["vulnerability_policy"]["exceptions"] = [
            unscoped_exception
        ]
        self.assertNotEqual(self.run_case(unscoped_docs).returncode, 0)

    def test_expired_or_wildcard_exception_fails(self) -> None:
        for purl, expires in (
            ("pkg:npm/example@1.0.0", "2000-01-01"),
            ("pkg:npm/example@*", "2099-12-31"),
        ):
            with self.subTest(purl=purl, expires=expires):
                docs = base_documents()
                docs["dsh_vulnerabilities"]["matches"] = [high_vulnerability()]
                docs["vulnerability_policy"]["exceptions"] = [
                    {
                        "id": "CVE-2099-0001",
                        "purl": purl,
                        "package": "example",
                        "version": "1.0.0",
                        "reason": "test",
                        "owner": "maintainer",
                        "tracking": "TEST-2",
                        "expiresAt": expires,
                        "architectures": ["amd64"],
                    }
                ]
                self.assertNotEqual(self.run_case(docs).returncode, 0)

    def test_wrong_digest_or_missing_dsh_fails(self) -> None:
        digest_docs = base_documents()
        digest_docs["caddy_sbom"]["source"]["metadata"]["repoDigests"] = []
        self.assertNotEqual(self.run_case(digest_docs).returncode, 0)

        package_docs = base_documents()
        package_docs["dsh_sbom"]["artifacts"] = []
        self.assertNotEqual(self.run_case(package_docs).returncode, 0)

        runtime_docs = base_documents()
        runtime_docs["build_metadata"]["buildx.build.provenance"]["materials"] = [
            {
                "digest": {
                    "sha256": NODE_DIGEST.removeprefix("sha256:")
                }
            }
        ]
        self.assertNotEqual(self.run_case(runtime_docs).returncode, 0)


def high_vulnerability() -> dict[str, object]:
    return {
        "vulnerability": {
            "id": "CVE-2099-0001",
            "severity": "High",
            "fix": {"versions": ["1.0.1"]},
        },
        "artifact": {
            "name": "example",
            "version": "1.0.0",
            "purl": "pkg:npm/example@1.0.0",
        },
    }


if __name__ == "__main__":
    unittest.main()
