#!/usr/bin/env python3
"""Shared standard-library helpers for Duckpad's signed review protocol."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any


COMMIT_NAMESPACE = "duckpad-commit-review-v1"
PARITY_NAMESPACE = "duckpad-parity-attestation-v1"
IDENTITY_RE = re.compile(r"^/[A-Za-z0-9._/-]+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CANONICAL_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$")
GENESIS_REGISTRY_FILENAME = "genesis-reviewers.json"
PUBLIC_KEY_RE = re.compile(r"^(ssh-ed25519) ([A-Za-z0-9+/]+={0,3})$")
ROLE_NAMESPACES = {
    "independent_commit_reviewer": COMMIT_NAMESPACE,
    "independent_parity_reviewer": PARITY_NAMESPACE,
}


class ReviewError(Exception):
    """Raised for a fail-closed review protocol violation."""


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def load_json(path: Path) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(
            raw,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_constant,
        )
    except (OSError, json.JSONDecodeError, UnicodeDecodeError, ValueError) as error:
        raise ReviewError(f"invalid JSON at {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReviewError(f"{path} must contain one JSON object")
    return value, raw


def canonical_json(value: Any) -> bytes:
    try:
        return (
            json.dumps(
                value,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise ReviewError(f"value is not canonical JSON: {error}") from error


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def require_exact_keys(value: dict[str, Any], keys: set[str], field: str) -> None:
    actual = set(value)
    if actual != keys:
        raise ReviewError(
            f"{field} keys differ: missing={sorted(keys - actual)}, extra={sorted(actual - keys)}"
        )


def require_identity(value: Any, field: str = "identity") -> str:
    if not isinstance(value, str) or IDENTITY_RE.fullmatch(value) is None:
        raise ReviewError(f"{field} must be a slash-prefixed stable identity")
    return value


def require_sha256(value: Any, field: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise ReviewError(f"{field} must be lowercase SHA-256 hex")
    return value


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ReviewError(f"{field} must be a non-empty string")
    return value


def require_trimmed_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise ReviewError(f"{field} must be a trimmed non-empty string")
    return value


def require_exact_integer(value: Any, field: str, *, expected: int | None = None) -> int:
    if isinstance(value, bool) or type(value) is not int:
        raise ReviewError(f"{field} must be a JSON integer")
    if expected is not None and value != expected:
        raise ReviewError(f"{field} must equal {expected}")
    return value


def require_canonical_utc(value: Any, field: str = "issued_at") -> str:
    if not isinstance(value, str) or CANONICAL_UTC_RE.fullmatch(value) is None:
        raise ReviewError(f"{field} must be canonical UTC YYYY-MM-DDTHH:MM:SS.ffffffZ")
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError as error:
        raise ReviewError(f"{field} is not a valid UTC timestamp") from error
    return value


def run(
    argv: list[str],
    *,
    cwd: Path | None = None,
    input_bytes: bytes | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            argv,
            cwd=cwd,
            input=input_bytes,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise ReviewError(f"cannot run {argv[0]}: {error}") from error
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ReviewError(f"command failed ({' '.join(argv)}): {detail}")
    return result


def git_output(repo: Path, *arguments: str, check: bool = True) -> bytes:
    return run(["git", *arguments], cwd=repo, check=check).stdout


def git_root(repo: Path) -> Path:
    return Path(git_output(repo, "rev-parse", "--show-toplevel").decode().strip()).resolve()


def git_common_dir(repo: Path) -> Path:
    raw = git_output(repo, "rev-parse", "--git-common-dir").decode().strip()
    path = Path(raw)
    if not path.is_absolute():
        path = git_root(repo) / path
    return path.resolve()


def authority_dir(repo: Path) -> Path:
    return git_common_dir(repo) / "duckpad-review-authority" / "v1"


def trust_dir(repo: Path) -> Path:
    return git_common_dir(repo) / "duckpad-review-trust" / "v1"


def genesis_registry_paths(repo: Path) -> tuple[Path, Path]:
    snapshot = trust_dir(repo) / GENESIS_REGISTRY_FILENAME
    return snapshot, snapshot.with_suffix(".sha256")


def load_external_genesis_registry(repo: Path) -> tuple[dict[str, dict[str, Any]], bytes]:
    snapshot, digest_path = genesis_registry_paths(repo)
    for path, label in ((snapshot, "genesis registry snapshot"), (digest_path, "genesis registry digest")):
        if (not path.is_file() or path.is_symlink() or path.parent.is_symlink()
                or path.parent.parent.is_symlink()):
            raise ReviewError(f"external {label} is missing")
        if stat.S_IMODE(path.stat().st_mode) & 0o222:
            raise ReviewError(f"external {label} must be read-only")
    fields = digest_path.read_text(encoding="ascii").strip().split()
    if len(fields) != 2 or fields[1] != snapshot.name:
        raise ReviewError("external genesis registry digest must bind the snapshot filename")
    expected = require_sha256(fields[0], "external genesis registry digest")
    identities, raw = load_registry(snapshot)
    if sha256_bytes(raw) != expected:
        raise ReviewError("external genesis registry snapshot digest mismatch")
    return identities, raw


def key_token(reviewer_id: str) -> str:
    require_identity(reviewer_id, "reviewer_id")
    return sha256_bytes(reviewer_id.encode("utf-8"))[:32]


def private_key_path(repo: Path, reviewer_id: str) -> Path:
    return authority_dir(repo) / "keys" / key_token(reviewer_id)


def allowed_signers_path(repo: Path) -> Path:
    return trust_dir(repo) / "allowed_signers"


def builder_identity_path(repo: Path) -> Path:
    return trust_dir(repo) / "builder_identity"


def provisioned_builder_identity(repo: Path) -> str:
    path = builder_identity_path(repo)
    if (not path.is_file() or path.is_symlink() or path.parent.is_symlink()
            or path.parent.parent.is_symlink()):
        raise ReviewError("orchestrator-provisioned builder identity is missing")
    if stat.S_IMODE(path.stat().st_mode) & 0o022:
        raise ReviewError("orchestrator-provisioned builder identity must not be group/world writable")
    return require_identity(path.read_text(encoding="utf-8").strip(), "provisioned builder identity")


def atomic_write(path: Path, raw: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def load_registry(path: Path) -> tuple[dict[str, dict[str, Any]], bytes]:
    registry, raw = load_json(path)
    require_exact_keys(registry, {"schema_version", "identities"}, "reviewer registry")
    require_exact_integer(registry["schema_version"], "reviewer registry schema_version", expected=2)
    if registry["schema_version"] != 2:
        raise ReviewError("reviewer registry schema_version must be 2")
    identities = registry["identities"]
    if not isinstance(identities, list):
        raise ReviewError("reviewer registry identities must be an array")
    result: dict[str, dict[str, Any]] = {}
    for item in identities:
        if not isinstance(item, dict):
            raise ReviewError("reviewer registry identity must be an object")
        require_exact_keys(item, {"id", "public_key", "roles", "status"}, "reviewer identity")
        reviewer_id = require_identity(item["id"], "reviewer identity id")
        if reviewer_id in result:
            raise ReviewError(f"duplicate reviewer identity: {reviewer_id}")
        public_key = require_string(item["public_key"], f"{reviewer_id} public_key")
        if PUBLIC_KEY_RE.fullmatch(public_key) is None:
            raise ReviewError(f"{reviewer_id} must use one ssh-ed25519 public key")
        roles = item["roles"]
        if (
            not isinstance(roles, list)
            or not roles
            or not all(isinstance(role, str) and role in ROLE_NAMESPACES for role in roles)
            or len(roles) != len(set(roles))
        ):
            raise ReviewError(f"{reviewer_id} has invalid or duplicate reviewer roles")
        if item["status"] not in {"active", "inactive"}:
            raise ReviewError(f"{reviewer_id} status must be active or inactive")
        result[reviewer_id] = item
    return result, raw


def public_key_from_file(path: Path) -> str:
    fields = path.read_text(encoding="utf-8").strip().split()
    if len(fields) < 2:
        raise ReviewError(f"malformed public key: {path}")
    public_key = f"{fields[0]} {fields[1]}"
    if PUBLIC_KEY_RE.fullmatch(public_key) is None:
        raise ReviewError("review authority key must be Ed25519")
    return public_key


def require_active_reviewer(
    *,
    registry_path: Path,
    reviewer_id: str,
    role: str,
    forbidden_ids: set[str],
) -> tuple[dict[str, Any], bytes]:
    identities, registry_raw = load_registry(registry_path)
    if reviewer_id in forbidden_ids:
        raise ReviewError("candidate builder cannot act as independent reviewer")
    identity = identities.get(reviewer_id)
    if identity is None:
        raise ReviewError("reviewer is absent from the versioned registry")
    if identity["status"] != "active":
        raise ReviewError("reviewer registry identity is inactive")
    if role not in identity["roles"]:
        raise ReviewError(f"reviewer lacks required role: {role}")
    return identity, registry_raw


def _allowed_signer_has_exact_key(path: Path, reviewer_id: str, public_key: str, namespace: str) -> None:
    if (not path.is_file() or path.is_symlink() or path.parent.is_symlink()
            or path.parent.parent.is_symlink()):
        raise ReviewError(f"local allowed_signers trust root is missing: {path}")
    if stat.S_IMODE(path.stat().st_mode) & 0o022:
        raise ReviewError("local allowed_signers trust root must not be group/world writable")
    expected_prefix = f'{reviewer_id} namespaces="{namespace}" {public_key}'
    matching = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip().startswith(reviewer_id + " ")]
    if expected_prefix not in matching:
        raise ReviewError("versioned reviewer key is not active in the local allowed_signers trust root")


def sign_envelope(*, signed: dict[str, Any], private_key: Path) -> dict[str, Any]:
    require_exact_keys(signed, {"schema_version", "namespace", "signer_id", "payload"}, "signed envelope")
    namespace = require_string(signed["namespace"], "signature namespace")
    require_identity(signed["signer_id"], "signer_id")
    if not private_key.is_file():
        raise ReviewError(f"reviewer private key is missing: {private_key}")
    if stat.S_IMODE(private_key.stat().st_mode) & 0o077:
        raise ReviewError("reviewer private key permissions must be 0600 or stricter")
    raw = canonical_json(signed)
    with tempfile.TemporaryDirectory(prefix="duckpad-sign-") as temporary:
        message = Path(temporary) / "message.json"
        message.write_bytes(raw)
        run(["ssh-keygen", "-Y", "sign", "-f", str(private_key), "-n", namespace, str(message)])
        signature = (Path(str(message) + ".sig")).read_text(encoding="utf-8")
    return {"signed": signed, "signature": signature}


def verify_envelope(
    *,
    envelope_path: Path,
    registry_path: Path,
    allowed_signers: Path,
    expected_namespace: str,
    required_role: str,
    forbidden_ids: set[str],
) -> tuple[dict[str, Any], str, str]:
    envelope, raw = load_json(envelope_path)
    require_exact_keys(envelope, {"signed", "signature"}, "signature envelope")
    signed = envelope["signed"]
    if not isinstance(signed, dict):
        raise ReviewError("signed envelope payload must be an object")
    require_exact_keys(signed, {"schema_version", "namespace", "signer_id", "payload"}, "signed envelope")
    require_exact_integer(signed["schema_version"], "signed envelope schema_version", expected=1)
    if signed["namespace"] != expected_namespace:
        raise ReviewError("signed envelope schema or namespace mismatch")
    signer_id = require_identity(signed["signer_id"], "signer_id")
    identity, _ = require_active_reviewer(
        registry_path=registry_path,
        reviewer_id=signer_id,
        role=required_role,
        forbidden_ids=forbidden_ids,
    )
    _allowed_signer_has_exact_key(allowed_signers, signer_id, identity["public_key"], expected_namespace)
    signature = require_string(envelope["signature"], "signature")
    with tempfile.TemporaryDirectory(prefix="duckpad-verify-") as temporary:
        allowed = Path(temporary) / "allowed_signers"
        allowed.write_text(
            f'{signer_id} namespaces="{expected_namespace}" {identity["public_key"]}\n',
            encoding="utf-8",
        )
        signature_path = Path(temporary) / "signature"
        signature_path.write_text(signature, encoding="utf-8")
        result = run(
            [
                "ssh-keygen", "-Y", "verify", "-f", str(allowed), "-I", signer_id,
                "-n", expected_namespace, "-s", str(signature_path),
            ],
            input_bytes=canonical_json(signed),
            check=False,
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            raise ReviewError(f"reviewer signature verification failed: {detail}")
    payload = signed["payload"]
    if not isinstance(payload, dict):
        raise ReviewError("signed payload must be an object")
    return payload, signer_id, sha256_bytes(raw)
