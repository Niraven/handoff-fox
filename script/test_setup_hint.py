#!/usr/bin/env python3
"""Check the Handoff Fox Gliff setup hint against fake release and PATH fixtures."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


PEER = Path(__file__).resolve().parents[1] / "peer/desktop_link_peer.py"


def load_peer():
    spec = importlib.util.spec_from_file_location("handoff_fox_peer_setup", PEER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SetupHintTests(unittest.TestCase):
    def setUp(self):
        self.peer = load_peer()
        temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-setup-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.binaries = self.root / "bin"
        self.binaries.mkdir()
        self.release = self.root / "os-release"
        self.release.write_text('NAME="Omarchy"\nID=omarchy\nID_LIKE=arch\n')

    def install(self, *names):
        for name in names:
            program = self.binaries / name
            program.write_text("#!/bin/sh\nexit 1\n")
            program.chmod(0o755)

    def hint(self):
        with patch.dict(os.environ, {"PATH": str(self.binaries)}):
            return self.peer.setup_hint(self.release)

    def test_omarchy_release_with_omarchy_uses_its_package_manager(self):
        self.install("omarchy", "pacman", "yay")
        self.assertEqual(self.hint(), {
            "packageManager": "omarchy", "command": "omarchy pkg add gliff",
            "docs": "https://github.com/omacom/gliff", "gliffInstalled": False,
        })

    def test_debian_answers_with_the_docs_link_and_no_command(self):
        self.install("apt-get")
        self.release.write_text('ID=ubuntu\nID_LIKE=debian\n')
        self.assertEqual(self.hint(), {
            "packageManager": "debian", "command": None,
            "docs": "https://github.com/omacom/gliff", "gliffInstalled": False,
        })

    def test_pacman_without_an_aur_helper_names_no_command(self):
        self.install("pacman")
        hint = self.hint()
        self.assertEqual((hint["packageManager"], hint["command"]), ("pacman", None))
        self.install("paru")
        self.assertEqual(self.hint()["command"], "yay -S gliff")

    def test_unknown_system_names_no_command(self):
        self.release.write_text("ID=source\n")
        self.assertEqual(self.hint(), {
            "packageManager": "unknown", "command": None,
            "docs": "https://github.com/omacom/gliff", "gliffInstalled": False,
        })

    def test_installed_gliff_server_is_reported(self):
        self.install("apt-get", "gliff-server")
        hint = self.hint()
        self.assertIs(hint["gliffInstalled"], True)

    def test_existing_helper_keeps_the_docs_link_when_the_release_is_unreadable(self):
        self.install("dnf")
        with patch.dict(os.environ, {"PATH": str(self.binaries)}):
            hint = self.peer.setup_hint(self.root / "missing-os-release")
        self.assertEqual((hint["packageManager"], hint["command"]), ("fedora", None))
        self.assertEqual(hint["docs"], "https://github.com/omacom/gliff")


if __name__ == "__main__":
    unittest.main()
