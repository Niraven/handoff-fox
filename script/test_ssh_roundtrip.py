#!/usr/bin/env python3
"""Check the SSH transport the Mac actually uses, against a real sshd.

The other receiver tests call the script directly. This one starts a local
sshd, installs the receiver the way the app does, and runs the same remote
command the app runs.
"""

import getpass
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "peer/desktop_link_peer.py"
REMOTE_COMMAND = ".local/bin/desktop-link-peer"
INSTALLED = Path.home() / ".local/bin/desktop-link-peer"

INSTALLER = """
import hashlib, os, pathlib, sys, tempfile
if sys.version_info < (3, 9):
    sys.exit(83)
data = sys.stdin.buffer.read(131073)
if len(data) > 131072 or hashlib.sha256(data).hexdigest() != sys.argv[1]:
    sys.exit(85)
destination = pathlib.Path.home() / ".local/bin/desktop-link-peer"
destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(dir=destination.parent) as staged:
    staged.write(data)
    staged.flush()
    os.fchmod(staged.fileno(), 0o755)
    try:
        os.link(staged.name, destination)
    except FileExistsError:
        pass
"""


def unavailable_reason():
    if os.geteuid() == 0:
        return "the test runs against an sshd it starts as a normal user"
    if INSTALLED.exists():
        return "a receiver is already installed in this home directory"
    if not Path("/usr/sbin/sshd").is_file() or not shutil.which("ssh") or not shutil.which("ssh-keygen"):
        return "sshd or the OpenSSH client is missing"
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return "starting sshd needs passwordless sudo"
    return None


REASON = unavailable_reason()


@unittest.skipIf(REASON is not None, REASON or "")
class SshTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-ssh-")
        cls.root = Path(cls.temporary.name)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            cls.port = probe.getsockname()[1]
        host_key = cls.root / "host_ed25519"
        client_key = cls.root / "client_ed25519"
        for key in (host_key, client_key):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        authorized = cls.root / "authorized_keys"
        authorized.write_text(client_key.with_suffix(".pub").read_text())
        authorized.chmod(0o600)
        cls.config = cls.root / "sshd_config"
        cls.config.write_text(
            f"Port {cls.port}\n"
            f"ListenAddress 127.0.0.1\n"
            f"HostKey {host_key}\n"
            f"PidFile {cls.root / 'sshd.pid'}\n"
            f"AuthorizedKeysFile {authorized}\n"
            "PasswordAuthentication no\n"
            "KbdInteractiveAuthentication no\n"
            "PermitRootLogin no\n"
            "UsePAM no\n"
            "StrictModes no\n"
            "LogLevel QUIET\n"
        )
        # sshd refuses to start without its privilege separation directory, which
        # a container or a fresh runner can lack even when /usr/sbin/sshd exists.
        subprocess.run(["sudo", "-n", "mkdir", "-p", "/run/sshd"], capture_output=True)
        cls.errors = cls.root / "sshd.log"
        with cls.errors.open("wb") as log:
            cls.sshd = subprocess.Popen(["sudo", "-n", "/usr/sbin/sshd", "-D", "-f", str(cls.config)],
                                        stdout=log, stderr=log)
        cls.addClassCleanup(cls.stop)
        cls.addClassCleanup(cls.temporary.cleanup)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", cls.port)) == 0:
                    return
            time.sleep(0.1)
        reason = cls.errors.read_text(errors="replace").strip().splitlines()
        raise unittest.SkipTest("the local sshd did not start" + (f": {reason[-1]}" if reason else ""))

    @classmethod
    def stop(cls):
        cls.sshd.terminate()
        try:
            cls.sshd.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.sshd.kill()

    def ssh(self, command, payload=b"", extra=()):
        return subprocess.run(
            ["ssh", "-T", "-p", str(self.port), "-i", str(self.root / "client_ed25519"),
             "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=" + str(self.root / "known_hosts"),
             "-o", "ConnectTimeout=5", "-o", "ControlMaster=no", *extra,
             "--", f"{getpass.getuser()}@127.0.0.1", command],
            input=payload, capture_output=True, timeout=60,
        )

    def test_a_missing_receiver_fails_the_way_the_app_expects(self):
        run = self.ssh(REMOTE_COMMAND, b'{"version": 1, "action": "pair"}')
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(run.returncode, 127, run.stderr.decode(errors="replace"))

    def test_the_app_bootstrap_installs_and_the_receiver_answers(self):
        self.addCleanup(lambda: INSTALLED.unlink(missing_ok=True))
        script = SOURCE.read_bytes()
        digest = hashlib.sha256(script).hexdigest()
        install = self.ssh(f"python3 -c '{INSTALLER}' {digest}", script)
        self.assertEqual(install.returncode, 0, install.stderr.decode(errors="replace"))
        self.assertTrue(INSTALLED.is_file(), "the bootstrap did not install the receiver")
        self.assertTrue(os.access(INSTALLED, os.X_OK), "the receiver is not executable")

        run = self.ssh(REMOTE_COMMAND, b'{"version": 1, "action": "pair"}')
        self.assertEqual(run.returncode, 0, run.stderr.decode(errors="replace"))
        reply = json.loads(run.stdout.decode().splitlines()[-1])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["system"], "Linux")
        self.assertEqual(reply["version"], 1)

    def test_the_bootstrap_refuses_a_different_script(self):
        self.addCleanup(lambda: INSTALLED.unlink(missing_ok=True))
        wrong = hashlib.sha256(b"not the receiver").hexdigest()
        run = self.ssh(f"python3 -c '{INSTALLER}' {wrong}", SOURCE.read_bytes())
        self.assertEqual(run.returncode, 85, run.stderr.decode(errors="replace"))
        self.assertFalse(INSTALLED.exists(), "a mismatched script still landed on disk")


if __name__ == "__main__":
    unittest.main()
