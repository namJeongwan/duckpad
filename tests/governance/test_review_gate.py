#!/usr/bin/env python3
"""End-to-end tests for the parent-pinned independent-review commit gate."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.review import review_common as REVIEW_COMMON


ROOT = Path(__file__).resolve().parents[2]
REVIEW = ROOT / "scripts/review"
NAMESPACES = {
    "independent_commit_reviewer": "duckpad-commit-review-v1",
    "independent_parity_reviewer": "duckpad-parity-attestation-v1",
}


class ReviewGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="duckpad-governance-")
        self.repo = Path(self.temporary.name) / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-b", "main"], cwd=self.repo, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Duckpad Test"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "test@duckpad.invalid"], cwd=self.repo, check=True)
        (self.repo / "scripts").mkdir()
        shutil.copytree(REVIEW, self.repo / "scripts/review", ignore=shutil.ignore_patterns("__pycache__"))
        (self.repo / "docs/parity").mkdir(parents=True)
        self.registry = self.repo / "docs/parity/reviewer-identities.v1.json"
        self.registry.write_text('{"identities":[],"schema_version":2}\n', encoding="utf-8")
        self.provision_identity("/reviewer/alice", ["independent_commit_reviewer", "independent_parity_reviewer"])
        self.seal_genesis_registry()
        self.provision_builder("/builder/bob")
        self.run_script("install_hooks.py")
        (self.repo / "candidate.txt").write_text("candidate\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        self.message = self.repo / ".git/test-message.txt"
        self.message.write_text(
            "feat: bootstrap reviewed repository\n\n"
            "Establish the initial governed candidate.\n\n"
            "Keep future changes bound to exact review receipts.\n",
            encoding="ascii",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def provision_builder(self, identity: str) -> None:
        trust = self.repo / ".git/duckpad-review-trust/v1"
        trust.mkdir(parents=True, exist_ok=True)
        path = trust / "builder_identity"
        path.write_text(identity + "\n", encoding="utf-8")
        path.chmod(0o600)

    def seal_genesis_registry(self) -> None:
        trust = self.repo / ".git/duckpad-review-trust/v1"
        snapshot = trust / "genesis-reviewers.json"
        if snapshot.exists():
            snapshot.chmod(0o600)
        snapshot.write_bytes(self.registry.read_bytes())
        snapshot.chmod(0o400)
        sidecar = snapshot.with_suffix(".sha256")
        if sidecar.exists():
            sidecar.chmod(0o600)
        sidecar.write_text(f"{hashlib.sha256(snapshot.read_bytes()).hexdigest()}  {snapshot.name}\n")
        sidecar.chmod(0o400)

    def provision_identity(self, reviewer: str, roles: list[str], *, trust: bool = True) -> Path:
        token = hashlib.sha256(reviewer.encode()).hexdigest()[:32]
        keys = self.repo / ".git/duckpad-review-authority/v1/keys"
        keys.mkdir(parents=True, exist_ok=True)
        key = keys / token
        subprocess.run([
            "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", reviewer,
            "-f", str(key),
        ], check=True)
        key.chmod(0o600)
        key.with_suffix(".pub").chmod(0o600)
        fields = key.with_suffix(".pub").read_text().split()
        public_key = f"{fields[0]} {fields[1]}"
        registry = json.loads(self.registry.read_text())
        registry["identities"].append({
            "id": reviewer, "public_key": public_key,
            "roles": sorted(roles), "status": "active",
        })
        registry["identities"].sort(key=lambda item: item["id"])
        self.registry.write_text(json.dumps(registry, indent=2, sort_keys=True) + "\n")
        if trust:
            trust_directory = self.repo / ".git/duckpad-review-trust/v1"
            trust_directory.mkdir(parents=True, exist_ok=True)
            allowed = trust_directory / "allowed_signers"
            lines = allowed.read_text().splitlines() if allowed.exists() else []
            lines.extend(f'{reviewer} namespaces="{NAMESPACES[role]}" {public_key}' for role in roles)
            allowed.write_text("\n".join(sorted(lines)) + "\n")
            allowed.chmod(0o600)
        return key

    def run_script(self, name: str, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", "-B", str(self.repo / "scripts/review" / name), "--repo", str(self.repo), *args],
            cwd=self.repo, text=True, capture_output=True, check=check,
        )

    def prepare(self) -> str:
        return self.run_script(
            "verify_candidate.py", "prepare", "--message-file", str(self.message),
        ).stdout.strip()

    def sign(self, candidate: str, reviewer: str = "/reviewer/alice", *, check: bool = True):
        return self.run_script(
            "create_receipt.py", "--candidate-id", candidate, "--reviewer-id", reviewer,
            "--scope", "all staged files", "--validation", "governance fixture passed",
            check=check,
        )

    def prepare_and_sign(self, reviewer: str = "/reviewer/alice") -> tuple[str, Path]:
        candidate = self.prepare()
        signed = self.sign(candidate, reviewer)
        return candidate, Path(signed.stdout.strip())

    def commit(self, candidate: str) -> str:
        return self.run_script("local_commit.py", "--candidate-id", candidate).stdout.strip()

    def test_unborn_parent_pinned_onboarding_and_no_verify_audit(self) -> None:
        allowed = self.repo / ".git/duckpad-review-trust/v1/allowed_signers"
        trust_before = allowed.read_bytes()
        root_candidate, _ = self.prepare_and_sign()
        self.commit(root_candidate)
        self.assertEqual(trust_before, allowed.read_bytes())
        self.assertIn("audited 1 commit", self.run_script("verify_candidate.py", "audit", "--all").stdout)

        # Bob is externally trusted and added by this candidate, but is absent from its parent registry.
        self.provision_identity("/reviewer/bob", ["independent_commit_reviewer"])
        subprocess.run(["git", "add", str(self.registry)], cwd=self.repo, check=True)
        self.message.write_text("chore: onboard second reviewer\n", encoding="ascii")
        onboarding = self.prepare()
        premature = self.sign(onboarding, "/reviewer/bob", check=False)
        self.assertNotEqual(premature.returncode, 0)
        self.assertIn("absent from the versioned registry", premature.stderr)
        self.sign(onboarding, "/reviewer/alice")
        self.commit(onboarding)

        (self.repo / "candidate.txt").write_text("reviewed by parent-pinned Bob\n", encoding="utf-8")
        subprocess.run(["git", "add", "candidate.txt"], cwd=self.repo, check=True)
        self.message.write_text("fix: use parent pinned reviewer\n", encoding="ascii")
        follow_up, _ = self.prepare_and_sign("/reviewer/bob")
        self.commit(follow_up)
        self.assertIn("audited 3 commit", self.run_script("verify_candidate.py", "audit", "--all").stdout)

        (self.repo / "candidate.txt").write_text("policy bypass\n", encoding="utf-8")
        subprocess.run(["git", "add", "candidate.txt"], cwd=self.repo, check=True)
        blocked = subprocess.run(
            ["git", "commit", "-m", "fix: raw commit must be blocked"], cwd=self.repo,
            text=True, capture_output=True,
        )
        self.assertNotEqual(blocked.returncode, 0)
        subprocess.run(["git", "commit", "--no-verify", "-m", "fix: simulate policy bypass"],
                       cwd=self.repo, check=True, capture_output=True)
        failed = self.run_script("verify_candidate.py", "audit", "--all", check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("--no-verify bypass detected", failed.stderr)

    def test_no_shipped_bootstrap_alias_and_absent_trust_fail(self) -> None:
        self.assertFalse((self.repo / "scripts/review/bootstrap_authority.py").exists())
        missing_command = self.run_script("bootstrap_authority.py", check=False)
        self.assertNotEqual(missing_command.returncode, 0)

        identity_path = self.repo / ".git/duckpad-review-trust/v1/builder_identity"
        identity_path.unlink()
        missing_identity = self.run_script(
            "verify_candidate.py", "prepare", "--message-file", str(self.message), check=False,
        )
        self.assertNotEqual(missing_identity.returncode, 0)
        self.assertIn("builder identity is missing", missing_identity.stderr)
        self.provision_builder("/builder/bob")

        # Even an externally keyed identity cannot use a registry record introduced by this ROOT candidate.
        self.provision_identity("/reviewer/self-registered", ["independent_commit_reviewer"], trust=True)
        subprocess.run(["git", "add", str(self.registry)], cwd=self.repo, check=True)
        alias_candidate = self.prepare()
        rejected = self.sign(alias_candidate, "/reviewer/self-registered", check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("absent from the versioned registry", rejected.stderr)

        # Even a valid genesis signer cannot approve an unborn repository without the pre-existing root.
        allowed = self.repo / ".git/duckpad-review-trust/v1/allowed_signers"
        allowed.unlink()
        self.sign(alias_candidate, "/reviewer/alice")
        rejected = self.run_script("verify_candidate.py", "verify", "--candidate-id", alias_candidate, check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("trust root is missing", rejected.stderr)

    def test_receipt_strict_types_timestamp_and_trimmed_arrays(self) -> None:
        candidate, original = self.prepare_and_sign()
        original_envelope = json.loads(original.read_text())
        key = REVIEW_COMMON.private_key_path(self.repo, "/reviewer/alice")
        mutations = (
            ("schema-bool", lambda payload: payload.__setitem__("schema_version", True), "JSON integer"),
            ("blocker-bool", lambda payload: payload.__setitem__("unresolved_blockers", False), "JSON integer"),
            ("major-float", lambda payload: payload.__setitem__("unresolved_majors", 0.0), "JSON integer"),
            ("scope-space", lambda payload: payload.__setitem__("scope", ["   "]), "trimmed non-empty"),
            ("validation-padding", lambda payload: payload.__setitem__("validation", [" pass "]), "trimmed non-empty"),
            ("timestamp-offset", lambda payload: payload.__setitem__("issued_at", "2026-09-02T00:00:00+00:00"), "canonical UTC"),
        )
        original.unlink()
        for name, mutate, message in mutations:
            signed = json.loads(json.dumps(original_envelope["signed"]))
            mutate(signed["payload"])
            envelope = REVIEW_COMMON.sign_envelope(signed=signed, private_key=key)
            raw = REVIEW_COMMON.canonical_json(envelope)
            receipt = self.repo / f".git/duckpad-review-receipts/v1/{candidate}.{hashlib.sha256(raw).hexdigest()}.json"
            receipt.write_bytes(raw)
            receipt.chmod(0o400)
            with self.subTest(mutation=name):
                rejected = self.run_script(
                    "verify_candidate.py", "verify", "--candidate-id", candidate, check=False,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(message, rejected.stderr)
            receipt.unlink()

    def test_authenticated_builder_candidate_and_receipt_tamper_fail(self) -> None:
        candidate, receipt = self.prepare_and_sign()
        manifest_path = self.repo / f".git/duckpad-review-candidates/v1/{candidate}.json"
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["builder_id"], "/builder/bob")
        override = self.run_script(
            "verify_candidate.py", "prepare", "--message-file", str(self.message),
            "--builder-id", "/reviewer/alias", check=False,
        )
        self.assertNotEqual(override.returncode, 0)

        (self.repo / "candidate.txt").write_text("changed after signature\n", encoding="utf-8")
        subprocess.run(["git", "add", "candidate.txt"], cwd=self.repo, check=True)
        changed = self.run_script("verify_candidate.py", "verify", "--candidate-id", candidate, check=False)
        self.assertNotEqual(changed.returncode, 0)
        (self.repo / "candidate.txt").write_text("candidate\n", encoding="utf-8")
        subprocess.run(["git", "add", "candidate.txt"], cwd=self.repo, check=True)
        receipt.chmod(0o600)
        envelope = json.loads(receipt.read_text())
        envelope["signed"]["payload"]["decision"] = "rejected"
        receipt.write_text(json.dumps(envelope), encoding="utf-8")
        tampered = self.run_script("verify_candidate.py", "verify", "--candidate-id", candidate, check=False)
        self.assertNotEqual(tampered.returncode, 0)
        self.assertIn("filename hash mismatch", tampered.stderr)

    def test_wrong_role_inactive_and_same_builder_are_rejected(self) -> None:
        self.provision_identity("/reviewer/wrong-role", ["independent_parity_reviewer"])
        self.provision_identity("/builder/bob", ["independent_commit_reviewer"])
        registry = json.loads(self.registry.read_text())
        for identity in registry["identities"]:
            if identity["id"] == "/reviewer/alice":
                identity["status"] = "inactive"
        self.registry.write_text(json.dumps(registry, indent=2, sort_keys=True) + "\n")
        self.seal_genesis_registry()
        subprocess.run(["git", "add", str(self.registry)], cwd=self.repo, check=True)
        candidate = self.prepare()
        for reviewer, message in (("/reviewer/wrong-role", "lacks required role"),
                                  ("/reviewer/alice", "inactive"),
                                  ("/builder/bob", "cannot act as independent reviewer")):
            with self.subTest(reviewer=reviewer):
                result = self.sign(candidate, reviewer, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_notepad_reference_path_is_rejected_during_prepare_and_verify(self) -> None:
        reference = self.repo / "vendor/notepad-plus-plus/README.md"
        reference.parent.mkdir(parents=True)
        reference.write_text("external reference must never enter product history\n", encoding="utf-8")
        subprocess.run(["git", "add", "-f", str(reference)], cwd=self.repo, check=True)
        rejected = self.run_script(
            "verify_candidate.py", "prepare", "--message-file", str(self.message), check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("forbidden Notepad++ reference path", rejected.stderr)

        subprocess.run(["git", "reset", "--", str(reference)], cwd=self.repo, check=True)
        reference.unlink()
        reference.parent.rmdir()
        candidate, _ = self.prepare_and_sign()
        forbidden = self.repo / "Notepad-Plus-Plus/source.txt"
        forbidden.parent.mkdir()
        forbidden.write_text("case-insensitive collision\n", encoding="utf-8")
        subprocess.run(["git", "add", "-f", str(forbidden)], cwd=self.repo, check=True)
        verified = self.run_script(
            "verify_candidate.py", "verify", "--candidate-id", candidate, check=False,
        )
        self.assertNotEqual(verified.returncode, 0)
        self.assertIn("forbidden Notepad++ reference path", verified.stderr)

    def test_every_readme_name_is_rejected_during_prepare(self) -> None:
        for name in ("README", "README.md", "readme.txt", "ReAdMe-Candidate.md"):
            path = self.repo / "nested" / name
            path.parent.mkdir(exist_ok=True)
            path.write_text("README is intentionally withheld\n", encoding="utf-8")
            subprocess.run(["git", "add", "-f", str(path)], cwd=self.repo, check=True)
            rejected = self.run_script(
                "verify_candidate.py", "prepare", "--message-file", str(self.message), check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("forbidden README name", rejected.stderr)
            subprocess.run(["git", "reset", "--", str(path)], cwd=self.repo, check=True)
            path.unlink()

    def test_every_gitlink_is_rejected_during_prepare(self) -> None:
        empty_tree = subprocess.run(
            ["git", "mktree"], cwd=self.repo, input="", text=True,
            capture_output=True, check=True,
        ).stdout.strip()
        gitlink_oid = subprocess.run(
            ["git", "commit-tree", empty_tree, "-m", "fixture commit"],
            cwd=self.repo, text=True, capture_output=True, check=True,
        ).stdout.strip()
        subprocess.run([
            "git", "update-index", "--add", "--cacheinfo",
            f"160000,{gitlink_oid},vendor/external-reference",
        ], cwd=self.repo, check=True)
        rejected = self.run_script(
            "verify_candidate.py", "prepare", "--message-file", str(self.message), check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("forbidden gitlink", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
