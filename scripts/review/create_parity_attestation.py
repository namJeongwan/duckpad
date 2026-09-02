#!/usr/bin/env python3
"""Reviewer-only: sign a typed parity attestation with externally provisioned key custody."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from review_common import (
    PARITY_NAMESPACE, ReviewError, atomic_write, canonical_json, git_root, load_json,
    private_key_path, require_active_reviewer, sign_envelope,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--reviewer-id", required=True)
    parser.add_argument("--builder-id", action="append", required=True)
    parser.add_argument("--registry", type=Path)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        repo = git_root(args.repo)
        registry = (args.registry or repo / "docs/parity/reviewer-identities.v1.json").resolve()
        require_active_reviewer(
            registry_path=registry, reviewer_id=args.reviewer_id,
            role="independent_parity_reviewer", forbidden_ids=set(args.builder_id),
        )
        payload, _ = load_json(args.payload)
        if payload.get("kind") not in {"parity-evidence", "parity-reviewed-na"}:
            raise ReviewError("unsupported parity attestation payload kind")
        envelope = sign_envelope(
            signed={"schema_version": 1, "namespace": PARITY_NAMESPACE,
                    "signer_id": args.reviewer_id, "payload": payload},
            private_key=private_key_path(repo, args.reviewer_id),
        )
        atomic_write(args.output.resolve(), canonical_json(envelope), 0o444)
        print(args.output.resolve())
        return 0
    except (ReviewError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
