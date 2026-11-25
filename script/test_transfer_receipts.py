#!/usr/bin/env python3
"""Check the receiver's durable transfer protocol in a temporary home."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
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
        self.outbox = self.root / "state" / "desktop-link" / "outbox"

    def invoke(self, args, body):
        result = subprocess.run([sys.executable, RECEIVER, *args], input=body,
                                capture_output=True, env=self.env, check=True, timeout=5)
        return json.loads(result.stdout)

    def request(self, action, ticket=None):
        fields = {"version": 1, "action": action}
        if ticket is not None:
            fields["project"] = ticket
        return self.invoke([], json.dumps(fields).encode())

    def queue(self, sample):
        return self.invoke(["--queue", "file", str(sample)], b"")["handoffs"][0]

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

    def test_reject_is_idempotent_and_unblocks_the_queue(self):
        sample = self.root / "pilot.txt"
        sample.write_text("A file the Mac refuses.")
        queued = self.queue(sample)
        self.assertEqual([item["id"] for item in self.request("pending")["handoffs"]], [queued["id"]])

        self.assertTrue(self.request("reject", queued["id"])["ok"])
        self.assertEqual(list(self.outbox.iterdir()), [])
        self.assertEqual(self.request("mac-file-status", queued["id"])["transferStatus"], "unknown")
        self.assertTrue(self.request("reject", queued["id"])["ok"])
        self.assertFalse(self.request("reject", uuid.uuid4().hex)["ok"])

        replacement = self.queue(sample)
        self.assertNotEqual(replacement["id"], queued["id"])
        self.assertEqual([item["id"] for item in self.request("pending")["handoffs"]], [replacement["id"]])

    def test_rejected_ticket_frees_a_queue_slot(self):
        sample = self.root / "pilot.txt"
        sample.write_text("A file for the Mac.")
        tickets = [self.queue(sample)["id"] for _ in range(12)]
        self.assertFalse(self.invoke(["--queue", "file", str(sample)], b"")["ok"])

        self.assertTrue(self.request("reject", tickets[0])["ok"])
        accepted = self.queue(sample)
        self.assertNotIn(accepted["id"], tickets)
        self.assertEqual(len(list(self.outbox.glob("*.json"))), 12)

    def test_stale_handoffs_expire_from_the_outbox(self):
        sample = self.root / "pilot.txt"
        sample.write_text("A forgotten handoff.")
        stale = self.queue(sample)
        expired = time.time() - 8 * 24 * 60 * 60
        for path in self.outbox.iterdir():
            os.utime(path, (expired, expired))

        fresh = self.queue(sample)
        self.assertEqual([item["id"] for item in self.request("pending")["handoffs"]], [fresh["id"]])
        self.assertEqual(sorted(path.name for path in self.outbox.iterdir()),
                         [f"{fresh['id']}.bin", f"{fresh['id']}.json"])
        self.assertFalse(self.request("reject", stale["id"])["ok"])

    def test_queue_publishes_atomically_and_sweeps_orphans(self):
        sample = self.root / "pilot.txt"
        sample.write_text("A file for the Mac.")
        self.outbox.mkdir(parents=True)
        orphaned = time.time() - 2 * 24 * 60 * 60
        stale = [self.outbox / f"{uuid.uuid4().hex}{suffix}" for suffix in (".part", ".bin")]
        for path in stale:
            path.write_bytes(b"half a handoff")
            os.utime(path, (orphaned, orphaned))
        in_flight = self.outbox / f"{uuid.uuid4().hex}.part"
        in_flight.write_bytes(b"still being written")

        queued = self.queue(sample)
        self.assertEqual(sorted(path.name for path in self.outbox.iterdir()),
                         sorted([f"{queued['id']}.bin", f"{queued['id']}.json", in_flight.name]))
        self.assertFalse(any(path.exists() for path in stale))

    def test_interrupted_commit_replans_past_a_foreign_file(self):
        ticket = uuid.uuid4().hex
        body = b"Planned upload"
        planned = self.folder / "project.txt"
        first = self.upload(ticket, body)
        self.assertTrue(first["ok"])
        self.assertEqual(first["path"], str(planned))

        manifest = self.receipts / f"file-{ticket}.json"
        state = json.loads(manifest.read_text())
        state["delivered"] = False
        manifest.write_text(json.dumps(state))
        planned.write_bytes(b"Someone else's shorter file")

        retry = self.upload(ticket, body)
        self.assertTrue(retry["ok"], retry)
        self.assertNotEqual(retry["path"], str(planned))
        self.assertEqual(Path(retry["path"]).read_bytes(), body)
        self.assertEqual(planned.read_bytes(), b"Someone else's shorter file")
        self.assertEqual(json.loads(manifest.read_text())["path"], retry["path"])
        self.assertEqual(self.status(ticket, checksum(body))["path"], retry["path"])

    def test_interrupted_commit_reports_a_foreign_file_at_its_recorded_path(self):
        self.upload(uuid.uuid4().hex, b"First file")
        ticket = uuid.uuid4().hex
        body = b"The second file"
        second = self.upload(ticket, body)
        self.assertTrue(second["ok"])
        self.assertNotEqual(second["path"], str(self.folder / "project.txt"))

        manifest = self.receipts / f"file-{ticket}.json"
        state = json.loads(manifest.read_text())
        state["delivered"] = False
        manifest.write_text(json.dumps(state))
        Path(second["path"]).write_bytes(b"Wrong size")

        retry = self.upload(ticket, body)
        self.assertFalse(retry["ok"], retry)
        self.assertEqual(retry["error"], "A different file occupies the transfer destination.")
        self.assertEqual(Path(second["path"]).read_bytes(), b"Wrong size")


if __name__ == "__main__":
    unittest.main()
