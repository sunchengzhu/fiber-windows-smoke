"""Guard the daily workflow's separation from manual node maintenance."""

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DailyWorkflowContractTests(unittest.TestCase):
    def test_daily_workflow_never_installs_migrates_or_opens_channels(self):
        workflow = (ROOT / ".github/workflows/fiber-node-maintenance.yml").read_text()
        for forbidden in ("Update-FiberBinary", "Install-FiberService", "Install-SecondNode", "Ensure-Channel", "Ensure-SecondNodeChannel", "Invoke-WebRequest", "Stop-Service", "Start-Service", "ensure_channel"):
            self.assertNotIn(forbidden, workflow)
        self.assertLess(workflow.index("id: versions"), workflow.index("id: payment_scheduled"))
        version_step = workflow[workflow.index("      - name: Verify installed"):workflow.index("      - name: Run module")]
        self.assertIn("scripts\\Test-InstalledFiber.ps1", version_step)
        self.assertNotIn("continue-on-error", version_step)

    def test_version_baseline_is_explicit_and_independent_of_latest_release(self):
        baseline = json.loads((ROOT / "config/tested-fiber-release.json").read_text())
        self.assertRegex(baseline["tag"], r"^v\d+\.\d+\.\d+$")
        self.assertRegex(baseline["commit"], r"^[0-9a-f]{40}$")
        self.assertEqual(baseline["repository"], "nervosnetwork/fiber")
        verifier = (ROOT / "scripts/Test-InstalledFiber.ps1").read_text()
        for forbidden in ("Update-FiberBinary", "Stop-Service", "Start-Service", "Stop-FiberService", "Start-FiberService", "Invoke-WebRequest"):
            self.assertNotIn(forbidden, verifier)
        self.assertIn("Get-LatestStableFiberRelease", verifier)

    def test_manual_update_requires_an_explicit_target_before_side_effects(self):
        script = (ROOT / "scripts/Update-FiberBinary.ps1").read_text()
        guard = script.index('if ([string]::IsNullOrWhiteSpace($ReleaseTag))')
        self.assertLess(guard, script.index("Import-Module"))
        self.assertIn("Get-FiberRelease -Settings $settings -ReleaseTag $ReleaseTag", script)


if __name__ == "__main__":
    unittest.main()
