#!/usr/bin/env python3
"""Check the distribution check: it reports, and it reports failures."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "script/verify_distro.sh"
PEER = REPO / "peer/desktop_link_peer.py"


@unittest.skipUnless(Path("/etc/os-release").is_file(), "the check reads /etc/os-release")
class VerifyDistroTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-distro-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.report = self.root / "report.md"
        self.env = os.environ | {"HOME": str(self.root)}
        self.env.pop("WAYLAND_DISPLAY", None)
        self.env.pop("DISPLAY", None)

    def run_check(self, peer):
        return subprocess.run(
            ["bash", str(SCRIPT), "--report", str(self.report)],
            env=self.env | {"HANDOFF_FOX_PEER": str(peer)},
            capture_output=True, text=True, timeout=120,
        )

    def test_reports_the_receiver_answering(self):
        run = self.run_check(PEER)
        self.assertIn(run.returncode, (0, 1), run.stderr)
        text = self.report.read_text()
        self.assertIn("| Receiver present | pass |", text)
        self.assertIn("| Pair: receiver answers | pass |", text)
        self.assertIn("| Receiver action: job-list | pass |", text)
        self.assertIn("## Still needs the Mac half", text)
        self.assertIn("Another Hyprland distro", text)

    def test_names_the_distribution_it_saw(self):
        self.run_check(PEER)
        text = self.report.read_text()
        release = dict(
            line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line
        )
        identifier = release["ID"].strip('"')
        self.assertIn(identifier, text)
        self.assertIn("- Distribution: ", text)
        self.assertIn("- Session: ", text)
        hostname = os.uname().nodename
        self.assertNotIn(hostname, text, "the report should not name the host")

    def test_a_missing_receiver_still_produces_a_report(self):
        run = self.run_check(self.root / "absent.py")
        self.assertEqual(run.returncode, 1, run.stderr)
        text = self.report.read_text()
        self.assertIn("| Receiver present | fail |", text)
        self.assertIn("| Pair: receiver answers | fail |", text)
        self.assertIn("stage(s) failed", run.stderr)


if __name__ == "__main__":
    unittest.main()
