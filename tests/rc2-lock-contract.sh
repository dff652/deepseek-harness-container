#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT

python3 - "$ROOT" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
version = "0.1.1-rc.2"
integrity = "sha512-UP1UIh6q3Gme/yXRn/QL2P8IsVlv8Shpg22TRJIZPsCRWLm4CBiA1MUvXmJAfsOEETBMLAl+xWPtFw6ICsN3wg=="

package = json.loads((root / "runtime/package.json").read_text())
assert package["version"] == version
assert package["dependencies"] == {"@deepseek-ai/dsh": version}

lock_text = (root / "runtime/pnpm-lock.yaml").read_text()
packages_text = lock_text.split("\npackages:\n", 1)[1].split("\nsnapshots:\n", 1)[0]
locked = set(re.findall(
    r"^  '(@deepseek-ai/dsh[^']*@0\.1\.1-rc\.2)':$", packages_text, re.MULTILINE
))
all_rc = set(re.findall(
    r"^  '(@deepseek-ai/dsh[^']*@0\.1\.1-rc\.[^']+)':$", packages_text, re.MULTILINE
))
assert len(locked) == 188, len(locked)
assert all_rc == locked, sorted(all_rc - locked)
assert re.search(
    r"^  '@deepseek-ai/dsh@0\.1\.1-rc\.2':\n"
    r"    resolution: \{integrity: " + re.escape(integrity) + r"\}$",
    packages_text,
    re.MULTILINE,
)

workspace_text = (root / "runtime/pnpm-workspace.yaml").read_text()
excluded = set(re.findall(
    r"^  - '(@deepseek-ai/dsh[^']*@0\.1\.1-rc\.2)'$",
    workspace_text,
    re.MULTILINE,
))
assert excluded == locked, {
    "missing": sorted(locked - excluded),
    "extra": sorted(excluded - locked),
}

policy = json.loads((root / "policy/image-lock.json").read_text())
assert policy["application"] == {
    "dshVersion": version,
    "dshTag": "dsh-v0.1.1-rc.2",
    "dshCommit": "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e",
    "npmIntegrity": integrity,
    "nodeVersion": "24.19.0",
    "pnpmVersion": "11.7.0",
}
assert policy["status"] == "qemu-candidate-built-not-released"
assert all(policy["output"].get(key) for key in (
    "builtAt", "imageId", "manifestDigest", "configDigest",
    "dshArchiveSha256", "caddyImageId", "caddyArchiveSha256",
))
assert policy["output"]["sbomSha256"] is None
assert policy["output"]["provenanceSha256"] is None

expected_images = {
    ".env.example": "DSH_IMAGE=local/dsh:0.1.1-rc.2-arm64",
    ".env.amd64.example": "DSH_IMAGE=local/dsh:0.1.1-rc.2-amd64",
    ".env.haproxy.example": "DSH_IMAGE=local/dsh:0.1.1-rc.2-arm64",
}
for relative, expected in expected_images.items():
    lines = (root / relative).read_text().splitlines()
    image_lines = [line for line in lines if line.startswith("DSH_IMAGE=")]
    assert image_lines == [expected], {relative: image_lines}
PY

printf 'PASS: rc.2 npm closure, release-age exclusions, environment examples and QEMU evidence lock are coherent\n'
