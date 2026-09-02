#!/usr/bin/env python3
"""Create and verify exact staged-candidate identities."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from review_common import (
    ReviewError, atomic_write, git_common_dir, git_output, git_root, load_json,
    load_external_genesis_registry, provisioned_builder_identity, require_exact_integer,
    require_exact_keys, require_sha256, sha256_bytes,
)

MESSAGE_RE = re.compile(r"^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-z0-9._/-]+\))?!?: .{1,72}$")
ZERO = "ROOT"
FORBIDDEN_REFERENCE_COMPONENT = "notepad-plus-plus"
FORBIDDEN_README_PREFIX = "readme"


def validate_message(raw: bytes) -> bytes:
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as error:
        raise ReviewError("commit header/body must be English ASCII") from error
    if "\r" in text or not text.endswith("\n") or text.endswith("\n\n"):
        raise ReviewError("commit message must use LF and exactly one trailing newline")
    lines = text[:-1].split("\n")
    if not lines or MESSAGE_RE.fullmatch(lines[0]) is None:
        raise ReviewError("commit header must be English Conventional Commits format")
    if len(lines) > 1:
        body = lines[2:]
        if lines[1] != "" or not body or not body[0].strip() or not body[-1].strip():
            raise ReviewError("commit body must follow one blank separator and contain no empty paragraphs")
        if any(not current.strip() and not following.strip() for current, following in zip(body, body[1:])):
            raise ReviewError("commit body must not contain consecutive empty paragraphs")
    return raw


def parent_oid(repo: Path) -> str:
    result = git_output(repo, "rev-parse", "--verify", "HEAD", check=False).decode().strip()
    return result if result else ZERO


def index_diff(repo: Path) -> bytes:
    return git_output(repo, "diff", "--cached", "--binary", "--no-ext-diff", "--full-index")


def validate_candidate_tree(repo: Path, treeish: str) -> None:
    """Reject external reference trees and every Git submodule from a candidate."""
    raw = git_output(repo, "ls-tree", "-rz", "-r", "--full-tree", treeish)
    for record in raw.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, object_type, _ = metadata.split(b" ", 2)
            path = raw_path.decode("utf-8", errors="strict")
        except (ValueError, UnicodeDecodeError) as error:
            raise ReviewError("cannot parse staged tree entry") from error
        if mode == b"160000" or object_type == b"commit":
            raise ReviewError(f"staged tree contains forbidden gitlink: {path}")
        if any(component.casefold() == FORBIDDEN_REFERENCE_COMPONENT for component in path.split("/")):
            raise ReviewError(f"staged tree contains forbidden Notepad++ reference path: {path}")
        if path.rsplit("/", 1)[-1].casefold().startswith(FORBIDDEN_README_PREFIX):
            raise ReviewError(f"staged tree contains forbidden README name: {path}")


def candidate_id(tree: str, parent: str, diff_sha: str, message_sha: str) -> str:
    raw = b"DuckpadReviewCandidate/v1\0" + b"\0".join(
        value.encode("ascii") for value in (tree, parent, diff_sha, message_sha)
    ) + b"\0"
    return sha256_bytes(raw)


def candidate_dirs(repo: Path) -> tuple[Path, Path, Path]:
    common = git_common_dir(repo)
    return (
        common / "duckpad-review-candidates" / "v1",
        common / "duckpad-review-messages" / "v1",
        common / "duckpad-review-receipts" / "v1",
    )


def registry_bytes_from_tree(repo: Path, treeish: str, relative_path: str) -> bytes:
    result = git_output(repo, "show", f"{treeish}:{relative_path}", check=False)
    if not result:
        raise ReviewError(f"reviewer registry is absent from {treeish}")
    return result


def candidate_registry_bytes(repo: Path, manifest: dict[str, Any]) -> bytes:
    raw = registry_bytes_from_tree(repo, manifest["tree_oid"], manifest["registry_path"])
    if sha256_bytes(raw) != manifest["candidate_registry_sha256"]:
        raise ReviewError("candidate reviewer registry hash mismatch")
    return raw


def approval_registry_bytes(repo: Path, manifest: dict[str, Any]) -> bytes:
    source = manifest["approval_registry_source"]
    expected = "external-genesis-v1" if manifest["parent_oid"] == ZERO else manifest["parent_oid"]
    if source != expected:
        raise ReviewError("approval registry source does not match candidate parent")
    if manifest["parent_oid"] == ZERO:
        _, raw = load_external_genesis_registry(repo)
    else:
        raw = registry_bytes_from_tree(repo, manifest["parent_oid"], manifest["registry_path"])
    if sha256_bytes(raw) != manifest["approval_registry_sha256"]:
        raise ReviewError("parent-pinned approval registry hash mismatch")
    return raw


def prepare(repo: Path, message_file: Path, registry_path: Path) -> dict[str, Any]:
    repo = git_root(repo)
    builder_id = provisioned_builder_identity(repo)
    message = validate_message(message_file.read_bytes())
    if not index_diff(repo):
        raise ReviewError("staged candidate is empty")
    check = git_output(repo, "diff", "--cached", "--check", check=False)
    if check:
        raise ReviewError(check.decode(errors="replace").strip())
    tree = git_output(repo, "write-tree").decode().strip()
    validate_candidate_tree(repo, tree)
    parent = parent_oid(repo)
    diff_sha = sha256_bytes(index_diff(repo))
    message_sha = sha256_bytes(message)
    identifier = candidate_id(tree, parent, diff_sha, message_sha)
    registry_path = registry_path.resolve()
    relative_registry = registry_path.relative_to(repo).as_posix()
    registry_raw = registry_path.read_bytes()
    indexed_registry = registry_bytes_from_tree(repo, tree, relative_registry)
    if indexed_registry != registry_raw:
        raise ReviewError("reviewer registry bytes must be included unchanged in the staged tree")
    if parent == ZERO:
        _, approval_registry_raw = load_external_genesis_registry(repo)
        approval_registry_source = "external-genesis-v1"
    else:
        approval_registry_raw = registry_bytes_from_tree(repo, parent, relative_registry)
        approval_registry_source = parent
    manifest = {
        "schema_version": 1,
        "kind": "duckpad-review-candidate",
        "candidate_id": identifier,
        "builder_id": builder_id,
        "tree_oid": tree,
        "parent_oid": parent,
        "diff_sha256": diff_sha,
        "message_sha256": message_sha,
        "registry_path": relative_registry,
        "candidate_registry_sha256": sha256_bytes(indexed_registry),
        "approval_registry_source": approval_registry_source,
        "approval_registry_sha256": sha256_bytes(approval_registry_raw),
    }
    candidates, messages, receipts = candidate_dirs(repo)
    for directory in (candidates, messages, receipts):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_write(candidates / f"{identifier}.json", json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n")
    atomic_write(messages / f"{identifier}.txt", message)
    return manifest


def load_candidate(repo: Path, identifier: str) -> tuple[dict[str, Any], Path]:
    require_sha256(identifier, "candidate_id")
    candidates, messages, _ = candidate_dirs(repo)
    manifest, _ = load_json(candidates / f"{identifier}.json")
    require_exact_keys(manifest, {
        "schema_version", "kind", "candidate_id", "builder_id", "tree_oid", "parent_oid",
        "diff_sha256", "message_sha256", "registry_path", "candidate_registry_sha256",
        "approval_registry_source", "approval_registry_sha256",
    }, "candidate manifest")
    require_exact_integer(manifest["schema_version"], "candidate manifest schema_version", expected=1)
    if manifest["kind"] != "duckpad-review-candidate":
        raise ReviewError("candidate manifest schema or kind mismatch")
    if manifest["candidate_id"] != identifier:
        raise ReviewError("candidate manifest filename binding mismatch")
    return manifest, messages / f"{identifier}.txt"


def recompute_current(repo: Path, manifest: dict[str, Any], message_path: Path) -> None:
    tree = git_output(repo, "write-tree").decode().strip()
    validate_candidate_tree(repo, tree)
    parent = parent_oid(repo)
    message = validate_message(message_path.read_bytes())
    values = {
        "tree_oid": tree,
        "parent_oid": parent,
        "diff_sha256": sha256_bytes(index_diff(repo)),
        "message_sha256": sha256_bytes(message),
    }
    for field, value in values.items():
        if manifest[field] != value:
            raise ReviewError(f"candidate changed after review preparation: {field}")
    if candidate_id(tree, parent, values["diff_sha256"], values["message_sha256"]) != manifest["candidate_id"]:
        raise ReviewError("candidate identity recomputation failed")
