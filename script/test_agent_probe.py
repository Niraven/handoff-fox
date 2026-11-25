#!/usr/bin/env python3
"""Check the read-only agent probe against a stand-in tmux."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PEER = Path(__file__).resolve().parents[1] / "peer/desktop_link_peer.py"

PANES = "\n".join([
    "work\t0.0\tclaude\tClaude Code",
    "work\t0.1\tzsh\tnotes",
    "infra\t1.0\tcodex\tcodex session",
    "infra\t1.1\tnode\tvite",
]) + "\n"


class AgentProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-agents-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ | {
            "HOME": str(self.root),
            "XDG_CONFIG_HOME": str(self.root / ".config"),
            "XDG_STATE_HOME": str(self.root / ".state"),
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
        }

    def install_tmux(self, panes=PANES, exit_code=0):
        script = self.bin / "tmux"
        script.write_text(
            "#!/bin/sh\n"
            f"cat <<'PANES'\n{panes}PANES\n"
            f"exit {exit_code}\n"
        )
        script.chmod(0o755)

    def request(self, action, **fields):
        run = subprocess.run(
            [sys.executable, str(PEER)], env=self.env, capture_output=True, timeout=12,
            input=json.dumps({"version": 1, "action": action, **fields}).encode(),
        )
        self.assertEqual(run.returncode, 0, run.stderr.decode(errors="replace"))
        reply = json.loads(run.stdout)
        self.assertTrue(reply["ok"], reply)
        return reply

    def test_reports_agent_panes_and_nothing_else(self):
        self.install_tmux()
        agents = self.request("agents")["agents"]
        self.assertEqual([entry["agent"] for entry in agents], ["Claude", "Codex"])
        self.assertEqual([entry["session"] for entry in agents], ["work", "infra"])
        self.assertEqual(agents[0]["pane"], "0.0")

    def test_missing_tmux_is_an_empty_answer(self):
        agents = self.request("agents")["agents"]
        self.assertEqual(agents, [])

    def test_failed_listing_is_an_empty_answer(self):
        self.install_tmux(exit_code=1)
        self.assertEqual(self.request("agents")["agents"], [])

    def test_malformed_lines_are_ignored(self):
        self.install_tmux(panes="work\t0.0\tclaude\tClaude Code\nnot a pane line\n")
        agents = self.request("agents")["agents"]
        self.assertEqual(len(agents), 1)
        self.assertEqual(agents[0]["agent"], "Claude")

    def test_the_probe_reports_no_paths_or_commands(self):
        self.install_tmux(panes="secret\t0.0\tclaude\t/home/you/private/client-name\n")
        entry = self.request("agents")["agents"][0]
        self.assertEqual(set(entry), {"agent", "session", "pane"})


if __name__ == "__main__":
    unittest.main()
