#!/usr/bin/env python3
"""Explicit pinned-source adversarial tests; never part of the reference-free suite."""

import copy
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests.test_parity_baseline import CHECKER, PRODUCTION, ROOT, SETUP_SCRIPT, digest


REFERENCE_VALUE = os.environ.get("DUCKPAD_NPP_REFERENCE")


@unittest.skipUnless(REFERENCE_VALUE, "set DUCKPAD_NPP_REFERENCE for explicit pinned integration")
class FrozenWorkflowPinnedIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.reference = Path(REFERENCE_VALUE).resolve()
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tests")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.path = self.directory / "baseline.json"
        self.baseline = json.loads(PRODUCTION.read_text())
        for field, source_path in (
            ("symbol_fixture_path", ROOT / "tests/fixtures/menuCmdID.v1.symbols"),
            ("workflow_fixture_path", ROOT / "docs/parity/notepad-plus-plus-workflow-inventory.v1.json"),
        ):
            self.baseline["source"][field] = os.path.relpath(source_path, self.directory)
        registry = self.directory / "reviewer-identities.json"
        registry.write_bytes((ROOT / "docs/parity/reviewer-identities.v1.json").read_bytes())
        self.baseline["review_policy"]["reviewer_registry_path"] = registry.name
        self.baseline["review_policy"]["reviewer_registry_sha256"] = digest(registry)

    def write(self):
        self.baseline["parity_contract_sha256"] = CHECKER.parity_contract_sha256(self.baseline)
        self.path.write_text(json.dumps(self.baseline, indent=2) + "\n")
        self.path.with_suffix(".sha256").write_text(f"{digest(self.path)}  {self.path.name}\n")
        return self.path

    def install_mutated_fixture(self, fixture):
        fixture_path = self.directory / "workflow-fixture.json"
        fixture_path.write_text(json.dumps(fixture, indent=2) + "\n")
        fixture_path.with_suffix(".sha256").write_text(
            f"{digest(fixture_path)}  {fixture_path.name}\n"
        )
        self.baseline["source"]["workflow_fixture_path"] = fixture_path.name
        self.baseline["source"]["workflow_fixture_sha256"] = digest(fixture_path)

    def validate(self):
        return CHECKER.validate_and_calculate(self.write(), integration_reference=self.reference)

    def test_pinned_reference_positive_control(self):
        self.assertTrue(self.validate()["integration_reference_audited"])

    def test_removed_frozen_workflow_fails(self):
        self.baseline["source"]["workflow_inventory"] = [
            workflow for workflow in self.baseline["source"]["workflow_inventory"]
            if workflow["id"] != "WF.C2.F12"
        ]
        with self.assertRaisesRegex(CHECKER.BaselineError, "missing=.*WF.C2.F12"):
            self.validate()

    def test_duplicate_selector_ownership_fails(self):
        duplicate = copy.deepcopy(self.baseline["source"]["workflow_inventory"][0])
        duplicate["id"] = "WF.DUPLICATE.OWNERSHIP"
        duplicate["feature_id"] = "C4.F03"
        self.baseline["source"]["workflow_inventory"].append(duplicate)
        with self.assertRaisesRegex(CHECKER.BaselineError, "duplicate workflow selector ownership"):
            self.validate()

    def test_expected_occurrence_drift_fails(self):
        fixture = json.loads((ROOT / "docs/parity/notepad-plus-plus-workflow-inventory.v1.json").read_text())
        fixture["workflows"][0]["expected_occurrences"] += 1
        self.baseline["source"]["workflow_inventory"][0]["expected_occurrences"] += 1
        self.install_mutated_fixture(fixture)
        with self.assertRaisesRegex(CHECKER.BaselineError, "workflow occurrence drift"):
            self.validate()

    def test_overlapping_selector_ownership_fails(self):
        fixture = json.loads((ROOT / "docs/parity/notepad-plus-plus-workflow-inventory.v1.json").read_text())
        selector = "CurrentBuffer"
        text = (self.reference / "PowerEditor/src/Notepad_plus.cpp").read_text(encoding="utf-8-sig")
        workflow = {
            "id": "WF.OVERLAP.CURRENT_BUFFER",
            "surface_id": "SURFACE.DYNAMIC_HOST",
            "feature_id": "C1.F06",
            "selectors": [selector],
            "expected_occurrences": len(list(re.finditer(selector, text))),
            "acceptance": "Synthetic overlap must be rejected before it can own source behavior.",
        }
        self.baseline["source"]["workflow_inventory"].append(workflow)
        fixture["workflows"].append({
            "id": workflow["id"], "surface_id": workflow["surface_id"],
            "feature_id": workflow["feature_id"], "selector": selector,
            "expected_occurrences": len(list(re.finditer(selector, text))),
        })
        self.install_mutated_fixture(fixture)
        with self.assertRaisesRegex(CHECKER.BaselineError, "overlapping workflow selector ownership"):
            self.validate()

    def test_setup_rejects_dirty_repository_already_at_pin(self):
        target = Path(tempfile.mkdtemp(prefix=".setup-dirty-pin-", dir=ROOT))
        target.rmdir()
        self.addCleanup(lambda: shutil.rmtree(target, ignore_errors=True))
        subprocess.run(["git", "clone", "-q", "--shared", str(self.reference), str(target)], check=True)
        subprocess.run([
            "git", "-C", str(target), "remote", "set-url", "origin",
            "https://github.com/notepad-plus-plus/notepad-plus-plus.git",
        ], check=True)
        before = subprocess.check_output(["git", "-C", str(target), "rev-parse", "HEAD"], text=True).strip()
        self.assertEqual(before, self.baseline["source"]["commit"])
        dirty = target / "dirty-at-pin.fixture"
        dirty.write_text("must survive rejected setup\n")
        result = subprocess.run([str(SETUP_SCRIPT), str(target)], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dirty before setup", result.stderr)
        self.assertTrue(dirty.exists())
        self.assertEqual(before, subprocess.check_output(["git", "-C", str(target), "rev-parse", "HEAD"], text=True).strip())

    def test_direct_integration_rejects_dirty_reference(self):
        sentinel = self.reference / "direct-audit-dirty.fixture"
        sentinel.write_text("direct audit must reject untracked state\n")
        self.addCleanup(lambda: sentinel.unlink(missing_ok=True))
        with self.assertRaisesRegex(CHECKER.BaselineError, "clean before direct audit"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
