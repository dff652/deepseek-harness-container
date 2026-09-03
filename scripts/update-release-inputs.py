#!/usr/bin/env python3
"""Validate a reviewed release-input proposal before an explicit apply.

This helper deliberately has no registry or npm lookup and never edits
consumers.  It is safe to use in a maintenance PR: without ``--apply`` it
only validates and reports the proposal.  Applying a proposal is an explicit
maintainer action; the normal CI workflow only runs the read-only checker.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
import tempfile
from pathlib import Path


def load_checker(path: Path):
    spec = importlib.util.spec_from_file_location("dsh_release_input_checker", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load checker: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def contains_key(value, wanted: str) -> bool:
    if isinstance(value, dict):
        return wanted in value or any(contains_key(item, wanted) for item in value.values())
    if isinstance(value, list):
        return any(contains_key(item, wanted) for item in value)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("proposal", type=Path, help="reviewed JSON proposal")
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="explicitly replace policy/release-inputs.json after validation",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    if args.proposal.is_symlink():
        print(f"FAIL: proposal must not be a symlink: {args.proposal}", file=sys.stderr)
        return 1
    proposal = args.proposal.resolve()
    target_path = root / "policy/release-inputs.json"
    if target_path.is_symlink():
        print(f"FAIL: target ledger must not be a symlink: {target_path}", file=sys.stderr)
        return 1
    target = target_path.resolve()
    checker = load_checker(root / "scripts/check-release-inputs.py")
    errors = checker.run(root, proposal, True)
    if errors:
        print("FAIL: release-input proposal rejected", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    document = checker.load_json(proposal)
    if contains_key(document, "exceptions"):
        print(
            "FAIL: vulnerability exceptions are not accepted by the updater; obtain owner review first",
            file=sys.stderr,
        )
        return 1
    if document.get("policy", {}).get("vulnerabilityExceptions") != "manual-review-required":
        print("FAIL: proposal does not preserve manual vulnerability review", file=sys.stderr)
        return 1

    print(f"PASS: validated release-input proposal {proposal}")
    if not args.apply:
        print("NOT APPLIED: rerun with --apply only after the consumer update is reviewed")
        return 0

    if proposal == target:
        print("FAIL: proposal already is the target ledger", file=sys.stderr)
        return 1
    target.parent.mkdir(parents=True, exist_ok=True)
    mode = target.stat().st_mode if target.exists() else 0o644
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=target.parent, prefix=f".{target.name}.", delete=False
        ) as handle:
            temporary = Path(handle.name)
            handle.write(proposal.read_text(encoding="utf-8"))
            handle.flush()
            os.fchmod(handle.fileno(), mode & 0o777)
        os.replace(temporary, target)
    except OSError as exc:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        print(f"FAIL: could not apply proposal: {exc}", file=sys.stderr)
        return 1
    print(f"APPLIED: {target}; run scripts/check-release-inputs.py to find consumer drift")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
