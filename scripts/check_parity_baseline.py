#!/usr/bin/env python3
"""Validate and score Duckpad's versioned Notepad++ parity baseline."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = ROOT / "docs/parity/notepad-plus-plus-command-baseline.v1.json"
DEFAULT_RECEIPT_VERIFIER = ROOT / "scripts/verify_parity_review_receipt.py"
DEFINE_RE = re.compile(r"^\s*#define\s+(IDM_[A-Za-z0-9_]+)\b")
SYMBOL_RE = re.compile(r"^IDM_[A-Za-z0-9_]+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_GATES = {f"G{number}" for number in range(1, 11)}
STATE_RATIOS = {
    "Missing": 0.0,
    "Partial-0.25": 0.25,
    "Partial-0.50": 0.5,
    "Partial-0.75": 0.75,
    "Full": 1.0,
}
GENESIS_REGISTRY_FILENAME = "genesis-reviewers.json"
RELEASE_GATE_POLICY = {
    "minimum_weighted_feature_parity": 90,
    "require_all_p0_full": True,
    "required_ux_gates": sorted(REQUIRED_GATES),
    "allow_pending_reviewed_na": False,
    "maximum_open_blocker_or_critical_defects": 0,
}


class BaselineError(Exception):
    pass


def reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number is forbidden: {value}")


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: Any) -> bytes:
    try:
        return (json.dumps(
            value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False,
        ) + "\n").encode("utf-8")
    except (TypeError, ValueError) as error:
        raise BaselineError(f"parity contract is not canonical JSON: {error}") from error


def parity_contract_sha256(baseline: dict[str, Any]) -> str:
    """Digest immutable parity rules while excluding implementation/evidence state."""
    features = [
        {key: value for key, value in feature.items() if key not in {"state", "evidence_ids"}}
        for feature in baseline.get("features", [])
    ]
    rules = [
        {key: value for key, value in rule.items() if key != "independent_review"}
        for rule in baseline.get("command_mapping_rules", [])
    ]
    gates = [
        {key: value for key, value in gate.items() if key not in {"status", "evidence_ids"}}
        for gate in baseline.get("ux_gates", [])
    ]
    contract = {
        "schema_version": 1,
        "baseline_version": baseline.get("baseline_version"),
        "source": baseline.get("source"),
        "implementation_states": baseline.get("implementation_states"),
        "categories": baseline.get("categories"),
        "features": features,
        "command_mapping_rules": rules,
        "ux_gates": gates,
        "release_gate_policy": baseline.get("release_gate_policy"),
    }
    return sha256_bytes(canonical_json(contract))


def resolve_approval_registry(
    *, baseline_path: Path, review_policy: dict[str, Any], review_trust_dir: Path,
    expected_parent_oid: str | None,
) -> tuple[bytes, str]:
    source = review_policy.get("approval_registry_source")
    if not isinstance(source, dict) or source.get("kind") not in {
        "external_genesis_v1", "parent_commit_v1",
    }:
        raise BaselineError("approval_registry_source must resolve external genesis or parent commit")
    if source["kind"] == "external_genesis_v1":
        if expected_parent_oid is not None:
            raise BaselineError("external genesis approval is valid only for a ROOT source commit")
        if set(source) != {"kind", "sha256"}:
            raise BaselineError("external genesis approval source fields are invalid")
        snapshot = review_trust_dir / GENESIS_REGISTRY_FILENAME
        sidecar = snapshot.with_suffix(".sha256")
        if (not snapshot.is_file() or snapshot.is_symlink() or not sidecar.is_file()
                or sidecar.is_symlink()):
            raise BaselineError("external genesis registry snapshot and digest are required")
        if (stat.S_IMODE(snapshot.stat().st_mode) & 0o222
                or stat.S_IMODE(sidecar.stat().st_mode) & 0o222):
            raise BaselineError("external genesis registry snapshot and digest must be read-only")
        fields = sidecar.read_text(encoding="ascii").strip().split()
        if len(fields) != 2 or fields[1] != snapshot.name:
            raise BaselineError("external genesis registry digest must bind its snapshot filename")
        sidecar_sha = require_sha256(fields[0], "external genesis sidecar sha256")
        raw = snapshot.read_bytes()
        actual = sha256_bytes(raw)
        if actual != sidecar_sha or actual != require_sha256(source["sha256"], "approval registry sha256"):
            raise BaselineError("external genesis registry snapshot digest mismatch")
        return raw, actual

    if set(source) != {"kind", "parent_oid", "registry_path", "sha256"}:
        raise BaselineError("parent commit approval source fields are invalid")
    if expected_parent_oid is None:
        raise BaselineError("ROOT source commit must use the external genesis approval registry")
    parent_oid = require_nonempty_string(source["parent_oid"], "approval parent_oid")
    if re.fullmatch(r"[0-9a-f]{40}", parent_oid) is None:
        raise BaselineError("approval parent_oid must be a full Git object ID")
    if parent_oid != expected_parent_oid:
        raise BaselineError("approval registry commit must be the source candidate's immediate parent")
    registry_path = require_nonempty_string(source["registry_path"], "approval registry_path")
    if Path(registry_path).is_absolute() or ".." in Path(registry_path).parts:
        raise BaselineError("approval registry_path escapes the parent tree")
    root_result = subprocess.run(
        ["git", "-C", str(baseline_path.parent), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    if root_result.returncode != 0:
        raise BaselineError("cannot resolve repository for parent-pinned approval registry")
    root = Path(root_result.stdout.strip()).resolve()
    object_type = subprocess.run(
        ["git", "-C", str(root), "cat-file", "-t", parent_oid], capture_output=True, text=True,
    )
    if object_type.returncode != 0 or object_type.stdout.strip() != "commit":
        raise BaselineError("approval parent_oid is not a committed parent")
    shown = subprocess.run(
        ["git", "-C", str(root), "show", f"{parent_oid}:{registry_path}"], capture_output=True,
    )
    if shown.returncode != 0:
        raise BaselineError("parent-pinned approval registry is absent")
    actual = sha256_bytes(shown.stdout)
    if actual != require_sha256(source["sha256"], "approval registry sha256"):
        raise BaselineError("parent-pinned approval registry digest mismatch")
    return shown.stdout, actual


def require_external_review_trust_dir(baseline_path: Path, supplied: Path) -> Path:
    result = subprocess.run(
        ["git", "-C", str(baseline_path.parent), "rev-parse", "--git-common-dir"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise BaselineError("release baseline must be inside a Git repository")
    common = Path(result.stdout.strip())
    if not common.is_absolute():
        common = baseline_path.parent / common
    expected = common.resolve() / "duckpad-review-trust/v1"
    supplied_absolute = supplied if supplied.is_absolute() else Path.cwd() / supplied
    if supplied_absolute.resolve() != expected:
        raise BaselineError("release trust must use $GIT_COMMON_DIR/duckpad-review-trust/v1")
    current = supplied_absolute
    while current != current.parent:
        if current.is_symlink():
            raise BaselineError("release trust path must not traverse a symlink")
        if current.resolve() == common.resolve():
            break
        current = current.parent
    return expected


def require_sha256(value: Any, field: str, *, allow_zero: bool = True) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise BaselineError(f"{field} must be a lowercase SHA-256 hex string")
    if not allow_zero and value == "0" * 64:
        raise BaselineError(f"{field} must not be the zero SHA-256")
    return value


def require_nonempty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BaselineError(f"{field} must be a non-empty string")
    return value


def require_strict_number(value: Any, field: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or type(value) not in (int, float):
        raise BaselineError(f"{field} must be a JSON number, not a coerced value")
    numeric = float(value)
    if not math.isfinite(numeric):
        raise BaselineError(f"{field} must be finite")
    if positive and numeric <= 0:
        raise BaselineError(f"{field} must be positive")
    return numeric


def require_strict_nonnegative_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or type(value) is not int:
        raise BaselineError(f"{field} must be a JSON integer")
    if value < 0:
        raise BaselineError(f"{field} must be non-negative")
    return value


def load_json(path: Path) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    try:
        value = json.loads(
            raw, object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_json_constant,
        )
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as error:
        raise BaselineError(f"invalid JSON in {path}: {error}") from error
    if not isinstance(value, dict):
        raise BaselineError("baseline root must be an object")
    return value, raw


def validate_sidecar(path: Path, raw: bytes) -> None:
    sidecar = path.with_suffix(".sha256")
    if not sidecar.is_file():
        raise BaselineError(f"missing checksum sidecar: {sidecar}")
    fields = sidecar.read_text(encoding="utf-8").strip().split()
    if len(fields) != 2 or fields[1] != path.name:
        raise BaselineError("checksum sidecar must contain '<sha256>  <baseline filename>'")
    expected = require_sha256(fields[0], "sidecar checksum")
    actual = sha256_bytes(raw)
    if expected != actual:
        raise BaselineError(f"baseline checksum mismatch: expected {expected}, got {actual}")


def extract_symbols(path: Path) -> list[dict[str, Any]]:
    symbols: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        match = DEFINE_RE.match(line)
        if match:
            symbols.append({"symbol": match.group(1), "line": line_number})
    return symbols


def load_symbol_fixture(path: Path) -> list[dict[str, Any]]:
    symbols: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        symbol = line.strip()
        if not symbol or SYMBOL_RE.fullmatch(symbol) is None:
            raise BaselineError(f"invalid symbol fixture entry at {path}:{line_number}")
        if symbol in seen:
            raise BaselineError(f"duplicate symbol fixture entry: {symbol}")
        seen.add(symbol)
        symbols.append({"symbol": symbol, "line": line_number})
    return symbols


def symbol_set_checksum(symbols: list[dict[str, Any]]) -> str:
    canonical = "".join(f"{item['symbol']}\n" for item in sorted(symbols, key=lambda item: item["symbol"]))
    return sha256_bytes(canonical.encode("utf-8"))


def rule_matches(rule: dict[str, Any], symbol: str) -> bool:
    match = rule.get("match")
    if not isinstance(match, dict):
        raise BaselineError(f"mapping rule {rule.get('id')} has no match object")
    if set(match) not in ({"symbols"}, {"regex"}):
        raise BaselineError(f"mapping rule {rule.get('id')} must use exactly one of symbols or regex")
    if "symbols" in match:
        values = match["symbols"]
        if (
            not isinstance(values, list)
            or not values
            or not all(isinstance(value, str) and SYMBOL_RE.fullmatch(value) for value in values)
            or len(values) != len(set(values))
        ):
            raise BaselineError(f"mapping rule {rule.get('id')} symbols must be unique IDM strings")
        return symbol in values
    pattern = match["regex"]
    if not isinstance(pattern, str) or not pattern:
        raise BaselineError(f"mapping rule {rule.get('id')} regex must be a non-empty string")
    try:
        return re.fullmatch(pattern, symbol) is not None
    except re.error as error:
        raise BaselineError(f"invalid regex in mapping rule {rule.get('id')}: {error}") from error


def load_receipt_verifier(path: Path):
    if not path.is_file():
        raise BaselineError(f"receipt verifier does not exist: {path}")
    spec = importlib.util.spec_from_file_location("duckpad_receipt_verifier", path)
    if spec is None or spec.loader is None:
        raise BaselineError(f"cannot load receipt verifier: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    verify_receipt = getattr(module, "verify_receipt", None)
    verify_evidence = getattr(module, "verify_evidence", None)
    if not callable(verify_receipt) or not callable(verify_evidence):
        raise BaselineError("attestation verifier must export verify_receipt and verify_evidence")
    return verify_receipt, verify_evidence


def map_symbols(
    symbols: list[dict[str, Any]],
    rules: list[dict[str, Any]],
    feature_ids: set[str],
    *,
    baseline_path: Path,
    baseline_version: str,
    candidate: dict[str, Any],
    review_policy: dict[str, Any],
    parity_contract_digest: str,
    approval_registry: tuple[bytes, str] | None,
    receipt_verifier_path: Path,
    review_trust_dir: Path | None,
) -> tuple[list[dict[str, Any]], list[str]]:
    rule_ids: list[str] = []
    for rule in rules:
        rule_id = require_nonempty_string(rule.get("id"), "mapping rule id")
        rule_ids.append(rule_id)
    if len(rule_ids) != len(set(rule_ids)):
        raise BaselineError("mapping rule IDs must be unique")
    rule_hits = {rule_id: 0 for rule_id in rule_ids}
    verify_receipt, _ = load_receipt_verifier(receipt_verifier_path)
    pending_na: list[str] = []
    mapped: list[dict[str, Any]] = []

    for source in symbols:
        symbol = source["symbol"]
        matches = [rule for rule in rules if rule_matches(rule, symbol)]
        if not matches:
            raise BaselineError(f"unmapped source command: {symbol} at line {source['line']}")
        if len(matches) > 1:
            raise BaselineError(
                f"ambiguous source command mapping for {symbol}: "
                + ", ".join(str(rule["id"]) for rule in matches)
            )
        rule = matches[0]
        rule_hits[rule["id"]] += 1
        disposition = rule.get("disposition")
        record = {**source, "mapping_rule": rule["id"], "disposition": disposition}
        if disposition == "feature":
            feature_id = rule.get("feature_id")
            if feature_id not in feature_ids:
                raise BaselineError(f"rule {rule['id']} references unknown feature {feature_id}")
            record["feature_id"] = feature_id
        elif disposition == "reviewed_na":
            require_nonempty_string(rule.get("rationale"), f"Reviewed-N/A rule {rule['id']} rationale")
            review = rule.get("independent_review")
            if not isinstance(review, dict) or review.get("status") not in {"pending", "approved"}:
                raise BaselineError(f"Reviewed-N/A rule {rule['id']} needs pending or approved review")
            if review["status"] == "pending":
                if any(review.get(field) is not None for field in ("reviewer_id", "receipt_path", "receipt_sha256")):
                    raise BaselineError(f"pending Reviewed-N/A rule {rule['id']} must not claim receipt fields")
                pending_na.append(rule["id"])
            else:
                receipt_path_value = require_nonempty_string(
                    review.get("receipt_path"), f"Reviewed-N/A rule {rule['id']} receipt_path"
                )
                receipt_path = _resolve_file(
                    baseline_path.parent, receipt_path_value,
                    f"Reviewed-N/A rule {rule['id']} receipt_path",
                )
                expected_receipt_sha = require_sha256(
                    review.get("receipt_sha256"), f"Reviewed-N/A rule {rule['id']} receipt_sha256"
                )
                if not receipt_path.is_file() or sha256_bytes(receipt_path.read_bytes()) != expected_receipt_sha:
                    raise BaselineError(f"Reviewed-N/A receipt missing or hash mismatch for {rule['id']}")
                reviewer_id = require_nonempty_string(
                    review.get("reviewer_id"), f"Reviewed-N/A rule {rule['id']} reviewer_id"
                )
                if review_trust_dir is None:
                    raise BaselineError("release attestations require a pre-provisioned reviewer trust directory")
                if approval_registry is None:
                    raise BaselineError("release attestations require a resolved approval registry")
                try:
                    verify_receipt(
                        receipt_path=receipt_path,
                        expected_receipt_sha256=expected_receipt_sha,
                        expected_reviewer_id=reviewer_id,
                        expected_rule_id=rule["id"],
                        expected_candidate_sha256=candidate["sha256"],
                        expected_baseline_version=baseline_version,
                        expected_rationale_sha256=sha256_bytes(rule["rationale"].encode("utf-8")),
                        expected_parity_contract_sha256=parity_contract_digest,
                        registry_bytes=approval_registry[0],
                        expected_registry_sha256=approval_registry[1],
                        forbidden_reviewer_ids=set(review_policy["candidate_builder_ids"]),
                        trust_dir=review_trust_dir,
                    )
                except Exception as error:
                    raise BaselineError(f"Reviewed-N/A receipt verification failed for {rule['id']}: {error}") from error
            record["independent_review"] = review
        elif disposition == "non_command":
            require_nonempty_string(rule.get("rationale"), f"non-command rule {rule['id']} rationale")
        else:
            raise BaselineError(f"rule {rule['id']} has invalid disposition {disposition}")
        mapped.append(record)

    unused = sorted(rule_id for rule_id, count in rule_hits.items() if count == 0)
    if unused:
        raise BaselineError(f"mapping rules matched no source symbols: {', '.join(unused)}")
    return mapped, sorted(set(pending_na))


def _resolve_file(base: Path, value: Any, field: str) -> Path:
    relative = require_nonempty_string(value, field)
    relative_path = Path(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise BaselineError(f"{field} escapes its artifact root")
    root = base.resolve()
    lexical = root / relative_path
    current = root
    for part in relative_path.parts:
        current = current / part
        if current.is_symlink():
            raise BaselineError(f"{field} must not traverse a symlink")
    path = lexical.resolve()
    if not path.is_file():
        raise BaselineError(f"{field} does not resolve to a regular file")
    return path


def _tree_sha256(root: Path) -> str:
    if not root.is_dir() or root.is_symlink():
        raise BaselineError("release source tree must be a non-symlink directory")
    records: list[bytes] = []
    for directory, names, files in os.walk(root, followlinks=False):
        current = Path(directory)
        for name in names:
            if (current / name).is_symlink():
                raise BaselineError("release source tree must not contain symlinks")
        for name in files:
            path = current / name
            if path.is_symlink() or not path.is_file():
                raise BaselineError("release source tree must contain only regular files")
            relative = path.relative_to(root).as_posix().encode("utf-8")
            mode = b"x" if path.stat().st_mode & 0o111 else b"-"
            records.append(relative + b"\0" + mode + b"\0" + sha256_bytes(path.read_bytes()).encode() + b"\n")
    if not records:
        raise BaselineError("release source tree must not be empty")
    return sha256_bytes(b"".join(sorted(records)))


def _committed_subtree_sha256(repo: Path, oid: str, git_path: str) -> str:
    listed = subprocess.run(
        ["git", "-C", str(repo), "ls-tree", "-rz", "-r", "--full-tree", oid, "--", git_path],
        capture_output=True,
    )
    if listed.returncode != 0:
        raise BaselineError("cannot enumerate release source commit subtree")
    prefix = git_path.rstrip("/").encode("utf-8") + b"/"
    records: list[bytes] = []
    for entry in listed.stdout.split(b"\0"):
        if not entry:
            continue
        try:
            metadata, path = entry.split(b"\t", 1)
            mode, object_type, object_id = metadata.split(b" ", 2)
        except ValueError as error:
            raise BaselineError("malformed release source commit tree") from error
        if object_type != b"blob" or mode not in {b"100644", b"100755"} or not path.startswith(prefix):
            raise BaselineError("release source commit subtree contains an unsupported entry")
        blob = subprocess.run(
            ["git", "-C", str(repo), "cat-file", "blob", object_id.decode("ascii")],
            capture_output=True,
        )
        if blob.returncode != 0:
            raise BaselineError("cannot read release source commit blob")
        relative = path[len(prefix):]
        executable = b"x" if mode == b"100755" else b"-"
        records.append(relative + b"\0" + executable + b"\0" + sha256_bytes(blob.stdout).encode() + b"\n")
    if not records:
        raise BaselineError("release source commit subtree must not be empty")
    return sha256_bytes(b"".join(sorted(records)))


def validate_candidate(
    candidate: dict[str, Any], baseline_path: Path, builders: list[str],
) -> tuple[str | None, str | None]:
    expected_keys = {"id", "status", "sha256", "manifest_path"}
    if set(candidate) != expected_keys:
        raise BaselineError("candidate must contain exactly id/status/sha256/manifest_path")
    if candidate["status"] == "not_built":
        if candidate["sha256"] != "0" * 64 or candidate["manifest_path"] is not None:
            raise BaselineError("not_built candidate must have zero hash and no release manifest")
        return None, None
    manifest_path = _resolve_file(baseline_path.parent, candidate["manifest_path"], "candidate.manifest_path")
    manifest, raw = load_json(manifest_path)
    if sha256_bytes(raw) != candidate["sha256"]:
        raise BaselineError("candidate.sha256 does not match the resolvable release manifest")
    exact = {"schema_version", "kind", "id", "builder_ids", "source_commit_oid",
             "source_tree", "build_artifacts"}
    if set(manifest) != exact or manifest["schema_version"] != 1 or manifest["kind"] != "duckpad-release-candidate":
        raise BaselineError("release candidate manifest schema or fields are invalid")
    if manifest["id"] != candidate["id"] or manifest["builder_ids"] != builders:
        raise BaselineError("release candidate identity or builders mismatch")
    source_commit_oid = require_nonempty_string(manifest["source_commit_oid"], "source_commit_oid")
    if re.fullmatch(r"[0-9a-f]{40}", source_commit_oid) is None:
        raise BaselineError("source_commit_oid must be a full Git commit ID")
    root_result = subprocess.run(
        ["git", "-C", str(baseline_path.parent), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    if root_result.returncode != 0:
        raise BaselineError("release baseline must be inside the source Git repository")
    repo = Path(root_result.stdout.strip()).resolve()
    head = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True,
    )
    if head.returncode != 0 or head.stdout.strip() != source_commit_oid:
        raise BaselineError("release source_commit_oid must equal the exact current HEAD")
    parents_result = subprocess.run(
        ["git", "-C", str(repo), "show", "-s", "--format=%P", source_commit_oid],
        capture_output=True, text=True,
    )
    parents = parents_result.stdout.strip().split() if parents_result.returncode == 0 else []
    if parents_result.returncode != 0 or len(parents) > 1:
        raise BaselineError("release source commit must exist and must not be a merge")
    source_parent_oid = parents[0] if parents else None
    source = manifest["source_tree"]
    if not isinstance(source, dict) or set(source) != {"path", "sha256"}:
        raise BaselineError("release source_tree must contain path and sha256")
    source_value = require_nonempty_string(source["path"], "source_tree.path")
    relative_source = Path(source_value)
    if relative_source.is_absolute() or ".." in relative_source.parts:
        raise BaselineError("release source tree escapes manifest root")
    source_path = manifest_path.parent.resolve()
    for part in relative_source.parts:
        source_path = source_path / part
        if source_path.is_symlink():
            raise BaselineError("release source tree must not traverse a symlink")
    source_path = source_path.resolve()
    source_sha = require_sha256(source["sha256"], "source_tree.sha256")
    if _tree_sha256(source_path) != source_sha:
        raise BaselineError("release source tree hash mismatch")
    try:
        git_source_path = source_path.relative_to(repo).as_posix()
    except ValueError as error:
        raise BaselineError("release source tree must be inside its source Git repository") from error
    if _committed_subtree_sha256(repo, source_commit_oid, git_source_path) != source_sha:
        raise BaselineError("release source tree is not the exact committed source subtree")
    artifacts = manifest["build_artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        raise BaselineError("release candidate needs at least one build artifact")
    seen: set[str] = set()
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {"id", "path", "sha256"}:
            raise BaselineError("build artifact fields are invalid")
        artifact_id = require_nonempty_string(artifact["id"], "build artifact id")
        if artifact_id in seen:
            raise BaselineError("duplicate build artifact id")
        seen.add(artifact_id)
        artifact_path = _resolve_file(manifest_path.parent, artifact["path"], "build artifact path")
        if sha256_bytes(artifact_path.read_bytes()) != require_sha256(artifact["sha256"], "build artifact sha256"):
            raise BaselineError(f"build artifact hash mismatch: {artifact_id}")
    return source_commit_oid, source_parent_oid


def validate_evidence(
    baseline: dict[str, Any], baseline_path: Path, candidate: dict[str, Any],
    baseline_version: str, review_policy: dict[str, Any], receipt_verifier_path: Path,
    review_trust_dir: Path | None, parity_contract_digest: str,
    approval_registry: tuple[bytes, str] | None,
) -> dict[str, dict[str, Any]]:
    records = baseline.get("evidence_records")
    if not isinstance(records, list):
        raise BaselineError("evidence_records must be an array")
    by_id: dict[str, dict[str, Any]] = {}
    _, verify_evidence = load_receipt_verifier(receipt_verifier_path)
    for record in records:
        if not isinstance(record, dict):
            raise BaselineError("each evidence record must be an object")
        evidence_id = require_nonempty_string(record.get("id"), "evidence id")
        if evidence_id in by_id:
            raise BaselineError(f"duplicate evidence id: {evidence_id}")
        if record.get("candidate_sha256") != candidate["sha256"]:
            raise BaselineError(f"evidence {evidence_id} is not bound to the candidate")
        exact = {"id", "candidate_sha256", "evidence_type", "subjects", "reviewer_id",
                 "attestation_path", "attestation_sha256"}
        if set(record) != exact:
            raise BaselineError(f"evidence {evidence_id} must use only typed signed-attestation fields")
        evidence_type = record["evidence_type"]
        if evidence_type not in {"automated", "manual"}:
            raise BaselineError(f"evidence {evidence_id} has invalid evidence_type")
        subjects = record["subjects"]
        if not isinstance(subjects, list) or not subjects:
            raise BaselineError(f"evidence {evidence_id} subjects must be non-empty")
        subject_keys: set[tuple[str, str]] = set()
        for subject in subjects:
            if not isinstance(subject, dict) or set(subject) != {"type", "id"} or subject["type"] not in {"feature", "ux_gate"}:
                raise BaselineError(f"evidence {evidence_id} has invalid typed subject")
            key = (subject["type"], require_nonempty_string(subject["id"], "evidence subject id"))
            if key in subject_keys:
                raise BaselineError(f"evidence {evidence_id} has duplicate subject")
            subject_keys.add(key)
        if review_trust_dir is None:
            raise BaselineError("release evidence requires a pre-provisioned reviewer trust directory")
        if approval_registry is None:
            raise BaselineError("release evidence requires a resolved approval registry")
        attestation = _resolve_file(baseline_path.parent, record["attestation_path"], "evidence attestation_path")
        expected_attestation_sha = require_sha256(record["attestation_sha256"], "attestation_sha256")
        reviewer_id = require_nonempty_string(record["reviewer_id"], "evidence reviewer_id")
        try:
            payload = verify_evidence(
                attestation_path=attestation, expected_attestation_sha256=expected_attestation_sha,
                expected_reviewer_id=reviewer_id, expected_evidence_id=evidence_id,
                expected_evidence_type=evidence_type, expected_candidate_sha256=candidate["sha256"],
                expected_baseline_version=baseline_version, expected_subjects=subjects,
                expected_parity_contract_sha256=parity_contract_digest,
                registry_bytes=approval_registry[0], expected_registry_sha256=approval_registry[1],
                forbidden_reviewer_ids=set(review_policy["candidate_builder_ids"]),
                trust_dir=review_trust_dir,
            )
        except Exception as error:
            raise BaselineError(f"evidence attestation verification failed for {evidence_id}: {error}") from error
        result_path = _resolve_file(baseline_path.parent, payload["result_artifact_path"], "result artifact path")
        if sha256_bytes(result_path.read_bytes()) != payload["result_artifact_sha256"]:
            raise BaselineError(f"typed result artifact hash mismatch: {evidence_id}")
        result, _ = load_json(result_path)
        required = {"schema_version", "kind", "candidate_sha256", "parity_contract_sha256",
                    "evidence_id", "subjects", "status"}
        if evidence_type == "automated":
            required |= {"command", "exit_code"}
        else:
            required |= {"checklist"}
        if (set(result) != required or isinstance(result["schema_version"], bool)
                or result["schema_version"] != 1):
            raise BaselineError(f"typed result artifact fields are invalid: {evidence_id}")
        expected_kind = "duckpad-machine-result" if evidence_type == "automated" else "duckpad-manual-result"
        if (result["kind"] != expected_kind or result["status"] != "pass"
                or result["candidate_sha256"] != candidate["sha256"]
                or result["parity_contract_sha256"] != parity_contract_digest
                or result["evidence_id"] != evidence_id or result["subjects"] != subjects):
            raise BaselineError(f"typed result artifact binding failed: {evidence_id}")
        if evidence_type == "automated" and (
            not isinstance(result["command"], list) or not result["command"]
            or isinstance(result["exit_code"], bool) or type(result["exit_code"]) is not int
            or result["exit_code"] != 0
        ):
            raise BaselineError(f"machine result must record a passing command: {evidence_id}")
        if evidence_type == "manual" and (not isinstance(result["checklist"], list) or not result["checklist"]):
            raise BaselineError(f"manual result must record a non-empty checklist: {evidence_id}")
        by_id[evidence_id] = record
    return by_id


def validate_contract_evidence(
    contract_id: str,
    state: str,
    evidence_ids: Any,
    evidence_by_id: dict[str, dict[str, Any]],
) -> None:
    if not isinstance(evidence_ids, list) or not all(isinstance(item, str) for item in evidence_ids):
        raise BaselineError(f"{contract_id} evidence_ids must be a string array")
    if len(evidence_ids) != len(set(evidence_ids)):
        raise BaselineError(f"{contract_id} evidence_ids must be unique")
    unknown = sorted(set(evidence_ids) - set(evidence_by_id))
    if unknown:
        raise BaselineError(f"{contract_id} references unknown evidence: {', '.join(unknown)}")
    if state == "Missing" and evidence_ids:
        raise BaselineError(f"Missing contract {contract_id} must not claim passing evidence")
    if state != "Missing" and not evidence_ids:
        raise BaselineError(f"non-Missing contract {contract_id} needs candidate-bound evidence")
    expected_subject = {"type": "ux_gate" if contract_id.startswith("G") else "feature", "id": contract_id}
    for evidence_id in evidence_ids:
        if expected_subject not in evidence_by_id[evidence_id]["subjects"]:
            raise BaselineError(f"evidence {evidence_id} is not signed for subject {contract_id}")
    if state == "Full":
        kinds = {evidence_by_id[evidence_id]["evidence_type"] for evidence_id in evidence_ids}
        if kinds != {"automated", "manual"}:
            raise BaselineError(f"Full contract {contract_id} needs automated and manual evidence")


def validate_workflow_fixture(
    source: dict[str, Any], baseline_path: Path
) -> list[dict[str, Any]]:
    fixture_value = require_nonempty_string(
        source.get("workflow_fixture_path"), "source.workflow_fixture_path"
    )
    fixture_path = (baseline_path.parent / fixture_value).resolve()
    if not fixture_path.is_file():
        raise BaselineError(f"frozen workflow fixture does not exist: {fixture_value}")
    expected_sha = require_sha256(
        source.get("workflow_fixture_sha256"), "source.workflow_fixture_sha256"
    )
    fixture, raw = load_json(fixture_path)
    if sha256_bytes(raw) != expected_sha:
        raise BaselineError("frozen workflow fixture checksum changed")
    validate_sidecar(fixture_path, raw)
    if fixture.get("schema_version") != 1:
        raise BaselineError("unsupported frozen workflow fixture schema")
    if fixture.get("source_commit") != source.get("commit"):
        raise BaselineError("frozen workflow fixture source commit mismatch")

    fixture_surfaces = fixture.get("surfaces")
    if not isinstance(fixture_surfaces, list) or not fixture_surfaces:
        raise BaselineError("frozen workflow fixture surfaces must be non-empty")
    actual_surfaces = [
        {field: surface.get(field) for field in ("id", "path", "sha256")}
        for surface in source["workflow_surfaces"]
    ]
    if fixture_surfaces != actual_surfaces:
        raise BaselineError("baseline workflow surfaces differ from the frozen fixture")

    frozen = fixture.get("workflows")
    if not isinstance(frozen, list) or not frozen:
        raise BaselineError("frozen workflow inventory must be non-empty")
    frozen_by_id: dict[str, dict[str, Any]] = {}
    frozen_ownership: set[tuple[str, str]] = set()
    for record in frozen:
        if not isinstance(record, dict):
            raise BaselineError("frozen workflow record must be an object")
        workflow_id = require_nonempty_string(record.get("id"), "frozen workflow id")
        if workflow_id in frozen_by_id:
            raise BaselineError(f"duplicate frozen workflow ID: {workflow_id}")
        require_nonempty_string(record.get("surface_id"), f"frozen workflow {workflow_id} surface")
        require_nonempty_string(record.get("feature_id"), f"frozen workflow {workflow_id} feature")
        selector = require_nonempty_string(record.get("selector"), f"frozen workflow {workflow_id} selector")
        occurrences = require_strict_nonnegative_integer(
            record.get("expected_occurrences"), f"frozen workflow {workflow_id} expected_occurrences"
        )
        if occurrences == 0:
            raise BaselineError(f"frozen workflow {workflow_id} must expect at least one occurrence")
        ownership = (record["surface_id"], selector)
        if ownership in frozen_ownership:
            raise BaselineError(f"duplicate frozen selector ownership: {ownership}")
        frozen_ownership.add(ownership)
        frozen_by_id[workflow_id] = record

    actual_by_id: dict[str, dict[str, Any]] = {}
    actual_ownership: set[tuple[str, str]] = set()
    for workflow in source["workflow_inventory"]:
        workflow_id = workflow["id"]
        selectors = workflow["selectors"]
        if len(selectors) != 1:
            raise BaselineError(f"workflow {workflow_id} must own exactly one frozen selector")
        ownership = (workflow["surface_id"], selectors[0])
        if ownership in actual_ownership:
            raise BaselineError(f"duplicate workflow selector ownership: {ownership}")
        actual_ownership.add(ownership)
        actual_by_id[workflow_id] = {
            "id": workflow_id,
            "surface_id": workflow["surface_id"],
            "feature_id": workflow["feature_id"],
            "selector": selectors[0],
            "expected_occurrences": require_strict_nonnegative_integer(
                workflow.get("expected_occurrences"),
                f"workflow {workflow_id} expected_occurrences",
            ),
        }
        if actual_by_id[workflow_id]["expected_occurrences"] == 0:
            raise BaselineError(f"workflow {workflow_id} must expect at least one occurrence")

    missing = sorted(set(frozen_by_id) - set(actual_by_id))
    extra = sorted(set(actual_by_id) - set(frozen_by_id))
    if missing or extra:
        raise BaselineError(f"workflow inventory differs from frozen fixture: missing={missing}, extra={extra}")
    for workflow_id, frozen_record in frozen_by_id.items():
        expected = {
            field: frozen_record[field]
            for field in ("id", "surface_id", "feature_id", "selector", "expected_occurrences")
        }
        if actual_by_id[workflow_id] != expected:
            raise BaselineError(f"workflow {workflow_id} differs from its frozen identity")
    return frozen


def validate_integration_reference(
    source: dict[str, Any], integration_reference: Path, expected_symbols: list[dict[str, Any]],
    frozen_workflows: list[dict[str, Any]],
) -> None:
    if not (integration_reference / ".git").is_dir():
        raise BaselineError(f"integration reference is not a Git repository: {integration_reference}")
    def require_clean(when: str) -> None:
        try:
            dirty = subprocess.run(
                ["git", "status", "--porcelain", "--untracked-files=all"],
                cwd=integration_reference, check=True, capture_output=True, text=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            raise BaselineError(f"cannot audit integration reference cleanliness: {error}") from error
        if dirty:
            raise BaselineError(f"integration reference must be clean {when}")

    require_clean("before direct audit")
    try:
        actual_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=integration_reference,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise BaselineError(f"cannot resolve integration reference commit: {error}") from error
    if actual_commit != source["commit"]:
        raise BaselineError(f"source commit changed: expected {source['commit']}, got {actual_commit}")
    header_path = integration_reference / source["header_path"]
    if not header_path.is_file() or sha256_bytes(header_path.read_bytes()) != source["file_sha256"]:
        raise BaselineError("pinned source command header missing or changed")
    actual_symbols = extract_symbols(header_path)
    if [item["symbol"] for item in actual_symbols] != [item["symbol"] for item in expected_symbols]:
        raise BaselineError("integration source command inventory drifted from the versioned fixture")
    surface_text: dict[str, str] = {}
    for surface in source["workflow_surfaces"]:
        surface_path = integration_reference / surface["path"]
        if not surface_path.is_file() or sha256_bytes(surface_path.read_bytes()) != surface["sha256"]:
            raise BaselineError(f"workflow surface missing or changed: {surface['id']}")
        surface_text[surface["id"]] = surface_path.read_text(encoding="utf-8-sig")
    occupied: dict[str, list[tuple[int, int, str]]] = {surface_id: [] for surface_id in surface_text}
    for workflow in frozen_workflows:
        selector = workflow["selector"]
        try:
            matches = list(re.finditer(selector, surface_text[workflow["surface_id"]], re.MULTILINE))
        except re.error as error:
            raise BaselineError(f"invalid workflow selector {workflow['id']}: {error}") from error
        if len(matches) != workflow["expected_occurrences"]:
            raise BaselineError(
                f"workflow occurrence drift {workflow['id']}: expected "
                f"{workflow['expected_occurrences']}, got {len(matches)}"
            )
        for match in matches:
            span = match.span()
            for other_start, other_end, other_id in occupied[workflow["surface_id"]]:
                if span[0] < other_end and other_start < span[1]:
                    raise BaselineError(
                        f"overlapping workflow selector ownership: {workflow['id']} and {other_id}"
                    )
            occupied[workflow["surface_id"]].append((span[0], span[1], workflow["id"]))
    final_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=integration_reference,
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    if final_commit != source["commit"]:
        raise BaselineError("integration reference HEAD changed during audit")
    require_clean("after direct audit")


def validate_and_calculate(
    path: Path,
    *,
    integration_reference: Path | None = None,
    receipt_verifier_path: Path = DEFAULT_RECEIPT_VERIFIER,
    review_trust_dir: Path | None = None,
    check_sidecar: bool = True,
) -> dict[str, Any]:
    baseline, raw = load_json(path)
    if check_sidecar:
        validate_sidecar(path, raw)
    if isinstance(baseline.get("schema_version"), bool) or baseline.get("schema_version") != 3:
        raise BaselineError("unsupported schema_version; expected 3")
    baseline_version = require_nonempty_string(baseline.get("baseline_version"), "baseline_version")
    declared_contract_digest = require_sha256(
        baseline.get("parity_contract_sha256"), "parity_contract_sha256", allow_zero=False,
    )
    contract_digest = parity_contract_sha256(baseline)
    if declared_contract_digest != contract_digest:
        raise BaselineError("parity contract digest mismatch")

    release_policy = baseline.get("release_gate_policy")

    states = baseline.get("implementation_states")
    if not isinstance(states, dict) or set(states) != set(STATE_RATIOS):
        raise BaselineError("implementation_states must contain exactly the normative five states")
    for name, ratio in STATE_RATIOS.items():
        value = require_strict_number(states[name], f"implementation_states.{name}")
        if value != ratio:
            raise BaselineError(f"implementation_states.{name} must equal {ratio}")

    candidate = baseline.get("candidate")
    if not isinstance(candidate, dict) or candidate.get("status") not in {"not_built", "release_candidate"}:
        raise BaselineError("candidate must have not_built or release_candidate status")
    require_nonempty_string(candidate.get("id"), "candidate.id")
    require_sha256(candidate.get("sha256"), "candidate.sha256", allow_zero=candidate["status"] == "not_built")
    if candidate["status"] == "release_candidate" and candidate["sha256"] == "0" * 64:
        raise BaselineError("release candidate hash must not be zero")

    review_policy = baseline.get("review_policy")
    if not isinstance(review_policy, dict):
        raise BaselineError("review_policy is required")
    if set(review_policy) != {
        "reviewer_registry_path", "reviewer_registry_sha256", "reviewer_trust_model",
        "reviewer_onboarding", "candidate_builder_ids", "approval_registry_source",
    }:
        raise BaselineError("review_policy fields are invalid")
    if review_policy.get("reviewer_trust_model") != "preprovisioned-local-v1":
        raise BaselineError("reviewer_trust_model must require pre-provisioned local trust")
    if review_policy.get("reviewer_onboarding") != "parent-pinned-two-step":
        raise BaselineError("reviewer_onboarding must be parent-pinned and two-step")
    require_nonempty_string(review_policy.get("reviewer_registry_path"), "reviewer_registry_path")
    require_sha256(review_policy.get("reviewer_registry_sha256"), "reviewer_registry_sha256")
    builders = review_policy.get("candidate_builder_ids")
    if not isinstance(builders, list) or not builders or not all(isinstance(item, str) and item for item in builders):
        raise BaselineError("candidate_builder_ids must be a non-empty string array")
    if len(builders) != len(set(builders)):
        raise BaselineError("candidate_builder_ids must be unique")
    registry_path = _resolve_file(path.parent, review_policy["reviewer_registry_path"], "reviewer_registry_path")
    if sha256_bytes(registry_path.read_bytes()) != review_policy["reviewer_registry_sha256"]:
        raise BaselineError("versioned reviewer registry missing or checksum mismatch")
    registry, _ = load_json(registry_path)
    if registry.get("schema_version") != 2 or not isinstance(registry.get("identities"), list):
        raise BaselineError("versioned reviewer registry must use schema 2")
    _, source_parent_oid = validate_candidate(candidate, path, builders)
    approval_source = review_policy.get("approval_registry_source")
    if not isinstance(approval_source, dict):
        raise BaselineError("approval_registry_source is required")
    approval_registry: tuple[bytes, str] | None = None
    if candidate["status"] == "release_candidate":
        if review_trust_dir is None:
            raise BaselineError("release candidate requires a pre-provisioned reviewer trust directory")
        review_trust_dir = require_external_review_trust_dir(path, review_trust_dir)
        approval_registry = resolve_approval_registry(
            baseline_path=path, review_policy=review_policy,
            review_trust_dir=review_trust_dir,
            expected_parent_oid=source_parent_oid,
        )
    elif approval_source.get("kind") == "external_genesis_v1":
        if set(approval_source) != {"kind", "sha256"}:
            raise BaselineError("external genesis approval source fields are invalid")
        require_sha256(approval_source.get("sha256"), "approval registry sha256")
    elif approval_source.get("kind") == "parent_commit_v1":
        if set(approval_source) != {"kind", "parent_oid", "registry_path", "sha256"}:
            raise BaselineError("parent commit approval source fields are invalid")
        require_sha256(approval_source.get("sha256"), "approval registry sha256")
    else:
        raise BaselineError("approval_registry_source must be external genesis or parent commit")

    categories = baseline.get("categories")
    if not isinstance(categories, list) or not categories:
        raise BaselineError("categories must be a non-empty array")
    category_weights: dict[str, float] = {}
    for category in categories:
        category_id = require_nonempty_string(category.get("id"), "category id")
        if category_id in category_weights:
            raise BaselineError("category IDs must be unique")
        category_weights[category_id] = require_strict_number(
            category.get("weight"), f"category {category_id} weight", positive=True
        )
    if not math.isclose(sum(category_weights.values()), 100.0, rel_tol=0, abs_tol=1e-9):
        raise BaselineError("category weights must sum to 100")

    evidence_by_id = validate_evidence(
        baseline, path, candidate, baseline_version, review_policy,
        receipt_verifier_path, review_trust_dir, contract_digest, approval_registry,
    )
    if release_policy != RELEASE_GATE_POLICY:
        raise BaselineError("release_gate_policy must equal the normative release/defect policy")
    features = baseline.get("features")
    if not isinstance(features, list) or not features:
        raise BaselineError("features must be a non-empty array")
    feature_by_id: dict[str, dict[str, Any]] = {}
    for feature in features:
        feature_id = require_nonempty_string(feature.get("id"), "feature id")
        if feature_id in feature_by_id:
            raise BaselineError("feature IDs must be unique")
        if feature.get("category") not in category_weights:
            raise BaselineError(f"feature {feature_id} has unknown category")
        if feature.get("priority") not in {"P0", "P1", "P2"}:
            raise BaselineError(f"feature {feature_id} has invalid priority")
        state = feature.get("state")
        if state not in STATE_RATIOS:
            raise BaselineError(f"feature {feature_id} has invalid implementation state")
        require_nonempty_string(feature.get("owner"), f"feature {feature_id} owner")
        acceptance = feature.get("acceptance")
        if not isinstance(acceptance, list) or not acceptance or not all(isinstance(item, str) and item.strip() for item in acceptance):
            raise BaselineError(f"feature {feature_id} needs explicit acceptance statements")
        validate_contract_evidence(feature_id, state, feature.get("evidence_ids"), evidence_by_id)
        feature_by_id[feature_id] = feature
    p0_features = [feature for feature in features if feature["priority"] == "P0"]
    if not p0_features:
        raise BaselineError("P0 feature set must be non-vacuous")

    source = baseline.get("source")
    if not isinstance(source, dict):
        raise BaselineError("source object is required")
    require_nonempty_string(source.get("commit"), "source.commit")
    require_nonempty_string(source.get("header_path"), "source.header_path")
    require_sha256(source.get("file_sha256"), "source.file_sha256")
    fixture_path_value = require_nonempty_string(source.get("symbol_fixture_path"), "source.symbol_fixture_path")
    fixture_path = (path.parent / fixture_path_value).resolve()
    if not fixture_path.is_file():
        raise BaselineError(f"versioned symbol fixture does not exist: {fixture_path_value}")
    fixture_sha = require_sha256(source.get("symbol_fixture_sha256"), "source.symbol_fixture_sha256")
    if sha256_bytes(fixture_path.read_bytes()) != fixture_sha:
        raise BaselineError("versioned symbol fixture checksum changed")
    symbols = load_symbol_fixture(fixture_path)
    expected_count = require_strict_nonnegative_integer(source.get("active_symbol_count"), "active_symbol_count")
    if expected_count != len(symbols) or source.get("active_symbol_set_sha256") != symbol_set_checksum(symbols):
        raise BaselineError("versioned symbol fixture count or set checksum mismatch")

    surfaces = source.get("workflow_surfaces")
    workflows = source.get("workflow_inventory")
    if not isinstance(surfaces, list) or not surfaces or not isinstance(workflows, list) or not workflows:
        raise BaselineError("workflow surfaces and inventory must be non-empty arrays")
    surface_ids: set[str] = set()
    for surface in surfaces:
        surface_id = require_nonempty_string(surface.get("id"), "workflow surface id")
        if surface_id in surface_ids:
            raise BaselineError("workflow surface IDs must be unique")
        surface_ids.add(surface_id)
        require_nonempty_string(surface.get("path"), f"surface {surface_id} path")
        require_sha256(surface.get("sha256"), f"surface {surface_id} sha256")
        require_nonempty_string(surface.get("role"), f"surface {surface_id} role")
    workflow_ids: set[str] = set()
    workflow_feature_ids: set[str] = set()
    used_surface_ids: set[str] = set()
    for workflow in workflows:
        workflow_id = require_nonempty_string(workflow.get("id"), "workflow id")
        if workflow_id in workflow_ids:
            raise BaselineError("workflow IDs must be unique")
        workflow_ids.add(workflow_id)
        if workflow.get("surface_id") not in surface_ids:
            raise BaselineError(f"workflow {workflow_id} has unknown surface")
        used_surface_ids.add(workflow["surface_id"])
        feature_id = workflow.get("feature_id")
        if feature_id not in feature_by_id:
            raise BaselineError(f"unmapped workflow ID {workflow_id}: unknown feature {feature_id}")
        workflow_feature_ids.add(feature_id)
        selectors = workflow.get("selectors")
        if not isinstance(selectors, list) or not selectors or not all(isinstance(item, str) and item for item in selectors):
            raise BaselineError(f"workflow {workflow_id} needs selectors")
        for selector in selectors:
            try:
                re.compile(selector)
            except re.error as error:
                raise BaselineError(f"invalid workflow selector {workflow_id}: {error}") from error
        require_nonempty_string(workflow.get("acceptance"), f"workflow {workflow_id} acceptance")
    if used_surface_ids != surface_ids:
        raise BaselineError(f"workflow surfaces lack enumerated behaviors: {sorted(surface_ids - used_surface_ids)}")
    frozen_workflows = validate_workflow_fixture(source, path)

    rules = baseline.get("command_mapping_rules")
    if not isinstance(rules, list) or not rules:
        raise BaselineError("command_mapping_rules must be a non-empty array")
    mapped, pending_na = map_symbols(
        symbols,
        rules,
        set(feature_by_id),
        baseline_path=path,
        baseline_version=baseline_version,
        candidate=candidate,
        review_policy=review_policy,
        parity_contract_digest=contract_digest,
        approval_registry=approval_registry,
        receipt_verifier_path=receipt_verifier_path,
        review_trust_dir=review_trust_dir,
    )
    command_feature_ids = {item["feature_id"] for item in mapped if item["disposition"] == "feature"}
    missing_source_mapping = sorted(set(feature_by_id) - command_feature_ids - workflow_feature_ids)
    if missing_source_mapping:
        raise BaselineError(f"features lack a command or stable workflow mapping: {', '.join(missing_source_mapping)}")

    if integration_reference is not None:
        validate_integration_reference(source, integration_reference.resolve(), symbols, frozen_workflows)

    gates = baseline.get("ux_gates")
    if not isinstance(gates, list):
        raise BaselineError("ux_gates must be an array")
    gate_ids = [gate.get("id") for gate in gates if isinstance(gate, dict)]
    if len(gates) != 10 or set(gate_ids) != REQUIRED_GATES or len(gate_ids) != len(set(gate_ids)):
        raise BaselineError("ux_gates must contain exactly G1 through G10 once each")
    for gate in gates:
        gate_id = gate["id"]
        if gate.get("status") not in {"Missing", "Pass"}:
            raise BaselineError(f"UX gate {gate_id} has invalid status")
        require_nonempty_string(gate.get("owner"), f"UX gate {gate_id} owner")
        require_nonempty_string(gate.get("scenario"), f"UX gate {gate_id} scenario")
        acceptance = gate.get("acceptance")
        if not isinstance(acceptance, list) or not acceptance or not all(isinstance(item, str) and item.strip() for item in acceptance):
            raise BaselineError(f"UX gate {gate_id} needs acceptance statements")
        gate_state = "Full" if gate["status"] == "Pass" else "Missing"
        validate_contract_evidence(gate_id, gate_state, gate.get("evidence_ids"), evidence_by_id)

    category_scores: dict[str, float] = {}
    for category_id, weight in category_weights.items():
        category_features = [feature for feature in features if feature["category"] == category_id]
        if not category_features:
            raise BaselineError(f"category {category_id} has no scoring features")
        ratio = sum(STATE_RATIOS[feature["state"]] for feature in category_features) / len(category_features)
        category_scores[category_id] = weight * ratio

    critical_open = require_strict_nonnegative_integer(
        baseline.get("open_blocker_or_critical_defects"), "open_blocker_or_critical_defects"
    )
    weighted_score = sum(category_scores.values())
    p0_full = all(feature["state"] == "Full" for feature in p0_features)
    gates_pass = all(gate["status"] == "Pass" for gate in gates)
    release_pass = (
        candidate["status"] == "release_candidate"
        and weighted_score >= release_policy["minimum_weighted_feature_parity"]
        and p0_full
        and gates_pass
        and not pending_na
        and critical_open <= release_policy["maximum_open_blocker_or_critical_defects"]
    )
    return {
        "baseline_version": baseline_version,
        "baseline_sha256": sha256_bytes(raw),
        "parity_contract_sha256": contract_digest,
        "source_symbol_count": len(symbols),
        "workflow_surface_count": len(surfaces),
        "workflow_count": len(workflows),
        "mapped_feature_commands": sum(item["disposition"] == "feature" for item in mapped),
        "reviewed_na_commands": sum(item["disposition"] == "reviewed_na" for item in mapped),
        "non_command_symbols": sum(item["disposition"] == "non_command" for item in mapped),
        "pending_reviewed_na_rules": pending_na,
        "scoring_feature_count": len(features),
        "category_scores": category_scores,
        "weighted_feature_parity": weighted_score,
        "p0_full": p0_full,
        "ux_gates_pass": gates_pass,
        "open_blocker_or_critical_defects": critical_open,
        "integration_reference_audited": integration_reference is not None,
        "release_pass": release_pass,
        "command_map": mapped,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--report", action="store_true", help="emit the exhaustive source-command map")
    parser.add_argument("--require-release-pass", action="store_true")
    parser.add_argument("--integration-reference", type=Path)
    parser.add_argument("--review-trust-dir", type=Path)
    args = parser.parse_args(argv)
    try:
        result = validate_and_calculate(
            args.baseline.resolve(),
            integration_reference=args.integration_reference,
            review_trust_dir=args.review_trust_dir.resolve() if args.review_trust_dir else None,
        )
    except (BaselineError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    output = result if args.report else {key: value for key, value in result.items() if key != "command_map"}
    print(json.dumps(output, indent=2, ensure_ascii=False, sort_keys=True))
    if args.require_release_pass and not result["release_pass"]:
        print("FAIL: validated baseline does not yet meet the release parity gate", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
