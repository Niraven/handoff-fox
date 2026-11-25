#!/usr/bin/env python3
"""Run isolated Handoff Fox preset-saving regressions with unittest."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PEER = Path(__file__).resolve().parents[1] / "peer/desktop_link_peer.py"


class SavePresetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-presets-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.config = self.root / ".config/desktop-link/projects.json"
        self.config.parent.mkdir(parents=True)
        self.env = os.environ | {
            "HOME": str(self.root),
            "XDG_CONFIG_HOME": str(self.root / ".config"),
            "XDG_STATE_HOME": str(self.root / ".state"),
        }
        self.configure()

    def configure(self, presets=None):
        self.config.write_text(json.dumps({"projects": [{
            "id": "project", "name": "Project", "path": str(self.project),
            "presets": presets if presets is not None else [],
        }]}))

    def script(self, name="test.sh", mode=0o755):
        path = self.project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(mode)
        return path

    def invoke(self, action, **fields):
        run = subprocess.run(
            [sys.executable, str(PEER)], env=self.env, capture_output=True, timeout=12,
            input=json.dumps({"version": 1, "action": action, **fields}).encode(),
        )
        self.assertEqual(run.returncode, 0, run.stderr.decode(errors="replace"))
        return json.loads(run.stdout)

    def save(self, name, argv, artifact=None):
        fields = {"project": "project", "name": name, "argv": argv}
        if artifact is not None:
            fields["artifact"] = artifact
        return self.invoke("save-preset", **fields)

    def stored(self):
        return json.loads(self.config.read_text())["projects"][0].get("presets", [])

    def test_saved_preset_appears_in_the_display_shape(self):
        self.script()
        reply = self.save("Test Suite", ["./test.sh", "--fast"], "out/report.txt")
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["projects"], [{
            "id": "project", "name": "Project", "canBuild": False,
            "presets": [{"id": "test-suite", "name": "Test Suite"}],
        }])
        self.assertEqual(self.stored(), [{"id": "test-suite", "name": "Test Suite",
                                          "argv": ["./test.sh", "--fast"],
                                          "artifact": "out/report.txt"}])

    def test_slash_free_command_is_stored_as_a_project_path(self):
        self.script()
        reply = self.save("Test", ["test.sh", "--fast"])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(self.stored(), [{"id": "test", "name": "Test",
                                          "argv": ["./test.sh", "--fast"]}])

    def test_nonexecutable_file_is_refused(self):
        self.script(mode=0o644)
        reply = self.save("Test", ["./test.sh"])
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"],
                         "The preset command must be an executable file inside the project.")
        self.assertEqual(self.stored(), [])

    def test_absolute_command_is_refused(self):
        executable = self.script()
        reply = self.save("Test", [str(executable)])
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"],
                         "Start the preset with a relative command path inside the project.")
        self.assertEqual(self.stored(), [])

    def test_parent_relative_command_and_artifact_are_refused(self):
        outside = self.root / "outside.sh"
        outside.write_text("#!/bin/sh\n")
        outside.chmod(0o755)
        self.script()
        reply = self.save("Escape", ["../outside.sh"])
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"],
                         "Start the preset with a relative command path inside the project.")
        reply = self.save("Artifact", ["./test.sh"], "../escape.txt")
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"],
                         "Make the preset artifact a relative path inside the project.")
        self.assertEqual(self.stored(), [])

    def test_symlink_outside_the_project_is_refused(self):
        outside = self.root / "outside.sh"
        outside.write_text("#!/bin/sh\n")
        outside.chmod(0o755)
        (self.project / "linked.sh").symlink_to(outside)
        reply = self.save("Linked", ["./linked.sh"])
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"],
                         "The preset command must be an executable file inside the project.")
        self.assertEqual(self.stored(), [])

    def test_duplicate_name_or_identifier_is_refused_by_name(self):
        self.script()
        self.configure([{"id": "test", "name": "Test", "argv": ["./test.sh"]}])
        for name in ("Test", "TEST", "test"):
            with self.subTest(name=name):
                reply = self.save(name, ["./test.sh"])
                self.assertFalse(reply["ok"], reply)
                self.assertEqual(reply["error"], "This project already has a preset named Test.")
        self.assertEqual(len(self.stored()), 1)

    def test_preset_limit_is_enforced(self):
        self.script()
        self.configure([{"id": f"p{index}", "name": f"Preset {index}", "argv": ["./test.sh"]}
                        for index in range(1, 20)])
        self.assertTrue(self.save("Twentieth", ["./test.sh"])["ok"])
        reply = self.save("Twenty First", ["./test.sh"])
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["error"], "A project can hold up to 20 presets.")
        self.assertEqual(len(self.stored()), 20)

    def test_concurrent_saves_keep_every_preset(self):
        self.script()
        names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"]
        with ThreadPoolExecutor(max_workers=len(names)) as pool:
            replies = list(pool.map(lambda name: self.save(name, ["./test.sh"]), names))
        self.assertTrue(all(reply["ok"] for reply in replies), replies)
        self.assertEqual(sorted(preset["name"] for preset in self.stored()), names)
        self.assertEqual(len({preset["id"] for preset in self.stored()}), len(names))


if __name__ == "__main__":
    unittest.main()
