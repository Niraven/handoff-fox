#!/usr/bin/env python3
"""Check how the app reaches the receiver: its install bootstrap and its command.

The other receiver tests import or execute the script directly. This one runs
the bootstrap the app pipes over SSH and then starts the receiver the way a
remote shell would, by its relative path. A round trip through a real sshd is
attempted too, and skipped with a reason when this machine's sshd will not
authenticate.
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


class HomeTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-ssh-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.env = os.environ | {"HOME": str(self.home), "USER": getpass.getuser()}

    def bootstrap(self, digest, script):
        return subprocess.run(
            [sys.executable, "-c", INSTALLER, digest], input=script,
            capture_output=True, env=self.env, timeout=60,
        )

    def receiver(self, payload):
        return subprocess.run(
            ["bash", "-c", REMOTE_COMMAND], input=payload, capture_output=True,
            cwd=self.home, env=self.env, timeout=60,
        )


class InstallerBootstrapTests(HomeTestCase):
    def test_the_bootstrap_installs_an_executable_receiver(self):
        script = SOURCE.read_bytes()
        digest = hashlib.sha256(script).hexdigest()
        install = self.bootstrap(digest, script)
        self.assertEqual(install.returncode, 0, install.stderr.decode(errors="replace"))
        installed = self.home / REMOTE_COMMAND
        self.assertTrue(installed.is_file(), "the bootstrap did not install the receiver")
        self.assertTrue(os.access(installed, os.X_OK), "the receiver is not executable")
        self.assertEqual(installed.read_bytes(), script)

    def test_the_bootstrap_refuses_a_different_script(self):
        install = self.bootstrap(hashlib.sha256(b"not the receiver").hexdigest(), SOURCE.read_bytes())
        self.assertEqual(install.returncode, 85, install.stderr.decode(errors="replace"))
        self.assertFalse((self.home / REMOTE_COMMAND).exists(), "a mismatched script still landed on disk")

    def test_a_bootstrap_without_a_hash_installs_nothing(self):
        install = subprocess.run(
            [sys.executable, "-c", INSTALLER], input=SOURCE.read_bytes(),
            capture_output=True, env=self.env, timeout=60,
        )
        self.assertNotEqual(install.returncode, 0)
        self.assertFalse((self.home / REMOTE_COMMAND).exists())


class RemoteCommandTests(HomeTestCase):
    def setUp(self):
        super().setUp()
        script = SOURCE.read_bytes()
        self.assertEqual(self.bootstrap(hashlib.sha256(script).hexdigest(), script).returncode, 0)

    def test_the_receiver_answers_by_its_relative_path(self):
        run = self.receiver(b'{"version": 1, "action": "pair"}')
        self.assertEqual(run.returncode, 0, run.stderr.decode(errors="replace"))
        reply = json.loads(run.stdout.decode().splitlines()[-1])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["system"], "Linux")
        self.assertEqual(reply["version"], 1)

    def test_a_shell_finds_the_command_the_app_sends(self):
        run = subprocess.run(["bash", "-lc", f"command -v {REMOTE_COMMAND}"], cwd=self.home,
                             env=self.env, capture_output=True, timeout=60)
        self.assertIn(REMOTE_COMMAND, run.stdout.decode(), "PATH does not reach the receiver")


def sshd_available():
    if os.geteuid() == 0:
        return "the sshd round trip is skipped when the tests run as root"
    if (Path.home() / ".ssh/authorized_keys").exists():
        return "an authorized_keys file already exists in this home directory"
    if not Path("/usr/sbin/sshd").is_file() or not shutil.which("ssh") or not shutil.which("ssh-keygen"):
        return "sshd or the OpenSSH client is missing"
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return "starting sshd needs passwordless sudo"
    return None


SSHD_REASON = sshd_available()


@unittest.skipIf(SSHD_REASON is not None, SSHD_REASON or "")
class SshdRoundTripTests(HomeTestCase):
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
        # sshd inside a sandboxed or confined service reads an absolute
        # AuthorizedKeysFile unreliably, so this uses the path it always looks at.
        ssh_directory = Path.home() / ".ssh"
        ssh_directory.mkdir(mode=0o700, exist_ok=True)
        authorized = ssh_directory / "authorized_keys"
        authorized.write_text(client_key.with_suffix(".pub").read_text())
        authorized.chmod(0o600)
        cls.addClassCleanup(authorized.unlink, missing_ok=True)
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
            "LogLevel DEBUG1\n"
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
        raise unittest.SkipTest("the local sshd did not start: " + cls.log_tail())

    @classmethod
    def log_tail(cls, lines=3):
        text = cls.errors.read_text(errors="replace").strip().splitlines()
        return " / ".join(text[-lines:]) or "no output"

    @classmethod
    def stop(cls):
        cls.sshd.terminate()
        try:
            cls.sshd.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.sshd.kill()

    def ssh(self, command, payload=b""):
        return subprocess.run(
            ["ssh", "-T", "-p", str(self.port), "-i", str(self.root / "client_ed25519"),
             "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=" + str(self.root / "known_hosts"),
             "-o", "ConnectTimeout=5", "-o", "ControlMaster=no",
             "--", f"{getpass.getuser()}@127.0.0.1", command],
            input=payload, capture_output=True, timeout=60,
        )

    def setUp(self):
        super().setUp()
        probe = self.ssh("true")
        if probe.returncode != 0:
            detail = probe.stderr.decode(errors="replace").strip().splitlines()
            self.skipTest("this sshd will not authenticate: "
                          + (detail[-1] if detail else self.log_tail()))

    def test_a_missing_receiver_fails_with_the_exit_code_the_app_maps(self):
        run = self.ssh(REMOTE_COMMAND, b'{"version": 1, "action": "pair"}')
        self.assertEqual(run.returncode, 127, run.stderr.decode(errors="replace"))

    def test_the_app_bootstrap_over_ssh_installs_and_answers(self):
        self.addCleanup(lambda: (Path.home() / REMOTE_COMMAND).unlink(missing_ok=True))
        script = SOURCE.read_bytes()
        digest = hashlib.sha256(script).hexdigest()
        install = self.ssh(f"python3 -c '{INSTALLER}' {digest}", script)
        self.assertEqual(install.returncode, 0, install.stderr.decode(errors="replace"))
        run = self.ssh(REMOTE_COMMAND, b'{"version": 1, "action": "pair"}')
        self.assertEqual(run.returncode, 0, run.stderr.decode(errors="replace"))
        reply = json.loads(run.stdout.decode().splitlines()[-1])
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["system"], "Linux")


if __name__ == "__main__":
    unittest.main()
