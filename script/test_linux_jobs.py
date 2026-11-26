#!/usr/bin/env python3
"""Run isolated Handoff Fox job lifecycle regressions with unittest."""

import base64
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid


PEER = Path(__file__).resolve().parents[1] / "peer/desktop_link_peer.py"


class DurableJobTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="handoff-fox-jobs-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.config = self.root / ".config/desktop-link/projects.json"
        self.config.parent.mkdir(parents=True)
        self.jobs = self.root / ".state/desktop-link/jobs"
        self.env = os.environ | {
            "HOME": str(self.root),
            "XDG_CONFIG_HOME": str(self.root / ".config"),
            "XDG_STATE_HOME": str(self.root / ".state"),
        }

    def configure(self, source, artifact=None):
        self.config.write_text(json.dumps({"projects": [{
            "id": "project", "name": "Project", "path": str(self.project),
            "build": [sys.executable, "-c", "print('legacy build')"],
            "presets": [{"id": "test", "name": "Test", "argv": [sys.executable, "-c", source],
                         "artifact": artifact}],
        }]}))

    def invoke(self, action, **fields):
        run = subprocess.run(
            [sys.executable, str(PEER)], env=self.env, capture_output=True, timeout=12,
            input=json.dumps({"version": 1, "action": action, **fields}).encode(),
        )
        self.assertEqual(run.returncode, 0, run.stderr.decode(errors="replace"))
        return json.loads(run.stdout)

    def request(self, action, **fields):
        reply = self.invoke(action, **fields)
        self.assertTrue(reply["ok"], reply)
        return reply

    def start(self, identifier, **fields):
        return self.request("job-start", project="project", preset="test", job=identifier, **fields)["job"]

    def start_with_supervisor(self, identifier):
        spec = importlib.util.spec_from_file_location("test_fox_peer", PEER)
        peer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(peer)
        peer.CONFIG, peer.JOBS = self.config, self.jobs
        launch = subprocess.Popen
        launched = []

        def capture_supervisor(*args, **kwargs):
            supervisor = launch(*args, **kwargs, env=self.env)
            launched.append(supervisor)
            return supervisor

        with patch.object(peer.subprocess, "Popen", side_effect=capture_supervisor):
            reply = peer.request({"version": 1, "action": "job-start", "project": "project",
                                  "preset": "test", "job": identifier})
        self.assertEqual(reply["job"]["state"], "queued")
        self.assertEqual(len(launched), 1)
        supervisor = launched[0]
        self.addCleanup(supervisor.wait, timeout=7)
        self.addCleanup(self.cancel_if_running, identifier)
        return supervisor

    def test_a_saved_bare_command_runs_the_project_file(self):
        project_tool = self.project / "fox-check"
        project_tool.write_text("#!/bin/sh\necho project > ran.txt\n")
        project_tool.chmod(0o755)
        elsewhere = self.root / "bin"
        elsewhere.mkdir()
        path_tool = elsewhere / "fox-check"
        path_tool.write_text("#!/bin/sh\necho path > ran.txt\n")
        path_tool.chmod(0o755)
        self.env["PATH"] = str(elsewhere) + os.pathsep + os.environ.get("PATH", "")
        self.configure("print('unused')")
        saved = self.invoke("save-preset", project="project", name="Check", argv=["fox-check"])
        self.assertTrue(saved["ok"], saved)
        presets = json.loads(self.config.read_text())["projects"][0]["presets"]
        saved_preset = next(entry for entry in presets if entry["id"] == "check")
        self.assertEqual(saved_preset["argv"], ["./fox-check"])

        identifier = uuid.uuid4().hex
        self.request("job-start", project="project", preset="check", job=identifier)
        self.wait_terminal(identifier)
        self.assertEqual((self.project / "ran.txt").read_text().strip(), "project")

    def test_an_owner_command_outside_the_project_still_runs(self):
        self.configure("import pathlib; pathlib.Path('owner.txt').touch()")
        identifier = uuid.uuid4().hex
        self.start(identifier)
        self.wait_terminal(identifier)
        self.assertTrue((self.project / "owner.txt").exists())

    def test_recovery_kills_what_a_dead_monitor_left_running(self):
        spec = importlib.util.spec_from_file_location("test_fox_peer", PEER)
        peer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(peer)
        peer.CONFIG, peer.JOBS = self.config, self.jobs

        directory = self.jobs / uuid.uuid4().hex
        directory.mkdir(parents=True)
        orphan = subprocess.Popen(["sleep", "30"], start_new_session=True)
        self.addCleanup(lambda: (orphan.poll() is None and orphan.kill(), orphan.wait()))
        started = peer.process_started_at(orphan.pid)
        self.assertIsNotNone(started, "the kernel did not report a start time")
        (directory / "worker.pid").write_text(
            json.dumps({"pid": orphan.pid, "started": started}))

        job = {"id": directory.name, "project": "project", "preset": "test",
               "state": "running", "createdAt": time.time(), "updatedAt": time.time()}
        (directory / "job.json").write_text(json.dumps(job))

        recovered = peer.recover_job(directory, job)
        self.assertEqual(recovered["state"], "failed")
        self.assertIn("killed", recovered["error"])
        orphan.wait(timeout=10)
        self.assertIsNotNone(orphan.returncode, "the orphaned command was still running")
        self.assertFalse((directory / "worker.pid").exists())

    def test_recovery_leaves_a_reused_pid_alone(self):
        spec = importlib.util.spec_from_file_location("test_fox_peer", PEER)
        peer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(peer)
        peer.CONFIG, peer.JOBS = self.config, self.jobs

        directory = self.jobs / uuid.uuid4().hex
        directory.mkdir(parents=True)
        while_we_wait = subprocess.Popen(["sleep", "30"], start_new_session=True)
        self.addCleanup(lambda: (while_we_wait.poll() is None and while_we_wait.kill(), while_we_wait.wait()))
        (directory / "worker.pid").write_text(
            json.dumps({"pid": while_we_wait.pid, "started": "%d" % (int(peer.process_started_at(while_we_wait.pid) or 0) - 1)}))
        job = {"id": directory.name, "project": "project", "preset": "test",
               "state": "running", "createdAt": time.time(), "updatedAt": time.time()}
        (directory / "job.json").write_text(json.dumps(job))

        recovered = peer.recover_job(directory, job)
        self.assertEqual(recovered["state"], "failed")
        self.assertNotIn("killed", recovered["error"])
        self.assertIsNone(while_we_wait.poll(), "an unrelated process was killed")

    def test_an_artifact_this_run_did_not_write_is_marked_stale(self):
        artifact = self.project / "out.txt"
        artifact.write_text("from an earlier run")
        self.configure("print('did nothing')", artifact="out.txt")
        identifier = uuid.uuid4().hex
        self.start(identifier)
        stale = self.wait_terminal(identifier)["job"]
        self.assertTrue(stale.get("artifactStale"), stale)
        self.assertNotIn("artifactSha256", stale, "a stale artifact was still collected")
        artifact = self.invoke("job-artifact", job=identifier)
        self.assertFalse(artifact["ok"], artifact)

        self.configure("import pathlib; pathlib.Path('out.txt').write_text('fresh')",
                      artifact="out.txt")
        fresh = uuid.uuid4().hex
        self.start(fresh)
        status = self.wait_terminal(fresh)["job"]
        self.assertFalse(status.get("artifactStale"), status)
        self.assertIsNone(status.get("artifactNote"), status)
        self.assertEqual(status["artifactName"], "out.txt")

    def wait_for(self, identifier, predicate):
        stop = time.monotonic() + 7
        while time.monotonic() < stop:
            response = self.request("job-status", job=identifier)
            if predicate(response):
                return response
            time.sleep(0.07)
        self.fail(f"Job did not reach expected state: {response}")

    def wait_terminal(self, identifier):
        return self.wait_for(identifier, lambda response: response["job"]["state"] in {
            "cancelled", "failed", "succeeded"
        })

    def test_reconnect_replays_same_ticket_and_artifact_snapshot(self):
        self.configure(
            "import pathlib, time; time.sleep(0.3); "
            "pathlib.Path('out').mkdir(); "
            "pathlib.Path('out/result.txt').write_text('passed'); print('x' * 50000)",
            "out/result.txt",
        )
        identifier = uuid.uuid4().hex
        job = self.start(identifier, argv=["never-run-request-arguments"])
        self.assertEqual(job["state"], "queued")
        with ThreadPoolExecutor(max_workers=3) as pool:
            duplicates = list(pool.map(self.start, [identifier] * 3))
        self.assertTrue(all(job["id"] == identifier for job in duplicates))
        collision = self.invoke("job-start", project="project", preset="build", job=identifier)
        self.assertFalse(collision["ok"], collision)

        # Each API call starts a fresh receiver process. The starting process
        # already exited before the detached worker finished.
        done = self.wait_terminal(identifier)
        self.assertEqual(done["job"]["state"], "succeeded")
        self.assertEqual(done["job"]["exitCode"], 0)
        self.assertEqual(done["job"]["artifactName"], "result.txt")
        self.assertEqual(len(done["output"].encode()), 48000)
        self.assertTrue(done["truncated"])
        original = self.request("job-artifact", job=identifier)["artifact"]
        self.assertEqual(base64.b64decode(original["data"]), b"passed")
        self.assertEqual(original["sha256"], sha256(b"passed").hexdigest())
        (self.project / "out/result.txt").write_text("later build")
        self.assertEqual(self.request("job-artifact", job=identifier)["artifact"], original)
        self.assertEqual(len(self.request("job-list")["jobs"]), 1)
        self.assertEqual(self.start(identifier), done["job"])
        (self.jobs / identifier / "artifact.bin").write_bytes(b"changed after commit")
        self.assertFalse(self.invoke("job-artifact", job=identifier)["ok"])

    def test_linked_artifact_folder_cannot_read_outside_the_project(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "result.txt").write_text("outside the project")
        (self.project / "out").symlink_to(outside, target_is_directory=True)
        self.configure("pass", "out/result.txt")
        identifier = uuid.uuid4().hex
        self.start(identifier)
        result = self.wait_terminal(identifier)["job"]
        self.assertEqual(result["state"], "succeeded")
        self.assertIn("artifactError", result)
        self.assertFalse(self.invoke("job-artifact", job=identifier)["ok"])

    def test_legacy_build_and_project_lock_survive_overlapping_requests(self):
        self.configure("import time; time.sleep(5)")
        identifier = uuid.uuid4().hex
        self.start(identifier)
        self.addCleanup(self.cancel_if_running, identifier)
        other = self.invoke("job-start", project="project", preset="test", job=uuid.uuid4().hex)
        self.assertFalse(other["ok"], other)
        self.assertFalse(self.invoke("build", project="project")["ok"])
        self.request("job-cancel", job=identifier)
        self.assertEqual(self.wait_terminal(identifier)["job"]["state"], "cancelled")
        # Terminal state is written just before the worker releases its lock.
        for _ in range(20):
            result = self.invoke("build", project="project")
            if result["ok"]:
                break
            time.sleep(0.05)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["output"], "legacy build\n")

    def cancel_if_running(self, identifier):
        self.invoke("job-cancel", job=identifier)
        self.wait_terminal(identifier)

    def test_cancel_stops_descendants_and_keeps_terminal_state(self):
        child = "import pathlib,time; time.sleep(1.3); pathlib.Path('orphan.txt').touch()"
        self.configure(
            "import subprocess, sys, time; "
            f"subprocess.Popen([sys.executable, '-c', {child!r}]); "
            "print('child started', flush=True); time.sleep(5)"
        )
        identifier = uuid.uuid4().hex
        self.start(identifier)
        self.addCleanup(self.cancel_if_running, identifier)
        self.wait_for(identifier, lambda response: "child started" in response["output"])
        cancelling = self.request("job-cancel", job=identifier)["job"]
        self.assertIn(cancelling["state"], {"cancelling", "cancelled"})
        done = self.wait_terminal(identifier)
        self.assertEqual(done["job"]["state"], "cancelled")
        self.assertEqual(self.request("job-cancel", job=identifier)["job"], done["job"])
        time.sleep(1.4)
        self.assertFalse((self.project / "orphan.txt").exists())

    def test_failure_and_owner_preset_boundary(self):
        self.configure("import sys; print('test failed'); sys.exit(23)")
        identifier = uuid.uuid4().hex
        self.assertFalse(self.invoke("job-start", project="project", preset="unknown", job=identifier)["ok"])
        self.assertFalse(self.invoke("job-start", project="project", preset="test", job="../escape")["ok"])
        self.start(identifier)
        failure = self.wait_terminal(identifier)
        self.assertEqual(failure["job"]["state"], "failed")
        self.assertEqual(failure["job"]["exitCode"], 23)
        self.assertIn("test failed", failure["output"])
        self.assertFalse(self.invoke("job-artifact", job=identifier)["ok"])

    def test_normal_exit_cleans_up_descendants_without_output_pipes(self):
        child = "import pathlib,time; time.sleep(1.4); pathlib.Path('orphan.txt').touch()"
        self.configure(
            "import subprocess, sys; "
            f"subprocess.Popen([sys.executable, '-c', {child!r}], "
            "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)"
        )
        identifier = uuid.uuid4().hex
        self.start(identifier)
        self.assertEqual(self.wait_terminal(identifier)["job"]["state"], "succeeded")
        time.sleep(1.5)
        self.assertFalse((self.project / "orphan.txt").exists())

    def test_no_worker_reconciles_after_abrupt_stop(self):
        self.configure("raise SystemExit('must never run')")
        identifier = uuid.uuid4().hex
        directory = self.jobs / identifier
        directory.mkdir(parents=True)
        state = {"id": identifier, "project": "project", "preset": "test", "title": "test",
                 "state": "running", "createdAt": time.time(), "updatedAt": time.time()}
        (directory / "job.json").write_text(json.dumps(state))
        recovered = self.request("job-status", job=identifier)["job"]
        self.assertEqual(recovered["state"], "failed")
        self.assertIn("worker stopped", recovered["error"])
        self.assertEqual(self.start(identifier), recovered)

    def test_supervisor_loss_reaps_a_quiet_job_before_releasing_project(self):
        for signum in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=signum.name):
                ready = self.project / f"ready-{signum.name}"
                orphan = self.project / f"orphan-{signum.name}"
                child = f"import pathlib, time; time.sleep(1.5); pathlib.Path({str(orphan)!r}).touch()"
                self.configure(
                    "import pathlib, subprocess, sys, time; "
                    f"subprocess.Popen([sys.executable, '-c', {child!r}]); "
                    f"pathlib.Path({str(ready)!r}).touch(); time.sleep(5)"
                )
                identifier = uuid.uuid4().hex
                supervisor = self.start_with_supervisor(identifier)
                self.wait_for(identifier, lambda _: ready.is_file())
                self.assertIn("--run-job", supervisor.args)
                self.assertIn(identifier, supervisor.args)
                if signum == signal.SIGTERM:
                    supervisor.send_signal(signum)
                else:
                    self.assertEqual(os.getpgid(supervisor.pid), supervisor.pid)
                    os.killpg(supervisor.pid, signum)
                result = self.wait_terminal(identifier)["job"]
                self.assertEqual(result["state"], "failed")
                self.assertEqual(result["error"], "The Linux job supervisor stopped.")
                time.sleep(1.6)
                self.assertFalse(orphan.exists())
                self.assertEqual(self.request("build", project="project")["output"], "legacy build\n")

    def test_handshake_lists_legacy_and_named_presets(self):
        self.configure("pass")
        reply = self.request("pair")
        self.assertEqual(reply["jobProtocol"], 1)
        self.assertIsInstance(reply["clipboardAvailable"], bool)
        self.assertTrue(reply["projects"][0]["canBuild"])
        self.assertEqual(reply["projects"][0]["presets"], [
            {"id": "build", "name": "Build"}, {"id": "test", "name": "Test"}
        ])

    def test_project_config_errors_name_the_path(self):
        for content in ('{"projects": [', '{"saved": []}'):
            with self.subTest(config=content):
                self.config.write_text(content)
                reply = self.invoke("pair")
                self.assertFalse(reply["ok"], reply)
                self.assertIn(str(self.config), reply["error"])

    def test_valid_project_config_skips_malformed_entries(self):
        self.config.write_text(json.dumps({"projects": [
            "not a project",
            {"name": "No identifier", "path": str(self.project)},
            {"id": "kept", "name": "Kept", "path": str(self.project),
             "presets": [{"id": "test", "name": "Test", "argv": [sys.executable, "-c", "pass"]}]},
        ]}))
        reply = self.request("pair")
        self.assertEqual([item["id"] for item in reply["projects"]], ["kept"])
        self.assertEqual(reply["projects"][0]["presets"], [{"id": "test", "name": "Test"}])

    def test_preset_without_an_id_or_argv_is_reported(self):
        self.configure("pass")
        document = json.loads(self.config.read_text())
        document["projects"][0]["presets"] = [{"name": "Missing argv"}]
        self.config.write_text(json.dumps(document))
        reply = self.invoke("pair")
        self.assertFalse(reply["ok"], reply)
        self.assertIn(str(self.config), reply["error"])
        self.assertIn("preset 1", reply["error"])

    def test_open_terminal_runs_only_the_platform_command_at_the_saved_path(self):
        self.project = self.root / "source project $literal"
        self.project.mkdir()
        self.configure("pass")
        binaries = self.root / "bin"
        binaries.mkdir()
        marker = self.root / "terminal.json"
        launcher = binaries / "foot"
        launcher.write_text(
            f"#!{sys.executable}\nimport json, os, pathlib, sys\n"
            f"pathlib.Path({str(marker)!r}).write_text(json.dumps([os.getcwd(), *sys.argv[1:]]))\n"
        )
        launcher.chmod(0o755)
        self.env |= {"PATH": str(binaries), "DISPLAY": ":99"}
        self.assertFalse(self.invoke("open-terminal", project="unknown")["ok"])
        self.request("open-terminal", project="project", args=["ignored-request-arguments"])
        deadline = time.monotonic() + 3
        while not marker.is_file() and time.monotonic() < deadline:
            time.sleep(0.05)
        directory = str(self.project.resolve())
        self.assertEqual(json.loads(marker.read_text()), [directory, f"--working-directory={directory}"])


if __name__ == "__main__":
    unittest.main()
