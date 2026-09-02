#!/usr/bin/env python3
"""Prepare, verify, and audit Duckpad's local signed commit receipts."""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path
from typing import Any

from candidate_identity import (
    ZERO, approval_registry_bytes, candidate_dirs, candidate_registry_bytes,
    load_candidate, prepare, recompute_current, validate_candidate_tree, validate_message,
)
from review_common import (
    COMMIT_NAMESPACE, ReviewError, allowed_signers_path, git_output, git_root,
    require_canonical_utc, require_exact_integer, require_exact_keys,
    require_trimmed_string, sha256_bytes, verify_envelope,
)


def validate_receipt_payload(payload: dict[str, Any], manifest: dict[str, Any]) -> None:
    require_exact_keys(payload, {
        "schema_version", "kind", "candidate", "decision", "unresolved_blockers",
        "unresolved_majors", "scope", "validation", "issued_at",
    }, "commit review payload")
    require_exact_integer(payload["schema_version"], "commit review schema_version", expected=1)
    if payload["kind"] != "duckpad-commit-review":
        raise ReviewError("commit review payload kind mismatch")
    if payload["candidate"] != manifest or payload["decision"] != "approved":
        raise ReviewError("receipt is not bound to this approved candidate")
    require_exact_integer(payload["unresolved_blockers"], "unresolved_blockers", expected=0)
    require_exact_integer(payload["unresolved_majors"], "unresolved_majors", expected=0)
    for field in ("scope", "validation"):
        values = payload[field]
        if not isinstance(values, list) or not values:
            raise ReviewError(f"receipt {field} must be a non-empty string array")
        for index, value in enumerate(values):
            require_trimmed_string(value, f"receipt {field}[{index}]")
    require_canonical_utc(payload["issued_at"])


def verify_receipt(repo: Path, identifier: str, *, current_index: bool) -> tuple[dict[str, Any], Path, Path]:
    manifest, message_path = load_candidate(repo, identifier)
    if current_index:
        recompute_current(repo, manifest, message_path)
    _, _, receipts = candidate_dirs(repo)
    matches = sorted(receipts.glob(f"{identifier}.*.json"))
    matches = [item for item in matches if len(item.name.split(".")) == 3]
    if len(matches) != 1:
        raise ReviewError("candidate must have exactly one sealed review receipt")
    receipt = matches[0]
    encoded_sha = receipt.name.split(".")[1]
    if sha256_bytes(receipt.read_bytes()) != encoded_sha:
        raise ReviewError("review receipt filename hash mismatch")
    candidate_registry_bytes(repo, manifest)
    approval_registry = approval_registry_bytes(repo, manifest)
    with tempfile.TemporaryDirectory(prefix="duckpad-parent-registry-") as temporary:
        registry = Path(temporary) / "reviewers.json"
        registry.write_bytes(approval_registry)
        payload, _, actual_sha = verify_envelope(
            envelope_path=receipt,
            registry_path=registry,
            allowed_signers=allowed_signers_path(repo),
            expected_namespace=COMMIT_NAMESPACE,
            required_role="independent_commit_reviewer",
            forbidden_ids={manifest["builder_id"]},
        )
    validate_receipt_payload(payload, manifest)
    if actual_sha != encoded_sha:
        raise ReviewError("verified receipt digest mismatch")
    return manifest, message_path, receipt


def commit_headers(repo: Path, oid: str) -> tuple[str, str, bytes]:
    tree = git_output(repo, "show", "-s", "--format=%T", oid).decode().strip()
    parents = git_output(repo, "show", "-s", "--format=%P", oid).decode().strip().split()
    if len(parents) > 1:
        raise ReviewError("review wrapper does not authorize merge commits")
    parent = parents[0] if parents else ZERO
    commit_object = git_output(repo, "cat-file", "commit", oid)
    try:
        _, message = commit_object.split(b"\n\n", 1)
    except ValueError as error:
        raise ReviewError("malformed Git commit object") from error
    validate_message(message)
    return tree, parent, message


def audit_commit(repo: Path, oid: str) -> None:
    _, _, receipts = candidate_dirs(repo)
    mappings = sorted(receipts.glob(f"committed/{oid}.*.*.json"))
    if len(mappings) != 1:
        raise ReviewError(f"commit {oid} has no unique immutable review mapping (--no-verify bypass detected)")
    mapping = mappings[0]
    parts = mapping.name.split(".")
    if len(parts) != 4:
        raise ReviewError("malformed committed receipt mapping")
    _, identifier, receipt_sha, extension = parts
    if extension != "json" or sha256_bytes(mapping.read_bytes()) != receipt_sha:
        raise ReviewError("committed receipt mapping hash mismatch")
    manifest, message_path = load_candidate(repo, identifier)
    tree, parent, message = commit_headers(repo, oid)
    validate_candidate_tree(repo, tree)
    if (tree, parent, sha256_bytes(message)) != (
        manifest["tree_oid"], manifest["parent_oid"], manifest["message_sha256"]
    ):
        raise ReviewError("commit bytes differ from reviewed candidate")
    candidate_registry_bytes(repo, manifest)
    approval_registry = approval_registry_bytes(repo, manifest)
    with tempfile.TemporaryDirectory(prefix="duckpad-parent-registry-") as temporary:
        registry = Path(temporary) / "reviewers.json"
        registry.write_bytes(approval_registry)
        payload, _, _ = verify_envelope(
            envelope_path=mapping, registry_path=registry, allowed_signers=allowed_signers_path(repo),
            expected_namespace=COMMIT_NAMESPACE, required_role="independent_commit_reviewer",
            forbidden_ids={manifest["builder_id"]},
        )
    validate_receipt_payload(payload, manifest)
    if sha256_bytes(message_path.read_bytes()) != manifest["message_sha256"]:
        raise ReviewError("preserved candidate message was mutated")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    sub = parser.add_subparsers(dest="command", required=True)
    make = sub.add_parser("prepare")
    make.add_argument("--message-file", type=Path, required=True)
    make.add_argument("--registry", type=Path)
    verify = sub.add_parser("verify")
    verify.add_argument("--candidate-id", required=True)
    audit = sub.add_parser("audit")
    audit.add_argument("--commit")
    audit.add_argument("--all", action="store_true")
    args = parser.parse_args()
    try:
        repo = git_root(args.repo)
        if args.command == "prepare":
            registry = args.registry or repo / "docs/parity/reviewer-identities.v1.json"
            manifest = prepare(repo, args.message_file, registry)
            print(manifest["candidate_id"])
        elif args.command == "verify":
            verify_receipt(repo, args.candidate_id, current_index=True)
            print(f"PASS: candidate {args.candidate_id} has an independent signed review")
        else:
            if args.all:
                raw = git_output(repo, "rev-list", "--all", check=False).decode().split()
                for oid in raw:
                    audit_commit(repo, oid)
                print(f"PASS: audited {len(raw)} commit(s)")
            else:
                oid = args.commit or "HEAD"
                resolved = git_output(repo, "rev-parse", "--verify", oid).decode().strip()
                audit_commit(repo, resolved)
                print(f"PASS: audited commit {resolved}")
        return 0
    except (ReviewError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
