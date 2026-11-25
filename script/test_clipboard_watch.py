import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest


RECEIVER = Path(__file__).resolve().parents[1] / "peer/desktop_link_peer.py"

PASTE = '''
import os
import subprocess
import sys
import time

args = sys.argv[1:]
initial = os.environ["FIXTURE_SELECTION"]
if args == ["--list-types"]:
    mime = os.environ.get("FIXTURE_EVENT_MIME", initial)
    if mime:
        print(mime)
    sys.exit(not mime)

assert args[:4] == ["--no-newline", "--type", "text", "--watch"]
helper = args[4:]

def event(state, payload=b""):
    env = dict(os.environ, CLIPBOARD_STATE=state, FIXTURE_EVENT_MIME="text/plain;charset=utf-8")
    subprocess.run(helper, check=True, input=payload, env=env)

if not initial:
    event("nil")
elif initial == "text/plain;charset=utf-8":
    event("data", b"existing clipboard must not be shared")
    event("data", b"new Linux copy")
# An image-only clipboard generates no event for a text watcher on startup.
time.sleep(10)
'''

COPY = '''
from pathlib import Path
import os
import sys

assert sys.argv[1:] == ["--type", "text/plain;charset=utf-8"]
Path(os.environ["FIXTURE_RESULT"]).write_bytes(sys.stdin.buffer.read())
'''


class ClipboardWatchTests(unittest.TestCase):
    def exercise(self, initial):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for name, script in (("wl-paste", PASTE), ("wl-copy", COPY)):
                path = fixture / name
                path.write_text(f"#!{sys.executable}\n{script}")
                path.chmod(0o700)

            result = fixture / "copied"
            env = dict(os.environ, PATH=f"{fixture}{os.pathsep}{os.environ['PATH']}",
                       WAYLAND_DISPLAY="fixture", FIXTURE_SELECTION=initial,
                       FIXTURE_RESULT=str(result))
            with subprocess.Popen([sys.executable, "-B", RECEIVER, "--watch-clipboard"],
                                  env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, bufsize=0) as peer:
                def frame():
                    self.assertTrue(select.select([peer.stdout], [], [], 5)[0], "No clipboard frame")
                    line = peer.stdout.readline()
                    self.assertTrue(line, "Clipboard watcher exited before it was ready")
                    return json.loads(line)

                try:
                    self.assertEqual(frame(), {"kind": "ready"})
                    if initial.startswith("text/"):
                        self.assertEqual(frame(), {"kind": "clipboard", "text": "new Linux copy"})
                    else:
                        peer.stdin.write(b'{"kind":"clipboard","text":"new Mac copy"}\n')
                        deadline = time.monotonic() + 3
                        while not result.exists() and time.monotonic() < deadline:
                            time.sleep(0.04)
                        self.assertTrue(result.exists(), "Receiver dropped the first Mac copy")
                        self.assertEqual(result.read_bytes(), b"new Mac copy")
                finally:
                    peer.stdin.close()
                    try:
                        peer.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        peer.kill()
                        peer.wait()

    def test_image_only_clipboard_starts_without_reading_png(self):
        self.exercise("image/png")

    def test_empty_clipboard_starts_and_accepts_text(self):
        self.exercise("")

    def test_existing_text_is_skipped_and_next_copy_is_shared(self):
        self.exercise("text/plain;charset=utf-8")


if __name__ == "__main__":
    unittest.main()
