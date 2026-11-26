#!/usr/bin/env python3
"""Check the three Linux installers into a throwaway home directory.

Nothing here touches the machine it runs on: every installer is pointed at a
temporary HOME, a temporary XDG_DATA_HOME, and a temporary XDG_CONFIG_HOME, and
the commands they expect from the desktop session are stand-ins on PATH.
"""

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HYPRELAND_RELOAD = "#!/bin/sh\nexit 0\n"


class InstallerTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-install-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        for directory in (self.home, self.bin):
            directory.mkdir()
        self.env = {
            "HOME": str(self.home),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
        }

    def run_installer(self, name, **overrides):
        return subprocess.run(
            ["bash", str(REPO / "script" / name)], env=self.env | overrides,
            capture_output=True, text=True, timeout=120,
        )

    def assert_executable(self, path):
        mode = path.stat().st_mode
        self.assertTrue(path.is_file(), f"{path} was not installed")
        self.assertTrue(mode & stat.S_IXUSR, f"{path} is not executable")


class PeerInstallerTests(InstallerTestCase):
    def test_installs_a_receiver_that_answers(self):
        run = self.run_installer("install_peer.sh")
        self.assertEqual(run.returncode, 0, run.stderr)
        installed = self.home / ".local/bin/desktop-link-peer"
        self.assert_executable(installed)
        self.assertEqual(installed.read_bytes(), (REPO / "peer/desktop_link_peer.py").read_bytes())

        reply = subprocess.run(
            ["bash", "-c", ".local/bin/desktop-link-peer"], cwd=self.home, env=self.env,
            input=b'{"version": 1, "action": "pair"}', capture_output=True, timeout=60,
        )
        self.assertEqual(reply.returncode, 0, reply.stderr.decode(errors="replace"))
        self.assertTrue(json.loads(reply.stdout.decode().splitlines()[-1])["ok"])

    def test_runs_twice_without_complaint(self):
        for _ in range(2):
            run = self.run_installer("install_peer.sh")
            self.assertEqual(run.returncode, 0, run.stderr)
        self.assert_executable(self.home / ".local/bin/desktop-link-peer")


class TrayInstallerTests(InstallerTestCase):
    def install(self):
        run = self.run_installer("install_omarchy.sh")
        self.assertEqual(run.returncode, 0, run.stderr)
        return run

    def test_installs_every_file_the_tray_needs(self):
        self.install()
        data = Path(self.env["XDG_DATA_HOME"])
        self.assert_executable(self.home / ".local/bin/desktop-link")
        self.assertEqual((self.home / ".local/bin/desktop-link").read_bytes(),
                         (REPO / "omarchy/desktop_link.py").read_bytes())
        for asset in ("TrayFox.png", "FoxRest.png", "FoxAlert.png"):
            installed = data / "desktop-link" / asset
            self.assertTrue(installed.is_file(), f"{asset} is missing")
            self.assertEqual(installed.read_bytes(), (REPO / "assets" / asset).read_bytes(),
                             f"{asset} is not the file it claims to be")
        icons = list((data / "icons/hicolor/512x512/apps").glob("*.png"))
        self.assertEqual(len(icons), 1, "the tray icon was not installed")
        self.assertEqual(icons[0].read_bytes(), (REPO / "assets/DesktopLink.png").read_bytes())

    def test_writes_a_launcher_and_an_autostart_entry(self):
        self.install()
        data = Path(self.env["XDG_DATA_HOME"])
        config = Path(self.env["XDG_CONFIG_HOME"])
        applications = list((data / "applications").glob("*.desktop"))
        autostart = list((config / "autostart").glob("*.desktop"))
        self.assertEqual(len(applications), 1)
        self.assertEqual(len(autostart), 1)
        launcher = str(self.home / ".local/bin/desktop-link")
        self.assertIn(f'Exec="{launcher}"', applications[0].read_text())
        self.assertIn(f'Exec="{launcher}" --tray', autostart[0].read_text())
        icon = Path(applications[0].read_text().split("Icon=", 1)[1].splitlines()[0])
        self.assertEqual(len(list((data / "icons/hicolor/512x512/apps").glob(f"{icon.name}.png"))), 1,
                         "the launcher names an icon that was not installed")

    def test_reports_status_after_installing(self):
        run = self.install()
        self.assertEqual(json.loads(run.stdout.strip().splitlines()[-1]),
                         {"active": False, "connected": False})


class HotkeyInstallerTests(InstallerTestCase):
    def setUp(self):
        super().setUp()
        hypr = Path(self.env["XDG_CONFIG_HOME"]) / "hypr"
        hypr.mkdir(parents=True)
        self.bindings = hypr / "bindings.lua"
        self.bindings.write_text('hl.bind("SUPER + Q", hl.dsp.window.close())\n')
        reload = self.bin / "hyprctl"
        reload.write_text(HYPRELAND_RELOAD)
        reload.chmod(0o755)

    def test_adds_the_binding_once(self):
        for _ in range(2):
            run = self.run_installer("install_hypr_hotkey.sh")
            self.assertEqual(run.returncode, 0, run.stderr)
        module = Path(self.env["XDG_CONFIG_HOME"]) / "hypr/handoff-fox.lua"
        self.assertTrue(module.is_file())
        text = module.read_text()
        self.assertIn("CTRL + ALT + J", text)
        self.assertIn(str(self.home / ".local/bin/desktop-link"), text)
        self.assertEqual(self.bindings.read_text().count('require("hypr.handoff-fox")'), 1,
                         "the binding was added twice")
        self.assertIn('hl.bind("SUPER + Q"', self.bindings.read_text())

    def test_refuses_without_a_hyprland_configuration(self):
        self.bindings.unlink()
        run = self.run_installer("install_hypr_hotkey.sh")
        self.assertNotEqual(run.returncode, 0)


if __name__ == "__main__":
    unittest.main()
