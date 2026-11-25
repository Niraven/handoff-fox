#!/usr/bin/env python3
"""Inspect and run approved Handoff Fox presets over verified SSH."""

import argparse
import base64
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any
import uuid


SOCKETS = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "handoff-fox/ssh"


def control_path(host):
    # One authenticated session per device. A handshake per request cost 212 ms on
    # loopback and two extra round trips on a tailnet; reuse costs about 8 ms.
    SOCKETS.mkdir(parents=True, exist_ok=True, mode=0o700)
    return str(SOCKETS / sha256(host.encode()).hexdigest()[:20])


def request(host, action, **fields):
    if host.startswith("-") or host.endswith("@") or host.count("@") > 1 or not re.fullmatch(
        r"[A-Za-z0-9_:\[][A-Za-z0-9_.:@\[\]%-]{0,252}", host
    ):
        raise ValueError("Enter an SSH host alias or user@hostname.")
    completed = subprocess.run(
        ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
         "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
         "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
         "-o", "ControlMaster=auto", "-o", f"ControlPath={control_path(host)}",
         "-o", "ControlPersist=60",
         "--", host, ".local/bin/desktop-link-peer"],
        input=json.dumps({"version": 1, "action": action, **fields}).encode(),
        capture_output=True, timeout=20, check=False,
    )
    if completed.returncode != 0:
        raise ValueError("The verified SSH receiver could not be reached. Check the host and SSH key.")
    if len(completed.stdout) > 3_500_000:
        raise ValueError("The Linux receiver returned too much data.")
    lines = completed.stdout.splitlines()
    reply = json.loads(lines[-1]) if lines else {}
    if reply.get("version") != 1 or not reply.get("ok"):
        raise ValueError(reply.get("error") or "The Linux receiver returned an incompatible response.")
    return reply


def serve_mcp(host):
    try:
        from mcp.server import MCPServer
    except ImportError:
        raise ValueError("Install the MCP Python SDK 2.x in the environment used for this command.") from None

    server = MCPServer("Handoff Fox")

    @server.tool(structured_output=True)
    def device() -> dict[str, Any]:
        """Read the configured Linux peer's capabilities and storage availability."""
        reply = request(host, "pair")
        return {key: value for key, value in reply.items() if key != "projects"}

    @server.tool(structured_output=True)
    def projects() -> dict[str, list[dict[str, Any]]]:
        """List saved Linux projects and the preset names configured by their owner."""
        saved = [
            {key: project[key] for key in ("id", "name", "presets") if key in project}
            for project in request(host, "pair").get("projects", [])
        ]
        return {"projects": saved}

    @server.tool(structured_output=True)
    def jobs() -> dict[str, list[dict[str, Any]]]:
        """List recent Linux jobs on this device."""
        return {"jobs": request(host, "job-list").get("jobs", [])}

    @server.tool(structured_output=True)
    def job_status(job_id: str) -> dict[str, Any]:
        """Read a Linux job's state and exit code by its ticket."""
        return request(host, "job-status", job=job_id)["job"]

    server.run(transport="stdio")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", help="Verified SSH host alias or user@hostname")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("device", help="Show capabilities and disk availability")
    commands.add_parser("projects", help="List saved projects and approved presets")
    commands.add_parser("list", help="List recent jobs on this device")
    commands.add_parser("mcp", help="Serve local read-only MCP tools for this verified SSH host")
    start = commands.add_parser("start", help="Start a Linux project preset")
    start.add_argument("project")
    start.add_argument("preset")
    start.add_argument("--ticket", help="Reuse the same 32-character job ID when retrying")
    for command in ("status", "cancel", "artifact"):
        target = commands.add_parser(command)
        target.add_argument("job")
        if command == "artifact":
            target.add_argument("output", type=Path, help="Save to a new local file")
    args = parser.parse_args()

    try:
        if args.command == "mcp":
            serve_mcp(args.host)
            return
        if args.command in {"device", "projects"}:
            reply = request(args.host, "pair")
            result = reply if args.command == "device" else reply.get("projects", [])
        elif args.command == "start":
            ticket = args.ticket or uuid.uuid4().hex
            if not re.fullmatch(r"[0-9a-f]{32}", ticket):
                raise ValueError("Enter a 32-character lowercase hexadecimal job ID.")
            print(f"Job ID: {ticket}", file=sys.stderr, flush=True)
            result = request(args.host, "job-start", project=args.project, preset=args.preset, job=ticket)
        elif args.command == "list":
            result = request(args.host, "job-list")
        else:
            result = request(args.host, f"job-{args.command}", job=args.job)
            if args.command == "artifact":
                artifact = result.pop("artifact")
                data = base64.b64decode(artifact["data"], validate=True)
                if len(data) > 2 * 1024 * 1024 or sha256(data).hexdigest() != artifact["sha256"]:
                    raise ValueError("The job artifact failed its checksum check.")
                descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "wb") as output:
                    output.write(data)
                result["savedTo"] = str(args.output)
        print(json.dumps(result))
    except (OSError, subprocess.SubprocessError, TypeError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
