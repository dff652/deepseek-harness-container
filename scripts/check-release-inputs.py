#!/usr/bin/env python3
"""Check the release input ledger and its checked-in consumers.

The ledger is intentionally declarative.  This command does not resolve tags,
rewrite files, or approve a vulnerability exception.  A maintainer can use
``--validate-only`` while preparing a proposed ledger, then run the default
check after updating the consumers in the same change.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import re
import sys
from pathlib import Path
from typing import Any


DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
UNSAFE_PRERELEASE = re.compile(r"(?:alpha|beta|nightly|dev|canary)", re.IGNORECASE)
FLOATING_ALIAS = re.compile(
    r"^(?:latest|stable|current|edge|main|master|head|rolling|next|lts)(?:$|[-_./])",
    re.IGNORECASE,
)
STABLE_SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
IMAGE_REF = re.compile(r"^(?P<name>[^@\s]+)@(?P<digest>sha256:[0-9a-f]{64})$")
PLATFORMS = ("linux/amd64", "linux/arm64")


def load_json(path: Path) -> Any:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{path} must be a regular file")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"could not parse {path}: {exc}") from exc


def canonical_image_name(name: str) -> str:
    for prefix in ("docker.io/library/", "docker.io/"):
        if name.startswith(prefix):
            return name[len(prefix) :]
    return name


def image_repository(name: str) -> str:
    """Return the repository portion of a tag or digest reference."""
    leaf = name.rsplit("/", 1)[-1]
    if ":" in leaf:
        name = name.rsplit(":", 1)[0]
    return canonical_image_name(name)


def image_identity(ref: str) -> tuple[str, str] | None:
    match = IMAGE_REF.fullmatch(ref)
    if not match:
        return None
    return image_repository(match.group("name")), match.group("digest")


def exact_image_identity(ref: str) -> tuple[str, str] | None:
    """Normalize Docker Hub aliases while preserving the exact tag form."""
    match = IMAGE_REF.fullmatch(ref)
    if not match:
        return None
    return canonical_image_name(match.group("name")), match.group("digest")


def ref_has_exact_tag(ref: str, expected_tag: str) -> bool:
    """Require an explicit exact tag, or a versioned digest-only repository leaf."""
    name = ref.split("@", 1)[0]
    leaf = name.rsplit("/", 1)[-1]
    if ":" in leaf:
        return leaf.rsplit(":", 1)[1] == expected_tag
    return leaf == expected_tag


def require_string(value: Any, label: str, errors: list[str]) -> str:
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{label} must be a non-empty string")
        return ""
    return value


def valid_sha512_sri(value: Any) -> bool:
    if not isinstance(value, str) or not value.startswith("sha512-"):
        return False
    try:
        return len(base64.b64decode(value.removeprefix("sha512-"), validate=True)) == 64
    except (binascii.Error, ValueError):
        return False


def validate_image(
    name: str, image: dict[str, Any], errors: list[str], *, platforms: bool = True
) -> None:
    if not isinstance(image, dict):
        errors.append(f"images.{name} must be an object")
        return
    repository = require_string(image.get("repository"), f"images.{name}.repository", errors)
    tag = require_string(image.get("tag"), f"images.{name}.tag", errors)
    if tag and UNSAFE_PRERELEASE.search(tag):
        errors.append(f"images.{name}.tag cannot be an alpha/beta/nightly/dev/canary")
    if tag and FLOATING_ALIAS.search(tag):
        errors.append(f"images.{name}.tag cannot be a floating channel alias")
    index_digest = image.get("indexDigest")
    if not isinstance(index_digest, str) or not DIGEST.fullmatch(index_digest):
        errors.append(f"images.{name}.indexDigest must be an exact sha256 digest")
    if platforms:
        entries = image.get("platforms")
        if not isinstance(entries, dict) or set(entries) != set(PLATFORMS):
            errors.append(f"images.{name}.platforms must contain exactly {PLATFORMS}")
            return
        for platform in PLATFORMS:
            item = entries.get(platform)
            if not isinstance(item, dict):
                errors.append(f"images.{name}.platforms.{platform} must be an object")
                continue
            digest = item.get("digest")
            ref = item.get("ref")
            if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
                errors.append(f"images.{name}.platforms.{platform}.digest is not exact")
            if not isinstance(ref, str) or not IMAGE_REF.fullmatch(ref):
                errors.append(f"images.{name}.platforms.{platform}.ref is not immutable")
                continue
            identity = image_identity(ref)
            if identity != (image_repository(repository), digest):
                errors.append(
                    f"images.{name}.platforms.{platform}.ref does not match repository/digest"
                )
            if not ref_has_exact_tag(ref, tag):
                errors.append(f"images.{name}.platforms.{platform}.ref does not use exact tag {tag}")
    else:
        ref = image.get("ref")
        digest = image.get("digest")
        if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
            errors.append(f"images.{name}.digest is not exact")
        if not isinstance(ref, str) or not IMAGE_REF.fullmatch(ref):
            errors.append(f"images.{name}.ref is not immutable")
        elif image_identity(ref) != (image_repository(repository), digest):
            errors.append(f"images.{name}.ref does not match repository/digest")
        elif not ref_has_exact_tag(ref, tag):
            errors.append(f"images.{name}.ref does not use exact tag {tag}")


def walk_strings(value: Any, path: str = "") -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    if isinstance(value, str):
        result.append((path, value))
    elif isinstance(value, dict):
        for key, child in value.items():
            result.extend(walk_strings(child, f"{path}.{key}" if path else str(key)))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            result.extend(walk_strings(child, f"{path}[{index}]"))
    return result


def validate_structure(document: Any, errors: list[str]) -> None:
    if not isinstance(document, dict):
        errors.append("release input ledger must be a JSON object")
        return
    if document.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")

    release = document.get("release")
    if not isinstance(release, dict) or release.get("status") != "candidate-only":
        errors.append("release.status must remain candidate-only")
        release = release if isinstance(release, dict) else {}
    dsh = release.get("dsh")
    if not isinstance(dsh, dict):
        errors.append("release.dsh must be an object")
        dsh = {}
    dsh_version = require_string(dsh.get("version"), "release.dsh.version", errors)
    if dsh_version and UNSAFE_PRERELEASE.search(dsh_version):
        errors.append("release.dsh.version cannot auto-accept alpha/beta/nightly/dev/canary")
    if dsh_version and not re.fullmatch(r"\d+\.\d+\.\d+(?:-rc\.\d+)?", dsh_version):
        errors.append("release.dsh.version must be a stable or rc semantic version")
    dsh_tag = require_string(dsh.get("tag"), "release.dsh.tag", errors)
    if dsh_version and dsh_tag != f"dsh-v{dsh_version}":
        errors.append("release.dsh.tag must be dsh-v<release.dsh.version>")
    commit = dsh.get("commit")
    if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
        errors.append("release.dsh.commit must be a 40-character lowercase commit")
    integrity = dsh.get("npmIntegrity")
    if not valid_sha512_sri(integrity):
        errors.append("release.dsh.npmIntegrity must be a 64-byte sha512 SRI value")

    for component in ("node", "pnpm"):
        item = release.get(component)
        if not isinstance(item, dict):
            errors.append(f"release.{component} must be an object")
        else:
            version = require_string(item.get("version"), f"release.{component}.version", errors)
            if version and not STABLE_SEMVER.fullmatch(version):
                errors.append(f"release.{component}.version must be a stable three-part version")
    pnpm = release.get("pnpm")
    if isinstance(pnpm, dict):
        integrity = pnpm.get("integrity")
        if not isinstance(integrity, str) or not re.fullmatch(r"sha512\.[0-9a-f]{128}", integrity):
            errors.append("release.pnpm.integrity must be a Corepack sha512 hash")

    images = document.get("images")
    if not isinstance(images, dict):
        errors.append("images must be an object")
        images = {}
    for name in ("nodeBuild", "nodeRuntime", "caddy", "haproxy"):
        validate_image(name, images.get(name), errors)
    validate_image("dockerfileFrontend", images.get("dockerfileFrontend"), errors, platforms=False)
    validate_image("buildkit", images.get("buildkit"), errors, platforms=False)

    archive_tags = document.get("archiveTags")
    if not isinstance(archive_tags, dict):
        errors.append("archiveTags must be an object")
    else:
        for gateway in ("caddy", "haproxy"):
            entries = archive_tags.get(gateway)
            if not isinstance(entries, dict) or set(entries) != set(PLATFORMS):
                errors.append(f"archiveTags.{gateway} must contain exactly {PLATFORMS}")
                continue
            for platform, value in entries.items():
                if not isinstance(value, str) or "@" in value or "latest" in value.lower():
                    errors.append(f"archiveTags.{gateway}.{platform} must be a dedicated tag")
                if not re.search(rf"-(amd64|arm64)-[0-9a-f]{{12,64}}$", value):
                    errors.append(f"archiveTags.{gateway}.{platform} is not architecture-specific")

    tools = document.get("tools")
    if not isinstance(tools, dict):
        errors.append("tools must be an object")
    else:
        for tool in ("syft", "grype", "gitleaks"):
            item = tools.get(tool)
            if not isinstance(item, dict):
                errors.append(f"tools.{tool} must be an object")
                continue
            version = require_string(item.get("version"), f"tools.{tool}.version", errors)
            if version and not STABLE_SEMVER.fullmatch(version):
                errors.append(f"tools.{tool}.version must be a stable three-part version")
            require_string(item.get("action"), f"tools.{tool}.action", errors)
            action_commit = item.get("actionCommit")
            if not isinstance(action_commit, str) or not COMMIT.fullmatch(action_commit):
                errors.append(f"tools.{tool}.actionCommit must be a 40-character commit")
            git_commit = item.get("gitCommit")
            if tool in ("syft", "grype"):
                if not isinstance(git_commit, str) or not COMMIT.fullmatch(git_commit):
                    errors.append(f"tools.{tool}.gitCommit must be a 40-character commit")
            elif git_commit is not None:
                errors.append("tools.gitleaks.gitCommit is unsupported; use the action commit")

    policy = document.get("policy")
    if not isinstance(policy, dict):
        errors.append("policy must be an object")
    else:
        if policy.get("allowFloatingReferences") is not False:
            errors.append("policy.allowFloatingReferences must be false")
        if policy.get("allowAlphaPrereleases") is not False:
            errors.append("policy.allowAlphaPrereleases must be false")
        if policy.get("vulnerabilityExceptions") != "manual-review-required":
            errors.append("vulnerability exceptions must require manual review")
        if policy.get("blockedSeverities") != ["High", "Critical"]:
            errors.append("policy.blockedSeverities must remain High and Critical")

    for path, value in walk_strings(document):
        lowered = value.lower()
        if "latest" in lowered:
            errors.append(f"{path} contains forbidden floating latest")
        if "@sha256:" in value and not IMAGE_REF.search(value):
            errors.append(f"{path} contains a malformed immutable image reference")


def check_consumer(
    root: Path, relative: str, fragments: list[str], errors: list[str]
) -> None:
    path = root / relative
    if not path.is_file() or path.is_symlink():
        errors.append(f"consumer is missing or not regular: {relative}")
        return
    text = path.read_text(encoding="utf-8")
    for fragment in fragments:
        if fragment not in text:
            errors.append(f"{relative} is missing ledger value: {fragment}")


def check_consumers(root: Path, document: dict[str, Any], errors: list[str]) -> None:
    release = document["release"]
    dsh = release["dsh"]
    node_version = release["node"]["version"]
    pnpm = release["pnpm"]
    images = document["images"]
    tools = document["tools"]
    arm = "linux/arm64"
    amd = "linux/amd64"
    node_base_arm = images["nodeBuild"]["platforms"][arm]["ref"]
    node_base_amd = images["nodeBuild"]["platforms"][amd]["ref"]
    node_runtime_arm = images["nodeRuntime"]["platforms"][arm]["ref"]
    node_runtime_amd = images["nodeRuntime"]["platforms"][amd]["ref"]
    caddy_arm = images["caddy"]["platforms"][arm]["ref"]
    caddy_amd = images["caddy"]["platforms"][amd]["ref"]
    haproxy_index = (
        "haproxy:"
        + images["haproxy"]["tag"]
        + "@"
        + images["haproxy"]["indexDigest"]
    )
    buildkit_ref = images["buildkit"]["ref"]
    frontend_ref = images["dockerfileFrontend"]["ref"]

    check_consumer(
        root,
        "Dockerfile",
        [
            f"# syntax={frontend_ref.removeprefix('docker.io/')}",
            f"ARG NODE_BASE_REF={node_base_arm}",
            f"ARG NODE_RUNTIME_REF={node_runtime_arm}",
            f'test "$(pnpm --version)" = "{pnpm["version"]}"',
            f'org.opencontainers.image.version="{dsh["version"]}"',
        ],
        errors,
    )
    check_consumer(
        root,
        "runtime/package.json",
        [
            f'"version": "{dsh["version"]}"',
            f'"@deepseek-ai/dsh": "{dsh["version"]}"',
            f'"packageManager": "pnpm@{pnpm["version"]}+{pnpm["integrity"]}"',
            f'"node": "{node_version}"',
        ],
        errors,
    )
    check_consumer(
        root,
        "runtime/pnpm-lock.yaml",
        [
            f"  '{dsh['package']}@{dsh['version']}':\n"
            f"    resolution: {{integrity: {dsh['npmIntegrity']}}}",
        ],
        errors,
    )
    check_consumer(root, "compose.yaml", [caddy_arm], errors)
    check_consumer(root, "compose.amd64.yaml", [caddy_amd], errors)
    check_consumer(root, "compose.haproxy.yaml", [haproxy_index], errors)
    check_consumer(
        root,
        ".env.example",
        [document["archiveTags"]["caddy"][arm]],
        errors,
    )
    check_consumer(
        root,
        ".env.amd64.example",
        [document["archiveTags"]["caddy"][amd]],
        errors,
    )
    check_consumer(
        root,
        ".env.haproxy.example",
        [
            document["archiveTags"]["haproxy"][arm],
            document["archiveTags"]["haproxy"][amd],
        ],
        errors,
    )

    check_consumer(root, "scripts/build-candidate.sh", [buildkit_ref, node_base_arm, node_runtime_arm, caddy_arm], errors)
    check_consumer(root, "scripts/build-amd64-candidate.sh", [buildkit_ref, node_base_amd, node_runtime_amd, caddy_amd], errors)
    check_consumer(root, ".github/workflows/build-arm64.yml", [buildkit_ref, node_base_arm, node_runtime_arm, caddy_arm], errors)
    check_consumer(root, ".github/workflows/build-amd64.yml", [buildkit_ref, node_base_amd, node_runtime_amd, caddy_amd], errors)

    publication = root / ".github/workflows/publish-dockerhub-candidate.yml"
    publication_fragments = [
        f"DSH_VERSION: {dsh['version']}",
        f"CADDY_VERSION: {images['caddy']['tag']}",
        f"SYFT_VERSION: {tools['syft']['version']}",
        f"GRYPE_VERSION: {tools['grype']['version']}",
        f"GITLEAKS_VERSION: {tools['gitleaks']['version']}",
        f"anchore/sbom-action/download-syft@{tools['syft']['actionCommit']}",
        f"anchore/scan-action/download-grype@{tools['grype']['actionCommit']}",
        f"gitleaks/gitleaks-action@{tools['gitleaks']['actionCommit']}",
        node_base_amd,
        node_base_arm,
        node_runtime_amd,
        node_runtime_arm,
        caddy_amd,
        caddy_arm,
    ]
    check_consumer(root, str(publication.relative_to(root)), publication_fragments, errors)

    tools_policy = load_json(root / "policy/supply-chain-tools.json")
    if not isinstance(tools_policy, dict):
        errors.append("policy/supply-chain-tools.json must be an object")
    else:
        for name in ("syft", "grype", "gitleaks"):
            for field in ("version", "action", "actionCommit", "gitCommit"):
                if tools_policy.get(name, {}).get(field) != tools[name].get(field):
                    errors.append(f"supply-chain-tools.{name}.{field} differs from ledger")

    vulnerability = load_json(root / "policy/vulnerability-allowlist.json")
    if vulnerability.get("blockedSeverities") != ["High", "Critical"]:
        errors.append("vulnerability-allowlist blocked severities drifted")
    if vulnerability.get("exceptions") != []:
        errors.append("vulnerability exceptions require explicit owner review; updater will not accept them")

    expected_application = {
        "dshVersion": dsh["version"],
        "dshTag": dsh["tag"],
        "dshCommit": dsh["commit"],
        "npmIntegrity": dsh["npmIntegrity"],
        "nodeVersion": node_version,
        "pnpmVersion": pnpm["version"],
    }
    lock_documents: dict[str, dict[str, Any]] = {}
    for relative in ("policy/image-lock.json", "policy/native-amd64-lock.json", "policy/native-arm64-lock.json"):
        lock = load_json(root / relative)
        lock_documents[relative] = lock
        if lock.get("application") != expected_application:
            errors.append(f"{relative}.application differs from ledger")

    def index_ref(name: str) -> str:
        image = images[name]
        repository = image["repository"]
        leaf = repository.rsplit("/", 1)[-1]
        versioned_name = repository if leaf == image["tag"] else f"{repository}:{image['tag']}"
        return f"{versioned_name}@{image['indexDigest']}"

    common_images = {
        "dockerfileFrontend": frontend_ref,
        "nodeBaseIndex": index_ref("nodeBuild"),
        "nodeRuntimeIndex": index_ref("nodeRuntime"),
        "caddyIndex": index_ref("caddy"),
        "buildkit": buildkit_ref,
    }
    expected_lock_images = {
        "policy/image-lock.json": {
            **common_images,
            "nodeBaseArm64": node_base_arm,
            "nodeRuntimeArm64": node_runtime_arm,
            "caddyArm64": caddy_arm,
        },
        "policy/native-arm64-lock.json": {
            **common_images,
            "nodeBaseArm64": node_base_arm,
            "nodeRuntimeArm64": node_runtime_arm,
            "caddyArm64": caddy_arm,
        },
        "policy/native-amd64-lock.json": {
            **common_images,
            "nodeBaseAmd64": node_base_amd,
            "nodeRuntimeAmd64": node_runtime_amd,
            "caddyAmd64": caddy_amd,
        },
    }
    for relative, expected_images in expected_lock_images.items():
        lock_images = lock_documents[relative].get("images", {})
        if not isinstance(lock_images, dict):
            errors.append(f"{relative}.images must be an object")
            continue
        for key, expected in expected_images.items():
            actual = lock_images.get(key)
            if exact_image_identity(actual or "") != exact_image_identity(expected):
                errors.append(f"{relative} images.{key} differs from ledger")


def run(root: Path, inputs: Path, validate_only: bool) -> list[str]:
    errors: list[str] = []
    try:
        document = load_json(inputs)
    except ValueError as exc:
        return [str(exc)]
    validate_structure(document, errors)
    if not errors and not validate_only:
        check_consumers(root, document, errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--inputs", type=Path)
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="validate a proposed ledger without comparing checked-in consumers",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    input_path = args.inputs or root / "policy/release-inputs.json"
    if input_path.is_symlink():
        print(f"FAIL: release input ledger must not be a symlink: {input_path}", file=sys.stderr)
        return 1
    inputs = input_path.resolve()
    errors = run(root, inputs, args.validate_only)
    if errors:
        print("FAIL: release input ledger check", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    mode = "schema" if args.validate_only else "coherence"
    print(f"PASS: release input ledger {mode} check ({inputs})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
