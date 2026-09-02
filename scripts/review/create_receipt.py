#!/usr/bin/env python3
"""Reviewer-only: sign an approval receipt with externally provisioned key custody."""

from __future__ import annotations

import argparse
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from candidate_identity import approval_registry_bytes, candidate_dirs, candidate_registry_bytes, load_candidate
from review_common import (
    COMMIT_NAMESPACE, ReviewError, atomic_write, canonical_json,
    git_root, private_key_path, require_active_reviewer, sha256_bytes, sign_envelope,
    require_trimmed_string,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--candidate-id", required=True)
    parser.add_argument("--reviewer-id", required=True)
    parser.add_argument("--scope", action="append", required=True)
    parser.add_argument("--validation", action="append", required=True)
    args = parser.parse_args()
    try:
        repo = git_root(args.repo)
        for field, values in (("scope", args.scope), ("validation", args.validation)):
            for index, value in enumerate(values):
                require_trimmed_string(value, f"{field}[{index}]")
        manifest, _ = load_candidate(repo, args.candidate_id)
        candidate_registry_bytes(repo, manifest)
        approval_registry = approval_registry_bytes(repo, manifest)
        with tempfile.TemporaryDirectory(prefix="duckpad-parent-registry-") as temporary:
            registry = Path(temporary) / "reviewers.json"
            registry.write_bytes(approval_registry)
            require_active_reviewer(
                registry_path=registry, reviewer_id=args.reviewer_id,
                role="independent_commit_reviewer", forbidden_ids={manifest["builder_id"]},
            )
        payload = {
            "schema_version": 1,
            "kind": "duckpad-commit-review",
            "candidate": manifest,
            "decision": "approved",
            "unresolved_blockers": 0,
            "unresolved_majors": 0,
            "scope": args.scope,
            "validation": args.validation,
            "issued_at": datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
        }
        envelope = sign_envelope(
            signed={"schema_version": 1, "namespace": COMMIT_NAMESPACE, "signer_id": args.reviewer_id, "payload": payload},
            private_key=private_key_path(repo, args.reviewer_id),
        )
        raw = canonical_json(envelope)
        receipt_sha = sha256_bytes(raw)
        _, _, receipts = candidate_dirs(repo)
        path = receipts / f"{args.candidate_id}.{receipt_sha}.json"
        atomic_write(path, raw, 0o400)
        print(path)
        return 0
    except (ReviewError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
