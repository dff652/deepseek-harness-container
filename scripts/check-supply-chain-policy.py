#!/usr/bin/env python3
"""Validate candidate SBOM, license, vulnerability and source evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


IDENTITY_WILDCARDS = re.compile(r"[*?\[\]{}]")
SHA256 = re.compile(r"sha256:[0-9a-f]{64}")
REQUIRED_BLOCKED_SEVERITIES = {"High", "Critical"}
EXPECTED_GRYPE_IGNORE_RULES = {
    ("kernel-headers", "", "rpm", "kernel"),
    ("linux(-.*)?-headers-.*", "", "deb", "linux.*"),
    ("linux-libc-dev", "", "deb", "linux"),
    ("linux-kbuild-.*", "", "deb", "linux.*"),
}


def load_json(path: str) -> Any:
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def iso_datetime(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def validate_exception_fields(
    item: dict[str, Any], required: tuple[str, ...], errors: list[str], label: str
) -> None:
    for field in required:
        if not isinstance(item.get(field), str) or not item[field].strip():
            errors.append(f"{label}: missing non-empty {field}")
    for field in ("id", "purl", "package", "name", "version"):
        value = item.get(field)
        if isinstance(value, str) and IDENTITY_WILDCARDS.search(value):
            errors.append(f"{label}: wildcard is forbidden in {field}")
    expires = item.get("expiresAt")
    if isinstance(expires, str) and expires:
        try:
            expiry = dt.date.fromisoformat(expires)
            if expiry <= dt.datetime.now(dt.timezone.utc).date():
                errors.append(f"{label}: exception expired on {expires}")
        except ValueError:
            errors.append(f"{label}: expiresAt must be YYYY-MM-DD")


def artifact_in_scope(artifact: dict[str, Any], prefix: str) -> bool:
    return any(
        isinstance(location.get("path"), str)
        and location["path"].startswith(prefix)
        for location in artifact.get("locations", [])
        if isinstance(location, dict)
    )


def spdx_contains(expression: str, identifier: str) -> bool:
    boundary = r"A-Za-z0-9.+-"
    return re.search(
        rf"(?<![{boundary}]){re.escape(identifier)}(?![{boundary}])", expression
    ) is not None


def exception_matches_license(
    exception: dict[str, Any], artifact: dict[str, Any]
) -> bool:
    return all(
        exception.get(field, "") == artifact.get(field, "")
        for field in ("name", "version", "purl")
    )


def validate_sbom(
    *,
    name: str,
    sbom: dict[str, Any],
    expected_arch: str,
    expected_version: str,
    expected_source_digest: str,
    syft_version: str,
    source_revision: str,
    errors: list[str],
) -> dict[str, Any]:
    descriptor = sbom.get("descriptor", {})
    if descriptor.get("name") != "syft" or descriptor.get("version") != syft_version:
        errors.append(f"{name}: unexpected Syft descriptor")

    source = sbom.get("source", {})
    metadata = source.get("metadata", {})
    if source.get("type") != "image":
        errors.append(f"{name}: SBOM source is not an image")
    if metadata.get("os") != "linux" or metadata.get("architecture") != expected_arch:
        errors.append(f"{name}: SBOM platform is not linux/{expected_arch}")
    repo_digests = metadata.get("repoDigests", [])
    if expected_source_digest and not any(
        isinstance(item, str) and item.endswith(f"@{expected_source_digest}")
        for item in repo_digests
    ):
        errors.append(f"{name}: expected source digest is absent from SBOM")

    labels = metadata.get("labels", {})
    if name == "dsh":
        if labels.get("org.opencontainers.image.version") != expected_version:
            errors.append("dsh: image version label does not match candidate")
        if (
            source_revision
            and labels.get("org.opencontainers.image.revision") != source_revision
        ):
            errors.append("dsh: source revision label does not match GITHUB_SHA")
        matches = [
            artifact
            for artifact in sbom.get("artifacts", [])
            if artifact.get("name") == "@deepseek-ai/dsh"
            and artifact.get("version") == expected_version
            and artifact.get("purl")
            == f"pkg:npm/%40deepseek-ai/dsh@{expected_version}"
        ]
        if len(matches) != 1:
            errors.append("dsh: exact npm package is missing or duplicated in SBOM")
    else:
        if labels.get("org.opencontainers.image.version") != f"v{expected_version}":
            errors.append("caddy: image version label does not match candidate")
        matches = [
            artifact
            for artifact in sbom.get("artifacts", [])
            if artifact.get("name") == "github.com/caddyserver/caddy/v2"
            and artifact.get("version") == f"v{expected_version}"
        ]
        if len(matches) != 1:
            errors.append("caddy: exact Go module is missing or duplicated in SBOM")
    return metadata


def validate_build_evidence(
    *,
    metadata: dict[str, Any],
    dsh_inspect: list[dict[str, Any]],
    caddy_inspect: list[dict[str, Any]],
    dsh_source: dict[str, Any],
    caddy_source: dict[str, Any],
    expected_arch: str,
    expected_platform: str,
    expected_node_build_digest: str,
    expected_node_runtime_digest: str,
    source_revision: str,
    errors: list[str],
) -> None:
    provenance = metadata.get("buildx.build.provenance", {})
    environment = provenance.get("invocation", {}).get("environment", {})
    if provenance.get("buildType") != "https://mobyproject.org/buildkit@v1":
        errors.append("build metadata: BuildKit provenance is missing")
    if environment.get("platform") != expected_platform:
        errors.append("build metadata: target platform mismatch")
    materials = provenance.get("materials", [])
    for label, expected_digest in (
        ("build", expected_node_build_digest),
        ("runtime", expected_node_runtime_digest),
    ):
        if not any(
            item.get("digest", {}).get("sha256")
            == expected_digest.removeprefix("sha256:")
            for item in materials
            if isinstance(item, dict)
        ):
            errors.append(
                f"build metadata: pinned Node {label} child digest is absent"
            )

    descriptor = metadata.get("containerimage.descriptor", {})
    if descriptor.get("platform") != {"architecture": expected_arch, "os": "linux"}:
        errors.append("build metadata: container descriptor platform mismatch")
    build_digest = metadata.get("containerimage.digest")
    if not isinstance(build_digest, str) or not build_digest.startswith("sha256:"):
        errors.append("build metadata: container manifest digest is missing")
    elif (
        build_digest
        not in {
            dsh_source.get("manifestDigest"),
            dsh_source.get("id"),
        }
        and not any(
            isinstance(item, str) and item.endswith(f"@{build_digest}")
            for item in dsh_source.get("repoDigests", [])
        )
    ):
        errors.append("build metadata: manifest digest does not match DSH SBOM")

    for name, inspect, source in (
        ("dsh", dsh_inspect, dsh_source),
        ("caddy", caddy_inspect, caddy_source),
    ):
        if len(inspect) != 1:
            errors.append(f"{name}: image inspect must contain exactly one record")
            continue
        record = inspect[0]
        if record.get("Os") != "linux" or record.get("Architecture") != expected_arch:
            errors.append(f"{name}: image inspect platform mismatch")
        inspect_digests = set(record.get("RepoDigests", []) or [])
        source_digests = set(source.get("repoDigests", []) or [])
        same_config = record.get("Id") == source.get("imageID")
        if not same_config and not inspect_digests.intersection(source_digests):
            errors.append(f"{name}: repo digest differs between inspect and SBOM")
        if name == "dsh" and source_revision:
            labels = record.get("Config", {}).get("Labels", {}) or {}
            if labels.get("org.opencontainers.image.revision") != source_revision:
                errors.append("dsh: inspect source revision does not match GITHUB_SHA")


def validate_licenses(
    sboms: list[dict[str, Any]], policy: dict[str, Any], errors: list[str]
) -> dict[str, Any]:
    prefix = policy.get("scopePathPrefix")
    allowed = set(policy.get("allowedSpdxExpressions", []))
    denied = set(policy.get("globallyDeniedSpdxExpressions", []))
    exceptions = policy.get("missingLicenseExceptions", [])
    used: set[int] = set()

    for index, item in enumerate(exceptions):
        validate_exception_fields(
            item,
            ("name", "version", "reason", "owner", "tracking", "expiresAt"),
            errors,
            f"license exception {index}",
        )

    scoped_count = 0
    for sbom in sboms:
        for artifact in sbom.get("artifacts", []):
            for license_item in artifact.get("licenses", []):
                expression = license_item.get("spdxExpression")
                if isinstance(expression, str):
                    for denied_expression in denied:
                        if spdx_contains(expression, denied_expression):
                            errors.append(
                                "license: globally denied expression "
                                f"{denied_expression} on {artifact.get('name')}"
                            )
            if not artifact_in_scope(artifact, prefix):
                continue
            scoped_count += 1
            licenses = artifact.get("licenses", [])
            if not licenses:
                matches = [
                    index
                    for index, exception in enumerate(exceptions)
                    if exception_matches_license(exception, artifact)
                ]
                if len(matches) != 1:
                    errors.append(
                        f"license: missing license for {artifact.get('name')}@{artifact.get('version')}"
                    )
                else:
                    used.add(matches[0])
                continue
            for license_item in licenses:
                expression = license_item.get("spdxExpression")
                if not expression or expression not in allowed:
                    errors.append(
                        f"license: unapproved expression {expression!r} on {artifact.get('name')}"
                    )

    unused = sorted(set(range(len(exceptions))) - used)
    if unused:
        errors.append(f"license: unused exceptions {unused}")
    return {"scopedArtifactCount": scoped_count, "usedExceptionCount": len(used)}


def vulnerability_key(match: dict[str, Any]) -> tuple[str, str, str, str]:
    vulnerability = match.get("vulnerability", {})
    artifact = match.get("artifact", {})
    return (
        vulnerability.get("id", ""),
        artifact.get("purl", ""),
        artifact.get("name", ""),
        artifact.get("version", ""),
    )


def validate_grype_configuration(
    name: str, descriptor: dict[str, Any], errors: list[str]
) -> str:
    configuration = descriptor.get("configuration")
    if not isinstance(configuration, dict):
        errors.append(f"{name}: Grype configuration is missing")
        return ""

    required_values = {
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
    }
    for field, expected in required_values.items():
        if configuration.get(field) != expected:
            errors.append(f"{name}: forbidden Grype filter/configuration in {field}")

    search = configuration.get("search", {})
    if (
        search.get("scope") != "squashed"
        or search.get("indexed-archives") is not True
    ):
        errors.append(f"{name}: Grype search scope/archive indexing was weakened")

    db_configuration = configuration.get("db", {})
    if db_configuration.get("validate-by-hash-on-start") is not True:
        errors.append(f"{name}: Grype DB hash validation is disabled")
    if db_configuration.get("validate-age") is not True:
        errors.append(f"{name}: Grype DB age validation is disabled")

    normalized_ignores: set[tuple[str, str, str, str]] = set()
    ignore_items = configuration.get("ignore")
    if not isinstance(ignore_items, list):
        errors.append(f"{name}: Grype ignore configuration is invalid")
        ignore_items = []
    for item in ignore_items:
        package = item.get("package", {}) if isinstance(item, dict) else {}
        if not isinstance(item, dict) or not isinstance(package, dict):
            errors.append(f"{name}: Grype ignore rule is malformed")
            continue
        normalized_ignores.add(
            (
                package.get("name", ""),
                package.get("version", ""),
                package.get("type", ""),
                package.get("upstream-name", ""),
            )
        )
        if any(
            item.get(field) not in ("", False)
            for field in (
                "vulnerability",
                "include-aliases",
                "namespace",
                "fix-state",
                "vex-status",
                "vex-justification",
            )
        ) or item.get("match-type") != "exact-indirect-match":
            errors.append(f"{name}: unapproved Grype ignore rule")
    if normalized_ignores != EXPECTED_GRYPE_IGNORE_RULES or len(ignore_items) != len(
        EXPECTED_GRYPE_IGNORE_RULES
    ):
        errors.append(f"{name}: Grype ignore rules differ from pinned defaults")

    status = descriptor.get("db", {}).get("status", {})
    source = status.get("from")
    checksums = (
        parse_qs(urlparse(source).query).get("checksum", [])
        if isinstance(source, str)
        else []
    )
    if len(checksums) != 1 or SHA256.fullmatch(checksums[0]) is None:
        errors.append(f"{name}: Grype DB source checksum is missing or invalid")
    return source if isinstance(source, str) else ""


def validate_vulnerabilities(
    reports: list[tuple[str, dict[str, Any]]],
    policy: dict[str, Any],
    grype_version: str,
    architecture: str,
    sbom_sources: dict[str, dict[str, Any]],
    errors: list[str],
) -> dict[str, Any]:
    blocked = set(policy.get("blockedSeverities", []))
    if blocked != REQUIRED_BLOCKED_SEVERITIES:
        errors.append("vulnerability policy: blockedSeverities must be High and Critical")
    exceptions = policy.get("exceptions", [])
    exception_keys: dict[tuple[str, str, str, str], int] = {}
    used: set[int] = set()
    for index, item in enumerate(exceptions):
        validate_exception_fields(
            item,
            (
                "id",
                "purl",
                "package",
                "version",
                "reason",
                "owner",
                "tracking",
                "expiresAt",
            ),
            errors,
            f"vulnerability exception {index}",
        )
        key = (
            item.get("id", ""),
            item.get("purl", ""),
            item.get("package", ""),
            item.get("version", ""),
        )
        architectures = item.get("architectures")
        if (
            not isinstance(architectures, list)
            or not architectures
            or any(value not in ("amd64", "arm64") for value in architectures)
        ):
            errors.append(
                f"vulnerability exception {index}: architectures must select amd64 and/or arm64"
            )
        if isinstance(architectures, list) and architecture in architectures:
            if key in exception_keys:
                errors.append(f"vulnerability exception {index}: duplicate identity")
            exception_keys[key] = index

    blocked_count = 0
    database_sources: dict[str, str] = {}
    for name, report in reports:
        descriptor = report.get("descriptor", {})
        if descriptor.get("name") != "grype" or descriptor.get("version") != grype_version:
            errors.append(f"{name}: unexpected Grype descriptor")
        database_sources[name] = validate_grype_configuration(
            name, descriptor, errors
        )
        status = descriptor.get("db", {}).get("status", {})
        if status.get("valid") is not True:
            errors.append(f"{name}: Grype DB is not valid")
        try:
            built = iso_datetime(status["built"])
            scanned = iso_datetime(descriptor["timestamp"])
            if scanned - built > dt.timedelta(days=5) or scanned < built:
                errors.append(f"{name}: Grype DB is stale or timestamp is inconsistent")
        except (KeyError, TypeError, ValueError):
            errors.append(f"{name}: Grype DB timestamps are missing or invalid")

        target = report.get("source", {}).get("target", {})
        if target.get("imageID") != sbom_sources[name].get("imageID"):
            errors.append(f"{name}: Grype report and SBOM image IDs differ")

        for match in report.get("matches", []):
            if match.get("vulnerability", {}).get("severity") not in blocked:
                continue
            blocked_count += 1
            key = vulnerability_key(match)
            if key not in exception_keys:
                errors.append(
                    "vulnerability: unapproved "
                    f"{key[0]} {key[2]}@{key[3]} ({key[1]})"
                )
            else:
                used.add(exception_keys[key])

    applicable = {
        index
        for index, item in enumerate(exceptions)
        if architecture in item.get("architectures", [])
    }
    unused = sorted(applicable - used)
    if unused:
        errors.append(f"vulnerability: unused exceptions {unused}")
    return {
        "blockedFindingCount": blocked_count,
        "usedExceptionCount": len(used),
        "databaseSources": database_sources,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsh-sbom", required=True)
    parser.add_argument("--caddy-sbom", required=True)
    parser.add_argument("--dsh-vulnerabilities", required=True)
    parser.add_argument("--caddy-vulnerabilities", required=True)
    parser.add_argument("--build-metadata", required=True)
    parser.add_argument("--dsh-inspect", required=True)
    parser.add_argument("--caddy-inspect", required=True)
    parser.add_argument("--license-policy", required=True)
    parser.add_argument("--vulnerability-policy", required=True)
    parser.add_argument("--tools-policy", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--dsh-version", required=True)
    parser.add_argument("--caddy-version", required=True)
    parser.add_argument("--node-base-digest", required=True)
    parser.add_argument("--node-runtime-digest", required=True)
    parser.add_argument("--caddy-digest", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    errors: list[str] = []
    tools = load_json(args.tools_policy)
    dsh_sbom = load_json(args.dsh_sbom)
    caddy_sbom = load_json(args.caddy_sbom)
    dsh_source = validate_sbom(
        name="dsh",
        sbom=dsh_sbom,
        expected_arch=args.architecture,
        expected_version=args.dsh_version,
        expected_source_digest="",
        syft_version=tools["syft"]["version"],
        source_revision=args.source_revision,
        errors=errors,
    )
    caddy_source = validate_sbom(
        name="caddy",
        sbom=caddy_sbom,
        expected_arch=args.architecture,
        expected_version=args.caddy_version,
        expected_source_digest=args.caddy_digest,
        syft_version=tools["syft"]["version"],
        source_revision="",
        errors=errors,
    )
    validate_build_evidence(
        metadata=load_json(args.build_metadata),
        dsh_inspect=load_json(args.dsh_inspect),
        caddy_inspect=load_json(args.caddy_inspect),
        dsh_source=dsh_source,
        caddy_source=caddy_source,
        expected_arch=args.architecture,
        expected_platform=args.platform,
        expected_node_build_digest=args.node_base_digest,
        expected_node_runtime_digest=args.node_runtime_digest,
        source_revision=args.source_revision,
        errors=errors,
    )
    license_summary = validate_licenses(
        [dsh_sbom, caddy_sbom], load_json(args.license_policy), errors
    )
    vulnerability_summary = validate_vulnerabilities(
        [
            ("dsh", load_json(args.dsh_vulnerabilities)),
            ("caddy", load_json(args.caddy_vulnerabilities)),
        ],
        load_json(args.vulnerability_policy),
        tools["grype"]["version"],
        args.architecture,
        {"dsh": dsh_source, "caddy": caddy_source},
        errors,
    )

    summary = {
        "schemaVersion": 1,
        "status": "pass" if not errors else "fail",
        "platform": args.platform,
        "sourceRevision": args.source_revision,
        "dshVersion": args.dsh_version,
        "caddyVersion": args.caddy_version,
        "license": license_summary,
        "vulnerability": vulnerability_summary,
        "errors": errors,
    }
    with Path(args.output).open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")

    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: supply-chain evidence and policy checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
