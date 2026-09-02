#!/usr/bin/env python3
"""Verify cryptographically signed Duckpad parity attestations."""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from typing import Any

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from review.review_common import (
    PARITY_NAMESPACE, ReviewError, require_exact_integer, require_exact_keys, require_sha256,
    sha256_bytes, verify_envelope,
)


def _verify(*, path: Path, expected_sha256: str, registry_bytes: bytes,
            expected_registry_sha256: str, trust_dir: Path,
            forbidden_reviewer_ids: set[str]) -> tuple[dict[str, Any], str]:
    require_sha256(expected_sha256, "attestation sha256")
    require_sha256(expected_registry_sha256, "registry sha256")
    if sha256_bytes(registry_bytes) != expected_registry_sha256:
        raise ReviewError("reviewer registry hash mismatch")
    with tempfile.TemporaryDirectory(prefix="duckpad-parity-registry-") as temporary:
        registry_path = Path(temporary) / "reviewers.json"
        registry_path.write_bytes(registry_bytes)
        payload, signer, actual = verify_envelope(
            envelope_path=path, registry_path=registry_path,
            allowed_signers=trust_dir / "allowed_signers",
            expected_namespace=PARITY_NAMESPACE, required_role="independent_parity_reviewer",
            forbidden_ids=forbidden_reviewer_ids,
        )
    if actual != expected_sha256:
        raise ReviewError("attestation hash mismatch")
    return payload, signer


def verify_receipt(*, receipt_path: Path, expected_receipt_sha256: str,
                   expected_reviewer_id: str, expected_rule_id: str,
                   expected_candidate_sha256: str, expected_baseline_version: str,
                   expected_rationale_sha256: str, expected_parity_contract_sha256: str,
                   registry_bytes: bytes, expected_registry_sha256: str,
                   forbidden_reviewer_ids: set[str], trust_dir: Path) -> dict[str, str]:
    payload, signer = _verify(
        path=receipt_path, expected_sha256=expected_receipt_sha256,
        registry_bytes=registry_bytes, expected_registry_sha256=expected_registry_sha256,
        trust_dir=trust_dir, forbidden_reviewer_ids=forbidden_reviewer_ids,
    )
    require_exact_keys(payload, {"schema_version", "kind", "baseline_version", "candidate_sha256",
                                 "parity_contract_sha256", "rule_id", "decision", "rationale_sha256"},
                       "Reviewed-N/A attestation payload")
    expected = {"schema_version": 1, "kind": "parity-reviewed-na",
                "baseline_version": expected_baseline_version,
                "candidate_sha256": expected_candidate_sha256,
                "parity_contract_sha256": expected_parity_contract_sha256,
                "rule_id": expected_rule_id, "decision": "approved",
                "rationale_sha256": expected_rationale_sha256}
    for field, value in expected.items():
        if payload[field] != value:
            raise ReviewError(f"Reviewed-N/A attestation {field} binding mismatch")
    require_exact_integer(payload["schema_version"], "Reviewed-N/A schema_version", expected=1)
    require_sha256(payload["rationale_sha256"], "rationale_sha256")
    if signer != expected_reviewer_id:
        raise ReviewError("Reviewed-N/A signer does not match reviewer_id")
    return {"reviewer_id": signer, "rule_id": expected_rule_id}


def verify_evidence(*, attestation_path: Path, expected_attestation_sha256: str,
                    expected_reviewer_id: str, expected_evidence_id: str,
                    expected_evidence_type: str, expected_candidate_sha256: str,
                    expected_baseline_version: str, expected_subjects: list[dict[str, str]],
                    expected_parity_contract_sha256: str,
                    registry_bytes: bytes, expected_registry_sha256: str,
                    forbidden_reviewer_ids: set[str], trust_dir: Path) -> dict[str, Any]:
    payload, signer = _verify(
        path=attestation_path, expected_sha256=expected_attestation_sha256,
        registry_bytes=registry_bytes, expected_registry_sha256=expected_registry_sha256,
        trust_dir=trust_dir, forbidden_reviewer_ids=forbidden_reviewer_ids,
    )
    require_exact_keys(payload, {"schema_version", "kind", "baseline_version", "candidate_sha256",
                                 "parity_contract_sha256", "evidence_id", "evidence_type", "subjects",
                                 "result_artifact_path", "result_artifact_sha256"},
                       "parity evidence attestation payload")
    expected = {"schema_version": 1, "kind": "parity-evidence",
                "baseline_version": expected_baseline_version,
                "candidate_sha256": expected_candidate_sha256,
                "parity_contract_sha256": expected_parity_contract_sha256,
                "evidence_id": expected_evidence_id, "evidence_type": expected_evidence_type,
                "subjects": expected_subjects}
    for field, value in expected.items():
        if payload[field] != value:
            raise ReviewError(f"parity evidence {field} binding mismatch")
    require_exact_integer(payload["schema_version"], "parity evidence schema_version", expected=1)
    require_sha256(payload["result_artifact_sha256"], "result_artifact_sha256")
    if signer != expected_reviewer_id:
        raise ReviewError("parity evidence signer does not match reviewer_id")
    return payload
