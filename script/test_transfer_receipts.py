#!/usr/bin/env python3
"""Check the receiver's durable transfer protocol in a temporary home."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path


RECEIVER = Path(__file__).resolve().parents[1] / "peer" / "desktop_link_peer.py"


def checksum(data):
    return hashlib.sha256(data).hexdigest()


class TransferReceiptTests(unittest.TestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        self.root = Path(home.name)
        self.env = os.environ | {"HOME": home.name, "XDG_STATE_HOME": str(self.root / "state")}
        self.folder = self.root / "Downloads" / "Handoff Fox"
        self.receipts = self.root / "state" / "desktop-link" / "receipts"

    def invoke(self, args, body):
        result = subprocess.run([sys.executable, RECEIVER, *args], input=body,
                                capture_output=True, env=self.env, check=True, timeout=5)
        return json.loads(result.stdout)

    def upload(self, ticket, body, *, name="project.txt", expected=None, size=None, durable=True):
        metadata = {"id": ticket, "name": name, "volume": "home",
                    "sha256": expected if expected is not None else checksum(body),
                    "size": size if size is not None else len(body)}
        data = json.dumps(metadata).encode() + b"\n" + body
        return self.invoke(["--upload-ticket" if durable else "--upload"], data)

    def status(self, ticket, digest):
        request = {"version": 1, "action": "upload-status", "project": ticket, "text": digest}
        return self.invoke([], json.dumps(request).encode())

    def test_lost_response_replays_original_path(self):
        ticket = uuid.uuid4().hex
        body = b"Build notes and artifacts"
        first = self.upload(ticket, body)
        self.assertTrue(first["ok"])
        self.assertEqual(self.status(ticket, checksum(body)), first)
        self.assertEqual(self.upload(ticket, body), first)
        self.assertEqual(list(self.folder.iterdir()), [Path(first["path"])])
        self.assertEqual(Path(first["path"]).read_bytes(), body)
        self.assertFalse(self.upload(ticket, b"Different payload")["ok"])
        self.assertFalse(self.status(ticket, checksum(b"Different payload"))["ok"])

    def test_partial_upload_and_wrong_digest_publish_no_file(self):
        ticket = uuid.uuid4().hex
        body = b"Entire file contents"
        self.assertFalse(self.upload(ticket, body[:4], size=len(body), expected=checksum(body))["ok"])
        self.assertFalse(self.upload(ticket, body, expected=checksum(b"not this file"))["ok"])
        self.assertEqual(list(self.folder.iterdir()), [])
        self.assertNotIn("path", self.status(ticket, checksum(body)))
        self.assertTrue(self.upload(ticket, body)["ok"])

    def test_commit_resumes_after_interruption_and_preserves_existing_file(self):
        first = self.upload(uuid.uuid4().hex, b"Original")
        ticket = uuid.uuid4().hex
        body = b"Another file with the same name"
        second = self.upload(ticket, body)
        self.assertTrue(first["ok"] and second["ok"])
        self.assertNotEqual(first["path"], second["path"])
        manifest = self.receipts / f"file-{ticket}.json"
        state = json.loads(manifest.read_text())
        state["delivered"] = False
        manifest.write_text(json.dumps(state))
        self.assertNotIn("path", self.status(ticket, checksum(body)))
        self.assertEqual(self.upload(ticket, body), second)
        self.assertEqual(Path(first["path"]).read_bytes(), b"Original")
        self.assertEqual(Path(second["path"]).read_bytes(), body)
        self.assertEqual(len(list(self.folder.iterdir())), 2)

        state["delivered"] = False
        manifest.write_text(json.dumps(state))
        Path(second["path"]).write_bytes(b"Unexpected replacement")
        self.assertFalse(self.upload(ticket, body)["ok"])
        self.assertEqual(Path(second["path"]).read_bytes(), b"Unexpected replacement")

    def test_legacy_upload_retains_digest_response(self):
        body = b"Legacy build output"
        response = self.upload(uuid.uuid4().hex, body, durable=False)
        self.assertTrue(response["ok"])
        self.assertEqual(response["sha256"], checksum(body))
        self.assertEqual(Path(response["path"]).read_bytes(), body)

    def test_mac_delivery_requires_an_acknowledged_file_ticket(self):
        sample = self.root / "pilot.txt"
        sample.write_text("A file for the Mac.")
        queued = self.invoke(["--queue", "file", str(sample)], b"")["handoffs"][0]
        token = queued["id"]

        def request(action, ticket=token):
            return self.invoke([], json.dumps({"version": 1, "action": action, "project": ticket}).encode())

        self.assertEqual(request("mac-file-status")["transferStatus"], "queued")
        self.assertEqual(request("mac-file-status", uuid.uuid4().hex)["transferStatus"], "unknown")
        self.assertTrue(request("ack")["ok"])
        self.assertEqual(request("mac-file-status")["transferStatus"], "delivered")
        self.assertEqual(list((self.root / "state/desktop-link/outbox").iterdir()), [])
        self.assertTrue(request("ack")["ok"])
        self.assertEqual(request("mac-file-status")["transferStatus"], "delivered")

        omitted = self.invoke(["--queue", "file", str(sample)], b"")["handoffs"][0]["id"]
        (self.root / "state/desktop-link/outbox" / f"{omitted}.json").unlink()
        self.assertEqual(request("mac-file-status", omitted)["transferStatus"], "unknown")


if __name__ == "__main__":
    unittest.main()
