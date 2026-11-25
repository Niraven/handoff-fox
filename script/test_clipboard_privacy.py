#!/usr/bin/env python3
"""Check the clipboard privacy gate against stand-in wl-clipboard tools."""

import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest

PEER = Path(__file__).resolve().parents[1] / "peer/desktop_link_peer.py"
CLEAN_TYPES = "text/plain\ntext/plain;charset=utf-8\n"
HINTS = ("passwordmanagerhint", "org.nspasteboard.concealedtype", "org.nspasteboard.transienttype")
LIMIT = 64 * 1024

WL_COPY = """#!/bin/sh
cat > "$STATE/clipboard.bin"
printf '%s' "text/plain;charset=utf-8" > "$STATE/types"
touch "$STATE/copied"
"""

WL_PASTE = """#!/bin/sh
if [ "$1" = "--list-types" ]; then
    cat "$STATE/types" 2>/dev/null
    exit 0
fi
if [ "$2" = "--type" ]; then
    test -f "$STATE/hang" && sleep 30
    cat "$STATE/clipboard.bin" 2>/dev/null
    exit 0
fi
if [ "$2" = "--watch" ]; then
    shift 2
    "$@" < /dev/null
    while [ ! -f "$STATE/copied" ]; do sleep 0.05; done
    sleep 0.1
    "$@" < "$STATE/clipboard.bin"
    while [ ! -f "$STATE/changed" ]; do sleep 0.05; done
    "$@" < "$STATE/clipboard.bin"
    exit 0
fi
exit 1
"""


class ClipboardPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-clip-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "state"
        self.state.mkdir()
        for name, body in (("wl-copy", WL_COPY), ("wl-paste", WL_PASTE)):
            tool = self.bin / name
            tool.write_text(body)
            tool.chmod(0o755)
        self.env = os.environ | {
            "HOME": str(self.root),
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
            "WAYLAND_DISPLAY": "wayland-stand-in",
            "STATE": str(self.state),
        }
        self.env.pop("DISPLAY", None)
        self.set_types(CLEAN_TYPES)
        self.set_clipboard(b"")

    def set_types(self, types):
        (self.state / "types").write_text(types)

    def set_clipboard(self, body):
        (self.state / "clipboard.bin").write_bytes(body)

    def request(self, action, **fields):
        run = subprocess.run(
            [sys.executable, str(PEER)], env=self.env, capture_output=True, timeout=20,
            input=json.dumps({"version": 1, "action": action, **fields}).encode(),
        )
        self.assertEqual(run.returncode, 0, run.stderr.decode(errors="replace"))
        return json.loads(run.stdout)

    def test_clipboard_get_refuses_every_sensitivity_hint(self):
        self.set_clipboard(b"hunter2")
        clean = self.request("clipboard-get")
        self.assertTrue(clean["ok"], clean)
        self.assertEqual(clean["text"], "hunter2")
        for hint in HINTS:
            with self.subTest(hint=hint):
                self.set_types(CLEAN_TYPES + hint + "\n")
                reply = self.request("clipboard-get")
                self.assertFalse(reply["ok"], reply)
                self.assertIn("sensitive", reply["error"])
        self.set_types(CLEAN_TYPES)

    def test_watch_helper_ignores_marked_items(self):
        marker = self.state / "marker"
        marker.touch()
        self.set_clipboard(b"hunter2")

        def invoke():
            run = subprocess.run(
                [sys.executable, str(PEER), "--clipboard-event", str(marker)],
                env=self.env, capture_output=True, timeout=20, input=b"hunter2",
            )
            return run.stdout.decode()

        self.assertEqual(invoke().strip(), '{"kind": "clipboard", "text": "hunter2"}')
        for hint in HINTS:
            with self.subTest(hint=hint):
                self.set_types(CLEAN_TYPES + hint + "\n")
                self.assertEqual(invoke().strip(), "")
        self.set_types(CLEAN_TYPES)

    def test_clipboard_put_refuses_oversized_and_nul_text(self):
        self.set_clipboard(b"unchanged")
        oversized = self.request("clipboard-put", text="a" * (LIMIT + 1))
        self.assertFalse(oversized["ok"], oversized)
        binary = self.request("clipboard-put", text="pass\x00word")
        self.assertFalse(binary["ok"], binary)
        self.assertEqual((self.state / "clipboard.bin").read_bytes(), b"unchanged")
        accepted = self.request("clipboard-put", text="a" * LIMIT)
        self.assertTrue(accepted["ok"], accepted)
        self.assertEqual(len((self.state / "clipboard.bin").read_bytes()), LIMIT)

    def test_clipboard_get_refuses_oversized_text(self):
        self.set_clipboard(b"a" * (LIMIT + 4096))
        reply = self.request("clipboard-get")
        self.assertFalse(reply["ok"], reply)
        self.assertIn("64 KiB", reply["error"])

    def test_clipboard_get_gives_up_on_a_stalled_paste(self):
        (self.state / "hang").touch()
        started = time.monotonic()
        reply = self.request("clipboard-get")
        elapsed = time.monotonic() - started
        self.assertFalse(reply["ok"], reply)
        self.assertIn("too long", reply["error"])
        self.assertLess(elapsed, 15)

    def test_watcher_does_not_echo_the_frame_it_wrote(self):
        process = subprocess.Popen(
            [sys.executable, str(PEER), "--watch-clipboard"], env=self.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(lambda: (process.kill(), process.wait(), process.stdout.close(),
                                 process.stderr.close()))
        pending = bytearray()

        def frame(seconds):
            deadline_at = time.monotonic() + seconds
            while b"\n" not in pending:
                remaining = deadline_at - time.monotonic()
                if remaining <= 0 or process.poll() is not None:
                    return None
                if select.select([process.stdout.fileno()], [], [], remaining)[0]:
                    chunk = os.read(process.stdout.fileno(), 8192)
                    if not chunk:
                        return None
                    pending.extend(chunk)
            at = pending.index(b"\n")
            line = bytes(pending[:at])
            del pending[:at + 1]
            return json.loads(line)

        self.assertEqual(frame(15), {"kind": "ready"})
        process.stdin.write(b'{"kind": "clipboard", "text": "from the mac"}\n')
        process.stdin.flush()
        self.assertIsNone(frame(1.5), "the watcher echoed the frame it wrote to the clipboard")

        self.set_clipboard(b"typed on linux")
        (self.state / "changed").touch()
        received = frame(15)
        self.assertEqual(received, {"kind": "clipboard", "text": "typed on linux"})
        process.stdin.close()
        process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
