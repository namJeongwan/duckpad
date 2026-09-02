#!/usr/bin/env python3
"""Create exactly the reviewed commit, then preserve its immutable receipt mapping."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from candidate_identity import ZERO, candidate_dirs
from review_common import ReviewError, atomic_write, git_output, git_root, sha256_bytes
from verify_candidate import audit_commit, verify_receipt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--candidate-id", required=True)
    args = parser.parse_args()
    try:
        repo = git_root(args.repo)
        hooks = git_output(repo, "config", "--local", "--get", "core.hooksPath", check=False).decode().strip()
        if hooks != "scripts/review/hooks":
            raise ReviewError("Phase-0 review hooks are not installed")
        manifest, message_path, receipt = verify_receipt(repo, args.candidate_id, current_index=True)
        command = ["commit-tree", manifest["tree_oid"]]
        if manifest["parent_oid"] != ZERO:
            command += ["-p", manifest["parent_oid"]]
        command += ["-F", str(message_path)]
        oid = git_output(repo, *command).decode().strip()
        current_parent = git_output(repo, "rev-parse", "--verify", "HEAD", check=False).decode().strip() or ZERO
        if current_parent != manifest["parent_oid"]:
            raise ReviewError("branch advanced after candidate verification")
        symbolic = git_output(repo, "symbolic-ref", "-q", "HEAD", check=False).decode().strip()
        if not symbolic:
            raise ReviewError("detached HEAD commits are not supported by the local wrapper")
        if current_parent == ZERO:
            git_output(repo, "update-ref", symbolic, oid)
        else:
            git_output(repo, "update-ref", symbolic, oid, current_parent)
        raw = receipt.read_bytes()
        receipt_sha = sha256_bytes(raw)
        _, _, receipts = candidate_dirs(repo)
        mapping = receipts / "committed" / f"{oid}.{args.candidate_id}.{receipt_sha}.json"
        if mapping.exists():
            raise ReviewError("immutable commit receipt mapping already exists")
        atomic_write(mapping, raw, 0o400)
        receipt.unlink()
        audit_commit(repo, oid)
        print(oid)
        return 0
    except (ReviewError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
