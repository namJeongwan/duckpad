#!/usr/bin/env python3

import copy, hashlib, importlib.util, json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

from scripts.review import review_common as REVIEW_COMMON

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/check_parity_baseline.py"
SETUP_SCRIPT = ROOT / "scripts/setup_notepadpp_reference.sh"
PRODUCTION = ROOT / "docs/parity/notepad-plus-plus-command-baseline.v1.json"
SPEC = importlib.util.spec_from_file_location("parity_checker", SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def provision_test_identity(repo, registry_path, reviewer_id, roles, *, add_to_trust=True):
    """Test-only external/orchestrator provisioning; intentionally not shipped in scripts/."""
    token = hashlib.sha256(reviewer_id.encode()).hexdigest()[:32]
    keys = repo / ".git/duckpad-review-authority/v1/keys"
    keys.mkdir(parents=True, exist_ok=True)
    key = keys / token
    subprocess.run([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", reviewer_id,
        "-f", str(key),
    ], check=True)
    key.chmod(0o600)
    key.with_suffix(".pub").chmod(0o600)
    fields = key.with_suffix(".pub").read_text().split()
    public_key = f"{fields[0]} {fields[1]}"
    registry = json.loads(registry_path.read_text())
    registry["identities"].append({
        "id": reviewer_id, "public_key": public_key,
        "roles": sorted(roles), "status": "active",
    })
    registry["identities"].sort(key=lambda item: item["id"])
    registry_path.write_text(json.dumps(registry, indent=2, sort_keys=True) + "\n")
    if add_to_trust:
        trust = repo / ".git/duckpad-review-trust/v1"
        trust.mkdir(parents=True, exist_ok=True)
        allowed = trust / "allowed_signers"
        lines = allowed.read_text().splitlines() if allowed.exists() else []
        namespaces = {
            "independent_commit_reviewer": "duckpad-commit-review-v1",
            "independent_parity_reviewer": "duckpad-parity-attestation-v1",
        }
        lines.extend(f'{reviewer_id} namespaces="{namespaces[role]}" {public_key}' for role in roles)
        allowed.write_text("\n".join(sorted(lines)) + "\n")
        allowed.chmod(0o600)
    return key


def seal_genesis_registry(repo, registry_path):
    trust = repo / ".git/duckpad-review-trust/v1"
    trust.mkdir(parents=True, exist_ok=True)
    snapshot = trust / "genesis-reviewers.json"
    if snapshot.exists():
        snapshot.chmod(0o600)
    snapshot.write_bytes(registry_path.read_bytes())
    snapshot.chmod(0o400)
    sidecar = snapshot.with_suffix(".sha256")
    if sidecar.exists():
        sidecar.chmod(0o600)
    sidecar.write_text(f"{digest(snapshot)}  {snapshot.name}\n")
    sidecar.chmod(0o400)
    return snapshot


class ParityBaselineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tests")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.path = self.directory / "baseline.json"
        self.baseline = json.loads(PRODUCTION.read_text())
        self.baseline["source"]["symbol_fixture_path"] = os.path.relpath(
            ROOT / "tests/fixtures/menuCmdID.v1.symbols", self.directory
        )
        self.baseline["source"]["workflow_fixture_path"] = os.path.relpath(
            ROOT / "docs/parity/notepad-plus-plus-workflow-inventory.v1.json", self.directory
        )
        self.registry = self.directory / "reviewer-identities.json"
        self.registry.write_bytes((ROOT / "docs/parity/reviewer-identities.v1.json").read_bytes())
        self.baseline["review_policy"]["reviewer_registry_path"] = self.registry.name
        self.baseline["review_policy"]["reviewer_registry_sha256"] = digest(self.registry)

    def write(self, value=None, sidecar=True, raw=None, refresh_contract=True):
        target = value or self.baseline
        if raw is None and refresh_contract:
            target["parity_contract_sha256"] = CHECKER.parity_contract_sha256(target)
        raw = raw if raw is not None else json.dumps(target, indent=2) + "\n"
        self.path.write_text(raw)
        if sidecar:
            self.path.with_suffix(".sha256").write_text(f"{digest(self.path)}  {self.path.name}\n")
        return self.path

    def validate(self, value=None):
        trust = getattr(self, "trust", None)
        return CHECKER.validate_and_calculate(self.write(value), review_trust_dir=trust)

    def sign(self, payload, name, reviewer="/reviewer/fixture"):
        payload_path = self.directory / f"{name}.payload.json"
        output = self.directory / f"{name}.attestation.json"
        payload_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        subprocess.run([
            sys.executable, "-B", str(ROOT / "scripts/review/create_parity_attestation.py"),
            "--repo", str(self.authority_repo), "--reviewer-id", reviewer,
            "--builder-id", "/root", "--builder-id", "/root/philosophy_parity",
            "--registry", str(self.registry), "--payload", str(payload_path),
            "--output", str(output),
        ], check=True, capture_output=True,
           env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        return output

    def release(self):
        self.authority_repo = self.directory
        subprocess.run(["git", "init", "-q"], cwd=self.authority_repo, check=True)
        self.registry = self.directory / "reviewer-identities.json"
        self.registry.write_text('{"identities":[],"schema_version":2}\n')
        provision_test_identity(
            self.authority_repo, self.registry, "/reviewer/fixture",
            ["independent_parity_reviewer"],
        )
        self.trust = self.authority_repo / ".git/duckpad-review-trust/v1"
        genesis = seal_genesis_registry(self.authority_repo, self.registry)
        self.baseline["review_policy"]["reviewer_registry_path"] = self.registry.name
        self.baseline["review_policy"]["reviewer_registry_sha256"] = digest(self.registry)
        self.baseline["review_policy"]["approval_registry_source"] = {
            "kind": "external_genesis_v1", "sha256": digest(genesis),
        }

        release = self.directory / "release"
        source = release / "source"
        source.mkdir(parents=True)
        (source / "Duckpad.swift").write_text("let reviewed = true\n")
        subprocess.run(["git", "add", "release/source"], cwd=self.authority_repo, check=True)
        subprocess.run([
            "git", "-c", "user.name=Duckpad Fixture", "-c", "user.email=fixture@duckpad.invalid",
            "commit", "-q", "-m", "release source candidate",
        ], cwd=self.authority_repo, check=True)
        source_commit_oid = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=self.authority_repo, text=True,
        ).strip()
        artifact = release / "Duckpad.app.zip"
        artifact.write_bytes(b"signed fixture build\n")
        manifest = release / "manifest.json"
        manifest_data = {
            "schema_version": 1, "kind": "duckpad-release-candidate", "id": "fixture-release",
            "builder_ids": self.baseline["review_policy"]["candidate_builder_ids"],
            "source_commit_oid": source_commit_oid,
            "source_tree": {"path": "source", "sha256": CHECKER._tree_sha256(source)},
            "build_artifacts": [{"id": "Duckpad.app.zip", "path": artifact.name, "sha256": digest(artifact)}],
        }
        manifest.write_text(json.dumps(manifest_data, indent=2, sort_keys=True) + "\n")
        candidate = digest(manifest)
        self.baseline["candidate"] = {
            "id":"fixture-release", "status":"release_candidate", "sha256":candidate,
            "manifest_path": os.path.relpath(manifest, self.directory),
        }
        self.baseline["parity_contract_sha256"] = CHECKER.parity_contract_sha256(self.baseline)
        subjects = ([{"type": "feature", "id": item["id"]} for item in self.baseline["features"]] +
                    [{"type": "ux_gate", "id": item["id"]} for item in self.baseline["ux_gates"]])
        evidence = []
        for evidence_type in ("automated", "manual"):
            evidence_id = f"E.{evidence_type.upper()}"
            result = {
                "schema_version": 1,
                "kind": "duckpad-machine-result" if evidence_type == "automated" else "duckpad-manual-result",
                "candidate_sha256": candidate, "evidence_id": evidence_id,
                "parity_contract_sha256": self.baseline["parity_contract_sha256"],
                "subjects": subjects, "status": "pass",
            }
            if evidence_type == "automated":
                result.update(command=["python3", "-m", "unittest"], exit_code=0)
            else:
                result.update(checklist=["Independent UX scenarios passed"])
            result_path = self.directory / f"{evidence_id}.result.json"
            result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
            payload = {
                "schema_version": 1, "kind": "parity-evidence",
                "baseline_version": self.baseline["baseline_version"], "candidate_sha256": candidate,
                "parity_contract_sha256": self.baseline["parity_contract_sha256"],
                "evidence_id": evidence_id, "evidence_type": evidence_type, "subjects": subjects,
                "result_artifact_path": result_path.name,
                "result_artifact_sha256": digest(result_path),
            }
            attestation = self.sign(payload, evidence_id)
            evidence.append({
                "id": evidence_id, "candidate_sha256": candidate, "evidence_type": evidence_type,
                "subjects": subjects, "reviewer_id": "/reviewer/fixture",
                "attestation_path": attestation.name, "attestation_sha256": digest(attestation),
            })
        self.baseline["evidence_records"] = evidence
        for item in self.baseline["features"]:
            item.update(state="Full", evidence_ids=["E.AUTOMATED", "E.MANUAL"])
        for item in self.baseline["ux_gates"]:
            item.update(status="Pass", evidence_ids=["E.AUTOMATED", "E.MANUAL"])
        reviewer = "/reviewer/fixture"
        for rule in self.baseline["command_mapping_rules"]:
            if rule["disposition"] != "reviewed_na": continue
            receipt_payload = {"schema_version":1,"kind":"parity-reviewed-na","decision":"approved",
                "rule_id":rule["id"],"candidate_sha256":candidate,
                "baseline_version":self.baseline["baseline_version"],
                "parity_contract_sha256":self.baseline["parity_contract_sha256"],
                "rationale_sha256":hashlib.sha256(rule["rationale"].encode()).hexdigest()}
            receipt_path = self.sign(receipt_payload, rule["id"])
            rule["independent_review"] = {"status":"approved","reviewer_id":reviewer,
                "receipt_path":receipt_path.name,"receipt_sha256":digest(receipt_path)}
        return self.baseline

    def integration_reference(self):
        reference = self.directory / "reference"
        source_root = reference / "PowerEditor/src"
        source_root.mkdir(parents=True)
        fixture_symbols = (ROOT / "tests/fixtures/menuCmdID.v1.symbols").read_text().splitlines()
        header = source_root / "menuCmdID.h"
        header.write_text("".join(f"#define {symbol} 1\n" for symbol in fixture_symbols))
        self.baseline["source"]["file_sha256"] = digest(header)
        for index, surface in enumerate(self.baseline["source"]["workflow_surfaces"]):
            surface_path = reference / surface["path"]
            tokens = []
            for workflow in self.baseline["source"]["workflow_inventory"]:
                if workflow["surface_id"] == surface["id"]:
                    token = f"WORKFLOW_TOKEN_{index}_{len(tokens)}"
                    workflow["selectors"] = [token]
                    workflow["expected_occurrences"] = 1
                    tokens.append(token)
            surface_path.write_text("\n".join(tokens) + "\n")
            surface["sha256"] = digest(surface_path)
        subprocess.run(["git", "init", "-q"], cwd=reference, check=True)
        subprocess.run(["git", "add", "."], cwd=reference, check=True)
        subprocess.run([
            "git", "-c", "user.name=Duckpad Fixture", "-c", "user.email=fixture@duckpad.invalid",
            "commit", "-q", "-m", "fixture"
        ], cwd=reference, check=True)
        self.baseline["source"]["commit"] = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=reference, text=True
        ).strip()
        frozen = {
            "schema_version": 1,
            "fixture_version": "synthetic-integration-v1",
            "source_commit": self.baseline["source"]["commit"],
            "surfaces": [
                {field: surface[field] for field in ("id", "path", "sha256")}
                for surface in self.baseline["source"]["workflow_surfaces"]
            ],
            "workflows": [{
                "id": workflow["id"], "surface_id": workflow["surface_id"],
                "feature_id": workflow["feature_id"], "selector": workflow["selectors"][0],
                "expected_occurrences": 1,
            } for workflow in self.baseline["source"]["workflow_inventory"]],
        }
        fixture_path = self.directory / "workflow-fixture.json"
        fixture_path.write_text(json.dumps(frozen, indent=2) + "\n")
        fixture_path.with_suffix(".sha256").write_text(
            f"{digest(fixture_path)}  {fixture_path.name}\n"
        )
        self.baseline["source"]["workflow_fixture_path"] = fixture_path.name
        self.baseline["source"]["workflow_fixture_sha256"] = digest(fixture_path)
        return reference

    def test_full_versioned_baseline_is_deterministic_without_ignored_tree(self):
        one = CHECKER.validate_and_calculate(PRODUCTION)
        self.assertEqual(one, CHECKER.validate_and_calculate(PRODUCTION))
        self.assertEqual((one["source_symbol_count"], one["workflow_surface_count"], one["scoring_feature_count"]), (530, 5, 94))
        self.assertFalse(one["integration_reference_audited"])

    def test_positive_release_fixture_passes(self):
        report = self.validate(self.release())
        self.assertTrue(report["release_pass"])
        self.assertEqual(report["weighted_feature_parity"], 100.0)

    def test_corrected_command_semantics(self):
        rules = {r["id"]:r for r in self.baseline["command_mapping_rules"]}
        self.assertEqual(rules["C2.WORD_WRAP"]["feature_id"], "C2.F12")
        self.assertEqual(rules["C3.VISIBLE_CHARACTERS"]["feature_id"], "C3.F13")
        self.assertEqual(rules["C2.TAB_MOVE_EDGES"]["feature_id"], "C2.F02")
        self.assertNotIn("GOTO_START", rules["C2.WINDOW_INSTANCE"]["match"]["regex"])

    def test_missing_gate_fails(self):
        self.baseline["ux_gates"].pop()
        with self.assertRaisesRegex(CHECKER.BaselineError, "exactly G1 through G10"): self.validate()

    def test_vacuous_p0_set_fails(self):
        for feature in self.baseline["features"]: feature["priority"] = "P1"
        with self.assertRaisesRegex(CHECKER.BaselineError, "non-vacuous"): self.validate()

    def test_evidence_missing_or_false_claim_fails(self):
        for state, evidence, message in (("Full", [], "candidate-bound evidence"), ("Missing", ["unknown"], "unknown evidence")):
            with self.subTest(state=state):
                value = copy.deepcopy(self.baseline); value["features"][0].update(state=state, evidence_ids=evidence)
                with self.assertRaisesRegex(CHECKER.BaselineError, message): self.validate(value)

    def test_candidate_bound_evidence_table_fails_closed(self):
        mutations = (
            ("candidate", "not bound to the candidate"),
            ("artifact_hash", "attestation verification"),
            ("result", "typed result artifact hash mismatch"),
            ("kinds", "invalid evidence_type"),
            ("owner", "attestation"),
            ("acceptance", "attestation"),
        )
        for mutation, message in mutations:
            with self.subTest(mutation=mutation):
                self.setUp(); self.release()
                if mutation == "candidate": self.baseline["evidence_records"][0]["candidate_sha256"] = "4"*64
                elif mutation == "artifact_hash": self.baseline["evidence_records"][0]["attestation_sha256"] = "4"*64
                elif mutation == "result": (self.directory / "E.AUTOMATED.result.json").write_text("{}\n")
                elif mutation == "kinds": self.baseline["evidence_records"][0]["evidence_type"] = "claimed-pass"
                elif mutation == "owner": self.baseline["features"][0]["owner"] = ""
                else: self.baseline["features"][0]["acceptance"] = []
                with self.assertRaisesRegex(CHECKER.BaselineError, message): self.validate()

    def test_pending_na_cannot_claim_receipt_and_approved_na_needs_one(self):
        for status, message in (("pending", "must not claim receipt fields"), ("approved", "receipt_path")):
            with self.subTest(status=status):
                value=copy.deepcopy(self.baseline)
                rule=next(r for r in value["command_mapping_rules"] if r["disposition"]=="reviewed_na")
                if status=="pending": rule["independent_review"]["reviewer_id"]="someone"
                else: rule["independent_review"]={"status":"approved","reviewer_id":None,"receipt_path":None,"receipt_sha256":None}
                with self.assertRaisesRegex(CHECKER.BaselineError,message): self.validate(value)

    def test_forged_release_with_pending_na_does_not_pass(self):
        self.release()
        rule = next(r for r in self.baseline["command_mapping_rules"] if r["disposition"] == "reviewed_na")
        rule["independent_review"] = {"status":"pending","reviewer_id":None,"receipt_path":None,"receipt_sha256":None}
        self.assertFalse(self.validate()["release_pass"])

    def test_unsigned_internally_consistent_release_is_rejected(self):
        self.release()
        record = self.baseline["evidence_records"][0]
        path = self.directory / record["attestation_path"]
        payload = json.loads(path.read_text())["signed"]["payload"]
        path.chmod(0o600)
        path.write_text(json.dumps({"signed": payload, "signature": "copied fingerprint"}) + "\n")
        record["attestation_sha256"] = digest(path)
        with self.assertRaisesRegex(CHECKER.BaselineError, "attestation|signature"):
            self.validate()

    def test_cryptographically_signed_self_authored_release_is_rejected(self):
        self.release()
        provision_test_identity(
            self.authority_repo, self.registry, "/root",
            ["independent_parity_reviewer"],
        )
        self.baseline["review_policy"]["reviewer_registry_sha256"] = digest(self.registry)
        genesis = seal_genesis_registry(self.authority_repo, self.registry)
        self.baseline["review_policy"]["approval_registry_source"]["sha256"] = digest(genesis)
        record = self.baseline["evidence_records"][0]
        payload = json.loads((self.directory / "E.AUTOMATED.payload.json").read_text())
        forged = REVIEW_COMMON.sign_envelope(
            signed={"schema_version": 1, "namespace": REVIEW_COMMON.PARITY_NAMESPACE,
                    "signer_id": "/root", "payload": payload},
            private_key=REVIEW_COMMON.private_key_path(self.authority_repo, "/root"),
        )
        path = self.directory / "self-authored.attestation.json"
        path.write_bytes(REVIEW_COMMON.canonical_json(forged))
        record.update(reviewer_id="/root", attestation_path=path.name,
                      attestation_sha256=digest(path))
        with self.assertRaisesRegex(CHECKER.BaselineError, "builder cannot"):
            self.validate()

    def test_candidate_only_parity_reviewer_cannot_approve_same_genesis_candidate(self):
        self.release()
        provision_test_identity(
            self.authority_repo, self.registry, "/reviewer/candidate-only",
            ["independent_parity_reviewer"],
        )
        self.baseline["review_policy"]["reviewer_registry_sha256"] = digest(self.registry)
        record = self.baseline["evidence_records"][0]
        payload = json.loads((self.directory / "E.AUTOMATED.payload.json").read_text())
        attestation = self.sign(payload, "candidate-only", reviewer="/reviewer/candidate-only")
        record.update(
            reviewer_id="/reviewer/candidate-only", attestation_path=attestation.name,
            attestation_sha256=digest(attestation),
        )
        with self.assertRaisesRegex(CHECKER.BaselineError, "absent from the versioned registry"):
            self.validate()

    def test_release_rejects_candidate_selected_trust_directory(self):
        self.release()
        candidate_trust = self.directory / "candidate-selected-trust"
        shutil.copytree(self.trust, candidate_trust)
        with self.assertRaisesRegex(CHECKER.BaselineError, "GIT_COMMON_DIR"):
            CHECKER.validate_and_calculate(self.write(), review_trust_dir=candidate_trust)

    def test_subsequent_parity_registry_is_resolved_from_parent_commit(self):
        repo = self.directory / "parent-registry-repo"
        registry = repo / "docs/parity/reviewer-identities.v1.json"
        registry.parent.mkdir(parents=True)
        registry.write_text('{"identities":[],"schema_version":2}\n')
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True)
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run([
            "git", "-c", "user.name=Duckpad Fixture", "-c", "user.email=fixture@duckpad.invalid",
            "commit", "-q", "-m", "parent registry",
        ], cwd=repo, check=True)
        parent = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        parent_raw = registry.read_bytes()
        registry.write_text('{"identities":[{"candidate":"only"}],"schema_version":2}\n')
        policy = {"approval_registry_source": {
            "kind": "parent_commit_v1", "parent_oid": parent,
            "registry_path": "docs/parity/reviewer-identities.v1.json",
            "sha256": hashlib.sha256(parent_raw).hexdigest(),
        }}
        resolved, resolved_sha = CHECKER.resolve_approval_registry(
            baseline_path=repo / "docs/parity/baseline.json", review_policy=policy,
            review_trust_dir=repo / ".git/duckpad-review-trust/v1",
            expected_parent_oid=parent,
        )
        self.assertEqual(resolved, parent_raw)
        self.assertEqual(resolved_sha, hashlib.sha256(parent_raw).hexdigest())
        self.assertNotEqual(resolved, registry.read_bytes())

        subprocess.run(["git", "add", str(registry)], cwd=repo, check=True)
        subprocess.run([
            "git", "-c", "user.name=Duckpad Fixture", "-c", "user.email=fixture@duckpad.invalid",
            "commit", "-q", "-m", "new immediate parent",
        ], cwd=repo, check=True)
        immediate_parent = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repo, text=True,
        ).strip()
        with self.assertRaisesRegex(CHECKER.BaselineError, "immediate parent"):
            CHECKER.resolve_approval_registry(
                baseline_path=repo / "docs/parity/baseline.json", review_policy=policy,
                review_trust_dir=repo / ".git/duckpad-review-trust/v1",
                expected_parent_oid=immediate_parent,
            )

    def test_all_normative_contract_mutations_after_signature_are_rejected(self):
        mutations = (
            ("feature-acceptance", lambda b: b["features"][0]["acceptance"].append("Changed after signing.")),
            ("gate-acceptance", lambda b: b["ux_gates"][0]["acceptance"].append("Changed after signing.")),
            ("priority", lambda b: b["features"][0].__setitem__("priority", "P1")),
            ("mapping", lambda b: b["command_mapping_rules"][1].__setitem__("feature_id", "C1.F02")),
            ("workflow", lambda b: b["source"]["workflow_inventory"][0].__setitem__("acceptance", "Changed after signing.")),
            ("weight", lambda b: (b["categories"][0].__setitem__("weight", 15), b["categories"][1].__setitem__("weight", 15))),
            ("defect-policy", lambda b: b["release_gate_policy"].__setitem__("maximum_open_blocker_or_critical_defects", 1)),
        )
        for name, mutate in mutations:
            with self.subTest(mutation=name):
                self.setUp()
                self.release()
                mutate(self.baseline)
                with self.assertRaisesRegex(CHECKER.BaselineError, "contract|attestation"):
                    self.validate()

    def test_declared_parity_contract_digest_mismatch_fails(self):
        self.baseline["parity_contract_sha256"] = "f" * 64
        self.write(refresh_contract=False)
        with self.assertRaisesRegex(CHECKER.BaselineError, "parity contract digest mismatch"):
            CHECKER.validate_and_calculate(self.path)

    def test_release_candidate_artifact_tamper_and_missing_artifact_fail(self):
        for mutation, message in (("manifest", "candidate.sha256"), ("source", "source tree hash"),
                                  ("artifact", "regular file"), ("symlink", "symlink")):
            with self.subTest(mutation=mutation):
                self.setUp(); self.release()
                manifest = self.directory / self.baseline["candidate"]["manifest_path"]
                if mutation == "manifest":
                    manifest.write_text(manifest.read_text() + " ")
                elif mutation == "source":
                    (manifest.parent / "source/Duckpad.swift").write_text("tampered\n")
                elif mutation == "artifact":
                    (manifest.parent / "Duckpad.app.zip").unlink()
                else:
                    target = manifest.parent / "Duckpad.app.zip"
                    moved = manifest.parent / "actual-build.zip"
                    target.rename(moved)
                    target.symlink_to(moved.name)
                with self.assertRaisesRegex(CHECKER.BaselineError, message): self.validate()

    def test_signed_evidence_replay_wrong_signer_and_inactive_reviewer_fail(self):
        for mutation, message in (("candidate_replay", "not bound to the candidate"),
                                  ("feature_replay", "subjects binding"),
                                  ("wrong_signer", "signer does not match"),
                                  ("inactive", "inactive"),
                                  ("builder", "builders mismatch")):
            with self.subTest(mutation=mutation):
                self.setUp(); self.release()
                record = self.baseline["evidence_records"][0]
                if mutation == "candidate_replay":
                    manifest_path = self.directory / self.baseline["candidate"]["manifest_path"]
                    manifest = json.loads(manifest_path.read_text())
                    manifest["id"] = "fixture-release-replayed"
                    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
                    self.baseline["candidate"]["id"] = manifest["id"]
                    self.baseline["candidate"]["sha256"] = digest(manifest_path)
                elif mutation == "feature_replay":
                    record["subjects"] = record["subjects"][1:]
                elif mutation == "wrong_signer":
                    record["reviewer_id"] = "/builder/forged"
                elif mutation == "inactive":
                    registry = json.loads(self.registry.read_text())
                    registry["identities"][0]["status"] = "inactive"
                    self.registry.write_text(json.dumps(registry, indent=2, sort_keys=True) + "\n")
                    self.baseline["review_policy"]["reviewer_registry_sha256"] = digest(self.registry)
                    genesis = seal_genesis_registry(self.authority_repo, self.registry)
                    self.baseline["review_policy"]["approval_registry_source"]["sha256"] = digest(genesis)
                else:
                    self.baseline["review_policy"]["candidate_builder_ids"].append("/reviewer/fixture")
                with self.assertRaisesRegex(CHECKER.BaselineError, message): self.validate()

    def test_receipt_hash_identity_and_candidate_binding_fail(self):
        for mutation in ("hash", "identity", "candidate"):
            with self.subTest(mutation=mutation):
                self.setUp(); self.release()
                rule = next(r for r in self.baseline["command_mapping_rules"] if r["disposition"] == "reviewed_na")
                if mutation == "hash": rule["independent_review"]["receipt_sha256"] = "f"*64
                elif mutation == "identity": rule["independent_review"]["reviewer_id"] = "/root/philosophy_parity"
                else: self.baseline["candidate"]["sha256"] = "3"*64
                with self.assertRaisesRegex(CHECKER.BaselineError, "receipt|candidate"): self.validate()

    def test_unmapped_ambiguous_unused_rules_fail(self):
        variants=[]
        a=copy.deepcopy(self.baseline); a["command_mapping_rules"]=[r for r in a["command_mapping_rules"] if r["id"]!="C1.NEW"]; variants.append((a,"unmapped source command"))
        a=copy.deepcopy(self.baseline); a["command_mapping_rules"].append({"id":"DUP","match":{"symbols":["IDM_FILE_NEW"]},"disposition":"feature","feature_id":"C1.F01"}); variants.append((a,"ambiguous source"))
        a=copy.deepcopy(self.baseline); a["command_mapping_rules"].append({"id":"UNUSED","match":{"symbols":["IDM_NOPE"]},"disposition":"feature","feature_id":"C1.F01"}); variants.append((a,"matched no source"))
        for value,message in variants:
            with self.subTest(message=message):
                with self.assertRaisesRegex(CHECKER.BaselineError,message): self.validate(value)

    def test_rules_regex_and_disposition_fail(self):
        for field,bad,message in (("match",{"regex":"["},"invalid regex"),("disposition","handwave","invalid disposition")):
            value=copy.deepcopy(self.baseline); value["command_mapping_rules"][0][field]=bad
            with self.subTest(field=field):
                with self.assertRaisesRegex(CHECKER.BaselineError,message): self.validate(value)

    def test_workflow_mapping_selector_and_surface_fail(self):
        variants=[]
        a=copy.deepcopy(self.baseline); a["source"]["workflow_inventory"][0]["feature_id"]="C0.NOPE"; variants.append((a,"unmapped workflow ID"))
        a=copy.deepcopy(self.baseline); a["source"]["workflow_inventory"][0]["selectors"]=["["]; variants.append((a,"invalid workflow selector"))
        a=copy.deepcopy(self.baseline); sid=a["source"]["workflow_surfaces"][0]["id"]; a["source"]["workflow_inventory"]=[w for w in a["source"]["workflow_inventory"] if w["surface_id"]!=sid]; variants.append((a,"lack enumerated behaviors"))
        for value,message in variants:
            with self.subTest(message=message):
                with self.assertRaisesRegex(CHECKER.BaselineError,message): self.validate(value)

    def test_explicit_integration_fixture_detects_commit_file_and_false_mapping_drift(self):
        for mutation, message in (("commit", "fixture source commit mismatch"), ("header", "command header"),
                                  ("symbol", "clean before direct audit"), ("surface", "workflow surface"),
                                  ("selector", "differs from its frozen identity")):
            with self.subTest(mutation=mutation):
                self.setUp(); reference = self.integration_reference()
                if mutation == "commit": self.baseline["source"]["commit"] = "f" * 40
                elif mutation == "header": self.baseline["source"]["file_sha256"] = "f" * 64
                elif mutation == "symbol":
                    header = reference / self.baseline["source"]["header_path"]
                    header.write_text(header.read_text() + "#define IDM_FIXTURE_DRIFT 1\n")
                    self.baseline["source"]["file_sha256"] = digest(header)
                elif mutation == "surface": self.baseline["source"]["workflow_surfaces"][0]["sha256"] = "f" * 64
                else: self.baseline["source"]["workflow_inventory"][0]["selectors"] = ["ABSENT_TOKEN"]
                with self.assertRaisesRegex(CHECKER.BaselineError, message):
                    CHECKER.validate_and_calculate(self.write(), integration_reference=reference)

    def test_numeric_types_and_nonfinite_fail(self):
        for bad in ("16", True, 16.5):
            value=copy.deepcopy(self.baseline); value["categories"][0]["weight"]=bad
            with self.subTest(value=bad):
                with self.assertRaisesRegex(CHECKER.BaselineError,"JSON number|sum to 100"): self.validate(value)
        value=copy.deepcopy(self.baseline); value["categories"][0]["weight"]=float("nan")
        self.write(raw=json.dumps(value,allow_nan=True))
        with self.assertRaisesRegex(CHECKER.BaselineError,"invalid JSON"): CHECKER.validate_and_calculate(self.path)
        for bad in (False,"0",0.5):
            value=copy.deepcopy(self.baseline); value["open_blocker_or_critical_defects"]=bad
            with self.assertRaisesRegex(CHECKER.BaselineError,"JSON integer"): self.validate(value)

    def test_duplicate_json_keys_fail_in_all_governance_loaders(self):
        raw = json.dumps(self.baseline, indent=2) + "\n"
        raw = raw.replace('"schema_version": 3,', '"schema_version": 999,\n  "schema_version": 3,', 1)
        self.write(raw=raw)
        with self.assertRaisesRegex(CHECKER.BaselineError, "duplicate JSON key"):
            CHECKER.validate_and_calculate(self.path)

        self.setUp(); self.release()
        manifest = self.directory / self.baseline["candidate"]["manifest_path"]
        raw = manifest.read_text().replace('"schema_version": 1,', '"schema_version": 9,\n  "schema_version": 1,', 1)
        manifest.write_text(raw)
        self.baseline["candidate"]["sha256"] = digest(manifest)
        with self.assertRaisesRegex(CHECKER.BaselineError, "duplicate JSON key"):
            self.validate()

        self.setUp()
        workflow = self.directory / "duplicate-workflow.json"
        raw = (ROOT / "docs/parity/notepad-plus-plus-workflow-inventory.v1.json").read_text()
        workflow.write_text(raw.replace('"schema_version": 1,', '"schema_version": 9,\n  "schema_version": 1,', 1))
        workflow.with_suffix(".sha256").write_text(f"{digest(workflow)}  {workflow.name}\n")
        self.baseline["source"]["workflow_fixture_path"] = workflow.name
        self.baseline["source"]["workflow_fixture_sha256"] = digest(workflow)
        with self.assertRaisesRegex(CHECKER.BaselineError, "duplicate JSON key"):
            self.validate()

        self.setUp(); self.release()
        result = self.directory / "E.AUTOMATED.result.json"
        raw = result.read_text().replace('"status": "pass"', '"status": "fail",\n  "status": "pass"', 1)
        result.write_text(raw)
        payload = json.loads((self.directory / "E.AUTOMATED.payload.json").read_text())
        payload["result_artifact_sha256"] = digest(result)
        attestation = self.sign(payload, "duplicate-result")
        record = self.baseline["evidence_records"][0]
        record.update(attestation_path=attestation.name, attestation_sha256=digest(attestation))
        with self.assertRaisesRegex(CHECKER.BaselineError, "duplicate JSON key"):
            self.validate()

    def test_sidecar_missing_and_drift_fail(self):
        self.write(sidecar=False)
        with self.assertRaisesRegex(CHECKER.BaselineError,"missing checksum"): CHECKER.validate_and_calculate(self.path)
        self.path.with_suffix(".sha256").write_text(f"{'0'*64}  {self.path.name}\n")
        with self.assertRaisesRegex(CHECKER.BaselineError,"checksum mismatch"): CHECKER.validate_and_calculate(self.path)

    def test_python_bytecode_is_excluded_from_candidate(self):
        for path in ("scripts/__pycache__/checker.pyc", "scripts/review/__pycache__/review_common.pyc",
                     "tests/governance/__pycache__/test_review_gate.pyo"):
            result = subprocess.run(["git", "check-ignore", "-q", path], cwd=ROOT)
            self.assertEqual(result.returncode, 0, path)
        staged = subprocess.check_output(["git", "diff", "--cached", "--name-only"], cwd=ROOT, text=True)
        self.assertNotIn("__pycache__", staged)
        forbidden = [
            path for path in ROOT.rglob("*")
            if ".git" not in path.parts and "notepad-plus-plus" not in path.parts
            and (path.name in {"__pycache__", ".pytest_cache"} or path.suffix in {".pyc", ".pyo"})
        ]
        self.assertEqual(forbidden, [], f"repository cache artifacts must be removed: {forbidden}")

    def test_cli_release_requirement(self):
        failed=subprocess.run([sys.executable,"-B",str(SCRIPT),"--require-release-pass"],cwd=ROOT)
        self.assertEqual(failed.returncode,2)
        self.write(self.release())
        passed=subprocess.run([sys.executable,"-B",str(SCRIPT),"--baseline",str(self.path),
            "--review-trust-dir",str(self.trust),"--require-release-pass"],cwd=ROOT)
        self.assertEqual(passed.returncode,0)

    def test_cli_report_contains_exhaustive_command_map(self):
        result=subprocess.run([sys.executable,"-B",str(SCRIPT),"--report"],cwd=ROOT,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        report=json.loads(result.stdout)
        self.assertEqual(len(report["command_map"]),530)

    def test_frozen_workflow_removal_extra_and_duplicate_ownership_fail(self):
        variants=[]
        a=copy.deepcopy(self.baseline); a["source"]["workflow_inventory"]=[w for w in a["source"]["workflow_inventory"] if w["id"]!="WF.C2.F12"]; variants.append((a,"differs from frozen fixture"))
        a=copy.deepcopy(self.baseline); extra=copy.deepcopy(a["source"]["workflow_inventory"][0]); extra["id"]="WF.EXTRA"; extra["selectors"]=["UNIQUE_EXTRA_SELECTOR"]; a["source"]["workflow_inventory"].append(extra); variants.append((a,"differs from frozen fixture"))
        a=copy.deepcopy(self.baseline); duplicate=copy.deepcopy(a["source"]["workflow_inventory"][0]); duplicate["id"]="WF.DUPLICATE"; a["source"]["workflow_inventory"].append(duplicate); variants.append((a,"duplicate workflow selector ownership"))
        for value,message in variants:
            with self.subTest(message=message):
                with self.assertRaisesRegex(CHECKER.BaselineError,message): self.validate(value)

    def test_setup_rejects_root_symlink_escape_unsafe_parent_and_unrelated_repo(self):
        outside=tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        symlink=ROOT/(".setup-symlink-"+self.directory.name)
        symlink.symlink_to(outside.name, target_is_directory=True)
        self.addCleanup(symlink.unlink)
        parent_symlink=ROOT/(".setup-parent-symlink-"+self.directory.name)
        parent_symlink.symlink_to(outside.name, target_is_directory=True)
        self.addCleanup(parent_symlink.unlink)
        nested=self.directory/"nested"
        nested.mkdir()
        unrelated=tempfile.TemporaryDirectory(prefix=".setup-unrelated-",dir=ROOT)
        self.addCleanup(unrelated.cleanup)
        subprocess.run(["git","init","-q"],cwd=unrelated.name,check=True)
        subprocess.run(["git","remote","add","origin","https://example.invalid/unrelated.git"],cwd=unrelated.name,check=True)
        cases=((".","unsafe reference target"),(str(symlink),"symlink reference target"),
               (str(parent_symlink/"reference"),"direct child"),
               (str(nested/"reference"),"direct child"),(unrelated.name,"unrelated repository"))
        for target,message in cases:
            with self.subTest(target=target):
                result=subprocess.run([str(SETUP_SCRIPT),target],cwd=ROOT,capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
                self.assertIn(message,result.stderr)


if __name__ == "__main__": unittest.main()
