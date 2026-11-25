#!/usr/bin/env python3
"""Handoff Fox's user-level SSH receiver. Accept one JSON request on stdin."""

import base64
from collections import deque
from contextlib import contextmanager
import fcntl
from hashlib import sha256
from html.parser import HTMLParser
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import ssl
from stat import S_ISREG
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urljoin, urlsplit
import uuid

VERSION = 1
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "desktop-link/projects.json"
MAX_REQUEST = 420_000
MAX_OUTPUT = 48_000
MAX_PAGE = 512_000
MAX_ARTIFACT = 2 * 1024 * 1024
MAX_CLIPBOARD = 64 * 1024
MAX_FILE = 128 * 1024 * 1024
OUTBOX = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "desktop-link/outbox"
JOBS = OUTBOX.parent / "jobs"
JOB_TIMEOUT = 900
ACTIVE_JOB_STATES = {"queued", "running", "cancelling"}


class RequestError(Exception):
    pass


def projects():
    if not CONFIG.exists():
        return []
    return json.loads(CONFIG.read_text())["projects"]


def display(project):
    return {key: project[key] for key in ("id", "name")} | {
        "canBuild": bool(project.get("build")),
        "presets": [{"id": preset["id"], "name": preset["name"]} for preset in job_presets(project)],
    }


def save_project(name, path):
    if not isinstance(name, str) or not name.strip() or len(name) > 64:
        raise RequestError("Enter a project name of up to 64 characters.")
    if not isinstance(path, str) or not Path(path).expanduser().is_absolute():
        raise RequestError("Enter an absolute folder path on Linux.")
    directory = Path(path).expanduser().resolve(strict=True)
    if not directory.is_dir():
        raise RequestError("The saved path must be a directory.")
    CONFIG.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with CONFIG.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entries = projects()
        if any(entry["path"] == str(directory) for entry in entries):
            raise RequestError("That folder is already saved.")
        if len(entries) >= 50:
            raise RequestError("This receiver can hold up to 50 projects.")
        entry = {"id": uuid.uuid4().hex, "name": name.strip(), "path": str(directory)}
        entries.append(entry)
        with tempfile.NamedTemporaryFile(mode="w", dir=CONFIG.parent, delete=False) as temp:
            json.dump({"projects": entries}, temp)
        os.replace(temp.name, CONFIG)
    return {"projects": [display(item) for item in entries]}


def launch_graphical(arguments, directory=None):
    # OpenSSH sessions normally have no display variables. Use the Linux user's
    # graphical service manager or the current graphical session, if available.
    if shutil.which("systemd-run"):
        session = subprocess.run(["systemctl", "--user", "is-active", "graphical-session.target"],
                                 capture_output=True, timeout=4, check=False)
        if session.returncode == 0:
            found = subprocess.run(
                ["systemd-run", "--user", "--quiet", "--collect", "--property=Type=exec",
                 "--property=ExitType=cgroup",
                 *([f"--working-directory={directory}"] if directory else []), "--", *arguments],
                capture_output=True, timeout=4, check=False,
            )
            if found.returncode == 0:
                return
    env = graphical_environment()
    if env.get("WAYLAND_DISPLAY") or env.get("DISPLAY"):
        subprocess.Popen(arguments, cwd=directory, env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return
    raise RequestError("Open a graphical Linux session before using this action.")


def open_desktop(target):
    launch_graphical(["xdg-open", str(target)])


def open_terminal(directory):
    candidates = [
        ("xdg-terminal-exec", [f"--dir={directory}"]),
        ("foot", [f"--working-directory={directory}"]),
        ("alacritty", ["--working-directory", str(directory)]),
        ("ghostty", [f"--working-directory={directory}"]),
        ("kitty", ["--directory", str(directory)]),
        ("gnome-terminal", [f"--working-directory={directory}"]),
        ("konsole", ["--workdir", str(directory)]),
        ("xterm", []),
    ]
    for program, arguments in candidates:
        if executable := shutil.which(program):
            launch_graphical([executable, *arguments], directory)
            return
    raise RequestError("Install a graphical terminal on Linux before opening this project.")


def storage():
    volumes = [("home", "System & home", Path.home())]
    if os.path.ismount("/workspace") and os.access("/workspace", os.W_OK):
        volumes.append(("workspace", "Workspace", Path("/workspace")))
    summaries = []
    for key, name, path in volumes:
        usage = shutil.disk_usage(path)
        summaries.append({"id": key, "name": name, "path": str(path),
                          "free": usage.free, "total": usage.total})
    return summaries


def file_name(name):
    if (not isinstance(name, str) or not name or len(name.encode()) > 220
            or name.startswith(".") or "/" in name or "\\" in name
            or re.search(r"[\x00-\x1f\x7f]", name)):
        raise RequestError("Choose a regular file with a visible filename.")
    if name.lower().endswith((".pem", ".key", ".p12", ".kdbx")) or name.lower() in {"credentials", "cookies"}:
        raise RequestError("Choose a project file without credentials.")
    return name


def browser_url(url):
    if not isinstance(url, str) or not url or len(url) > 4096 or re.search(r"[\x00-\x20\x7f]", url):
        raise RequestError("Enter a complete HTTP or HTTPS link.")
    parts = urlsplit(url)
    if parts.scheme not in {"http", "https"} or not parts.hostname or parts.username or parts.password:
        raise RequestError("Enter an HTTP or HTTPS link without embedded credentials.")
    return url


def ticket_id(token):
    if not isinstance(token, str) or not re.fullmatch("[0-9a-f]{32}", token):
        raise RequestError("Invalid handoff ID.")
    return token


def mailbox():
    OUTBOX.mkdir(parents=True, exist_ok=True, mode=0o700)
    return sorted(OUTBOX.glob("*.json"), key=lambda path: path.stat().st_mtime_ns)


def queue_for_mac(kind, value=None):
    if len(mailbox()) >= 12:
        raise RequestError("There are 12 transfers waiting for your Mac.")
    token = uuid.uuid4().hex
    item = {"id": token, "kind": kind}
    payload = OUTBOX / f"{token}.bin"
    temporary = OUTBOX / f"{token}.part"
    if kind == "file":
        selected = Path(value)
        item["name"] = file_name(selected.name)
        if not selected.is_file():
            raise RequestError("Choose a regular file.")
        with selected.open("rb") as source, payload.open("xb") as target:
            try:
                item["size"], item["sha256"] = copy_file(source, target)
            except BaseException:
                payload.unlink(missing_ok=True)
                raise
    elif kind == "link":
        item["url"] = browser_url(value)
    elif kind not in {"projects", "desktop"}:
        raise RequestError("Unknown handoff.")
    try:
        temporary.write_text(json.dumps(item))
        os.replace(temporary, OUTBOX / f"{token}.json")
    except OSError:
        temporary.unlink(missing_ok=True)
        payload.unlink(missing_ok=True)
        raise
    return item


def copy_file(source, target, expected=None):
    digest = sha256()
    total = 0
    while buffer := source.read(min(262_144, MAX_FILE + 1 - total)):
        total += len(buffer)
        if total > MAX_FILE or (expected is not None and total > expected):
            raise RequestError("Files can be up to 128 MiB.")
        digest.update(buffer)
        if target is not None:
            target.write(buffer)
    if expected is not None and total != expected:
        raise RequestError("The transfer stopped before all bytes arrived.")
    return total, digest.hexdigest()


def upload_file(durable=False):
    header = json.loads(sys.stdin.buffer.readline(8192))
    name = file_name(header["name"])
    token = ticket_id(header["id"])
    size = header["size"]
    volume = header["volume"]
    if type(size) is not int or not 0 <= size <= MAX_FILE:
        raise RequestError("Files can be up to 128 MiB.")
    expected = header.get("sha256")
    if durable and (not isinstance(expected, str) or not re.fullmatch("[0-9a-f]{64}", expected)):
        raise RequestError("The file checksum is missing or invalid.")
    if volume == "home":
        folder = Path.home() / "Downloads/Handoff Fox"
    elif volume == "workspace" and any(item["id"] == "workspace" for item in storage()):
        folder = Path("/workspace/Handoff Fox/Inbox")
    else:
        raise RequestError("The selected Linux volume is unavailable.")
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    if shutil.disk_usage(folder).free < size:
        raise RequestError("The selected Linux volume is full.")
    destination = folder / name
    if destination.exists():
        path = Path(name)
        destination = folder / f"{path.stem[:140]}-{token[:8]}{path.suffix}"
    with tempfile.NamedTemporaryFile(dir=folder) as temp:
        _, digest = copy_file(sys.stdin.buffer, temp, size)
        temp.flush()
        if durable:
            if digest != expected:
                raise RequestError("The file checksum did not match.")
            os.fsync(temp.fileno())
            return commit_upload(folder, Path(temp.name), token, name, volume, size, digest)
        os.link(temp.name, destination)
    return {"path": str(destination), "sha256": digest}


def transfer_receipts():
    receipts = OUTBOX.with_name("receipts")
    receipts.mkdir(parents=True, exist_ok=True, mode=0o700)
    return receipts


def save_transfer_receipt(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as temp:
        temporary = Path(temp.name)
        try:
            json.dump(value, temp)
            temp.flush()
            os.fsync(temp.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def commit_upload(folder, staged, token, name, volume, size, digest):
    receipts = transfer_receipts()
    receipt = receipts / f"file-{token}.json"
    manifest = {"name": name, "volume": volume, "size": size, "sha256": digest}
    path = Path(name)
    collision = folder / f"{path.stem}-{token}{path.suffix}"

    # Record the destination before publishing the file. A retry can verify
    # the same file after a lost receipt or an interrupted SSH command.
    with (receipts / "files.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(receipt.read_text()) if receipt.exists() else None
        if state is not None:
            if state.get("manifest") != manifest:
                raise RequestError("This transfer ticket belongs to a different file.")
            destination = Path(state["path"])
            if destination not in {folder / name, collision}:
                raise RequestError("The destination for this transfer has changed.")
            if state.get("delivered"):
                return {"path": str(destination), "sha256": digest}
        else:
            destination = folder / name
            if os.path.lexists(destination):
                destination = collision
            state = {"manifest": manifest, "path": str(destination), "delivered": False}
            save_transfer_receipt(receipt, state)

        try:
            os.link(staged, destination)
        except FileExistsError:
            # Never follow a symlink or read a special file when recovering
            # an interrupted commit at a planned destination.
            descriptor = os.open(destination, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as existing:
                if not S_ISREG(os.fstat(existing.fileno()).st_mode):
                    raise RequestError("The transfer destination is occupied.")
                _, actual = copy_file(existing, None, size)
            if actual != digest:
                raise RequestError("A different file occupies the transfer destination.")
        state["delivered"] = True
        save_transfer_receipt(receipt, state)
        return {"path": str(destination), "sha256": digest}


def deliver_link(value, ticket):
    token = ticket_id(ticket)
    url = browser_url(value)
    digest = sha256(url.encode()).hexdigest()
    receipts = transfer_receipts()
    receipt = receipts / f"link-{token}.json"
    with (receipts / "links.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if receipt.exists():
            state = json.loads(receipt.read_text())
            if state.get("sha256") != digest:
                raise RequestError("This transfer ticket belongs to a different link.")
            if state.get("delivered"):
                return {}
            raise RequestError("The earlier link attempt may have opened. Send the link again to open a new copy.")
        state = {"sha256": digest, "delivered": False}
        save_transfer_receipt(receipt, state)
        try:
            open_desktop(url)
        except RequestError:
            receipt.unlink(missing_ok=True)
            raise
        state["delivered"] = True
        save_transfer_receipt(receipt, state)
        return {}


def reveal_upload(ticket):
    token = ticket_id(ticket)
    path = transfer_receipts() / f"file-{token}.json"
    if not path.is_file():
        raise RequestError("The saved transfer receipt is unavailable on Linux.")
    state = json.loads(path.read_text())
    if not state.get("delivered"):
        raise RequestError("This file has not finished transferring.")
    folder = Path(state["path"]).parent
    if not folder.is_dir():
        raise RequestError("The transfer destination is unavailable on Linux.")
    open_desktop(folder)
    return {}


def upload_status(ticket, digest):
    token = ticket_id(ticket)
    path = transfer_receipts() / f"file-{token}.json"
    if not path.is_file():
        return {}
    state = json.loads(path.read_text())
    if state["manifest"]["sha256"] != digest:
        raise RequestError("This transfer ticket belongs to a different file.")
    if not state.get("delivered"):
        return {}
    return {"path": state["path"], "sha256": digest}


def graphical_environment():
    env = os.environ.copy()
    if not (env.get("WAYLAND_DISPLAY") or env.get("DISPLAY")) and shutil.which("systemctl"):
        session = subprocess.run(["systemctl", "--user", "show-environment"],
                                 capture_output=True, text=True, timeout=4, check=False)
        for line in session.stdout.splitlines():
            name, _, value = line.partition("=")
            if name in {"WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR"}:
                env[name] = value
    return env


def clipboard_tools():
    env = graphical_environment()
    if env.get("WAYLAND_DISPLAY") and shutil.which("wl-copy") and shutil.which("wl-paste"):
        return (["wl-copy", "--type", "text/plain;charset=utf-8"],
                ["wl-paste", "--no-newline", "--type", "text"], ["wl-paste", "--list-types"], env)
    if env.get("DISPLAY") and shutil.which("xclip"):
        base = ["xclip", "-selection", "clipboard"]
        return (base + ["-in"], base + ["-out", "-target", "UTF8_STRING"],
                base + ["-out", "-target", "TARGETS"], env)
    raise RequestError("Start a Linux desktop session with wl-clipboard or xclip installed.")


def clipboard_text(value):
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > MAX_CLIPBOARD:
        raise RequestError("Copy nonempty plain text up to 64 KiB.")
    return value.encode()


def put_clipboard(value, copy, env):
    completed = subprocess.run(copy, input=clipboard_text(value), env=env, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=6, check=False)
    if completed.returncode:
        raise RequestError("Linux could not write its desktop clipboard.")


def protected_clipboard(names):
    names = names.lower()
    return any(hint in names for hint in (
        b"passwordmanagerhint", b"org.nspasteboard.concealedtype", b"org.nspasteboard.transienttype",
    ))


def clipboard(action, value=None):
    copy, paste, formats, env = clipboard_tools()
    if action == "clipboard-put":
        put_clipboard(value, copy, env)
        return {}
    available = subprocess.run(formats, env=env, capture_output=True, timeout=5, check=False)
    if available.returncode:
        raise RequestError("Copy some text on Linux first.")
    if protected_clipboard(available.stdout):
        raise RequestError("Linux marked this clipboard item as sensitive.")
    with subprocess.Popen(paste, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        signal.alarm(6)
        try:
            data = process.stdout.read(MAX_CLIPBOARD + 1)
            if len(data) > MAX_CLIPBOARD:
                raise RequestError("Linux clipboard text exceeds 64 KiB.")
            if process.wait(timeout=2) or not data:
                raise RequestError("The Linux clipboard has no supported text.")
            return {"text": data.decode("utf-8")}
        finally:
            signal.alarm(0)
            if process.poll() is None:
                process.kill()


def send_clipboard_frame(kind, **fields):
    print(json.dumps({"kind": kind} | fields), flush=True)


def clipboard_event(marker):
    # wl-paste invokes this once per selection and waits for the helper to exit.
    if not marker.exists():
        marker.touch()
        send_clipboard_frame("ready")
        return
    # Older wl-clipboard versions omit both event metadata variables.
    state = os.environ.get("CLIPBOARD_STATE")
    if state is not None and state != "data":
        return
    mime = os.environ.get("CLIPBOARD_TYPE")
    if mime and not mime.startswith("text/plain") and mime not in {"UTF8_STRING", "TEXT", "STRING"}:
        return
    formats = subprocess.run(["wl-paste", "--list-types"], capture_output=True, timeout=3, check=False)
    names = formats.stdout.splitlines()
    if (formats.returncode or protected_clipboard(formats.stdout)
            or not any(name.startswith(b"text/plain") or name == b"UTF8_STRING" for name in names)):
        return
    signal.alarm(4)
    try:
        raw = sys.stdin.buffer.read(MAX_CLIPBOARD + 1)
        if raw and b"\x00" not in raw and len(raw) <= MAX_CLIPBOARD:
            send_clipboard_frame("clipboard", text=raw.decode())
    finally:
        signal.alarm(0)


def clipboard_stream():
    copy, _, _, env = clipboard_tools()
    if copy[0] != "wl-copy":
        raise RequestError("Automatic text sharing requires a Wayland session.")
    with tempfile.TemporaryDirectory(prefix="handoff-fox-clip-") as temp:
        marker = Path(temp) / "ready"
        watch = subprocess.Popen(["wl-paste", "--no-newline", "--watch", sys.executable,
                                  os.path.realpath(__file__), "--clipboard-event", str(marker)],
                                 env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL)
        source, incoming = watch.stdout.fileno(), sys.stdin.fileno()
        buffers = {source: bytearray(), incoming: bytearray()}
        ready = False
        echoes = deque(maxlen=8)
        expires = time.monotonic() + 28
        try:
            while watch.poll() is None and time.monotonic() < expires:
                available, _, _ = select.select([source, incoming], [], [], 1)
                for fd in available:
                    chunk = os.read(fd, 8192)
                    if not chunk:
                        return
                    buf = buffers[fd]
                    buf.extend(chunk)
                    while b"\n" in buf:
                        at = buf.index(b"\n")
                        if at > MAX_REQUEST:
                            raise RequestError("Clipboard frame is too large.")
                        frame = json.loads(buf[:at])
                        del buf[:at + 1]
                        kind = frame.get("kind")
                        if fd == incoming:
                            expires = time.monotonic() + 28
                            if kind == "clipboard" and ready:
                                value = frame.get("text")
                                data = clipboard_text(value)
                                put_clipboard(value, copy, env)
                                echoes.append((sha256(data).digest(), time.monotonic() + 3))
                        elif kind == "ready":
                            ready = True
                            send_clipboard_frame("ready")
                        elif kind == "clipboard" and ready:
                            value = frame.get("text")
                            digest = sha256(clipboard_text(value)).digest()
                            now = time.monotonic()
                            while echoes and echoes[0][1] < now:
                                echoes.popleft()
                            match = next((entry for entry in echoes if entry[0] == digest), None)
                            if match is None:
                                send_clipboard_frame("clipboard", text=value)
                            else:
                                echoes.remove(match)
                    if len(buf) > MAX_REQUEST:
                        raise RequestError("Clipboard frame is too large.")
        finally:
            if watch.poll() is None:
                watch.terminate()
                try:
                    watch.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    watch.kill()
                    watch.wait()
            watch.stdout.close()


def build_project(project, directory):
    args = project.get("build")
    if not args:
        raise RequestError("This project has no build preset on Linux.")
    if not isinstance(args, list) or not all(isinstance(argument, str) for argument in args):
        raise RequestError("The Linux build preset must be a list of executable arguments.")
    # The preset lives on Linux. Requests never supply command arguments.
    env = {key: value for key, value in os.environ.items()
           if key in {"HOME", "USER", "PATH", "LANG", "LC_ALL", "TMPDIR", "XDG_CACHE_HOME"}}
    start = time.monotonic()
    process = subprocess.Popen(args, cwd=directory, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    tail = bytearray()
    length = 0

    def collect():
        nonlocal length
        with process.stdout as output:
            while chunk := output.read1(8192):
                length += len(chunk)
                tail.extend(chunk)
                del tail[:-MAX_OUTPUT]

    reader = threading.Thread(target=collect, daemon=True)
    reader.start()
    try:
        code = process.wait(timeout=90)
        reader.join(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        reader.join(timeout=1)
        raise RequestError("Build exceeded the 90-second limit.")

    if reader.is_alive():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        reader.join(timeout=1)
        raise RequestError("Build left a process running after exit.")

    receipt = {"title": project["name"], "output": tail.decode(errors="replace"), "exitCode": code,
               "truncated": length > MAX_OUTPUT, "elapsedMs": round((time.monotonic() - start) * 1000)}
    if code == 0 and project.get("artifact"):
        path = (directory / project["artifact"]).resolve()
        if directory not in path.parents or not path.is_file():
            receipt["artifactError"] = "The configured build file is missing or outside the project."
        else:
            with path.open("rb") as file:
                data = file.read(MAX_ARTIFACT + 1)
            if len(data) > MAX_ARTIFACT:
                receipt["artifactError"] = "The build file is above the 2 MiB transfer limit."
            else:
                receipt["artifact"] = {"name": path.name, "data": base64.b64encode(data).decode("ascii"),
                                       "sha256": sha256(data).hexdigest()}
    return receipt


def job_presets(project):
    configured = project.get("presets", [])
    presets = []
    if project.get("build"):
        presets.append({"id": "build", "name": "Build", "argv": project["build"],
                        "artifact": project.get("artifact")})
    if isinstance(configured, list):
        presets.extend(configured)
    known = set()
    for preset in presets:
        if not isinstance(preset, dict):
            continue
        key, name, argv = (preset.get(field) for field in ("id", "name", "argv"))
        if (not isinstance(key, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", key)
                or key in known or not isinstance(name, str) or not name.strip() or len(name) > 64
                or not isinstance(argv, list) or not argv or not argv[0]
                or not all(isinstance(arg, str) and "\x00" not in arg for arg in argv)):
            continue
        known.add(key)
        yield preset


def job_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{32}", value):
        raise RequestError("Invalid job ID.")
    return value


def atomic_job_file(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        try:
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
            os.replace(temporary.name, path)
        finally:
            Path(temporary.name).unlink(missing_ok=True)


@contextmanager
def job_transaction():
    JOBS.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (JOBS / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def write_job(directory, job, **changes):
    job.update(changes, updatedAt=time.time())
    atomic_job_file(directory / "job.json", json.dumps(job).encode())
    # Persist the renamed directory entry as well as the file content.
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return job


def read_job(directory):
    try:
        return json.loads((directory / "job.json").read_text())
    except FileNotFoundError as error:
        raise RequestError("This job was not found on Linux.") from error


def recover_job(directory, job):
    if job["state"] not in ACTIVE_JOB_STATES:
        return job
    with (directory / "worker.lock").open("a") as owner:
        try:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return job
        return write_job(directory, job, state="failed", error="The Linux job worker stopped.")


def project_build_lock(project_id):
    return CONFIG.parent / f"build-{sha256(project_id.encode()).hexdigest()}.lock"


def start_job(payload):
    identifier = job_id(payload.get("job"))
    directory = JOBS / identifier
    project_id = payload.get("project")
    preset_id = payload.get("preset", "build")
    with job_transaction():
        if (directory / "job.json").is_file():
            job = read_job(directory)
            if (job["project"], job["preset"]) != (project_id, preset_id):
                raise RequestError("This job ID already refers to another project or preset.")
            return recover_job(directory, job)

        project = next((entry for entry in projects() if entry["id"] == project_id), None)
        if project is None:
            raise RequestError("This project is no longer saved on Linux.")
        preset = next((entry for entry in job_presets(project) if entry["id"] == preset_id), None)
        if preset is None:
            raise RequestError("This job preset is not configured on Linux.")
        cwd = Path(project["path"]).expanduser().resolve(strict=True)
        if not cwd.is_dir():
            raise RequestError("The project folder is unavailable.")
        spec = {"cwd": str(cwd), "argv": preset["argv"], "artifact": preset.get("artifact")}
        if spec["artifact"] is not None and not isinstance(spec["artifact"], str):
            raise RequestError("The Linux artifact must be a file path.")
        with project_build_lock(project_id).open("a") as project_lock:
            try:
                fcntl.flock(project_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RequestError("This project already has a build or job running.") from error

            directory.mkdir(exist_ok=True, mode=0o700)
            created = {"id": identifier, "project": project_id, "preset": preset_id,
                       "title": f"{project['name']} · {preset['name']}", "createdAt": time.time()}
            with (directory / "worker.lock").open("a") as worker_lock:
                fcntl.flock(worker_lock, fcntl.LOCK_EX)
                result = write_job(directory, created, state="queued")
                descriptors = (worker_lock.fileno(), project_lock.fileno())
                try:
                    # Pass the approved snapshot without keeping the command in the
                    # job history or making its arguments visible in the worker argv.
                    with tempfile.TemporaryFile(dir=directory) as specification:
                        specification.write(json.dumps(spec).encode())
                        specification.seek(0)
                        subprocess.Popen(
                            [sys.executable, str(Path(__file__).resolve()), "--run-job", identifier,
                             *(str(fd) for fd in descriptors)],
                            stdin=specification, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True, pass_fds=descriptors,
                        )
                except (OSError, subprocess.SubprocessError):
                    result = write_job(directory, result, state="failed",
                                       error="The Linux job worker could not start.")
                return result


def stop_job_group(pid, signum):
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        pass


def read_job_file(path, limit, parent=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(descriptor, "rb") as file:
        if not S_ISREG(os.fstat(file.fileno()).st_mode):
            raise OSError("Expected a regular job file.")
        return file.read(limit + 1)


def collect_job_output(process, directory, supervisor):
    tail = bytearray()
    length = 0
    saved_length = 0
    last_save = time.monotonic()
    started = last_save
    exited = None
    ended = False
    error = None
    try:
        while True:
            now = time.monotonic()
            state = read_job(directory)["state"]
            if state == "cancelling":
                stop_job_group(process.pid, signal.SIGTERM)
                time.sleep(0.3)
                break
            if now - started >= JOB_TIMEOUT:
                error = f"The job exceeded the {JOB_TIMEOUT}-second limit."
                break
            # Observe exit without reaping the process-group leader. Its ID stays
            # allocated until we've stopped leftover descendants.
            if os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT):
                exited = now if exited is None else exited
                if ended:
                    break
                if now - exited > 1:
                    error = "The preset left a process running after exit."
                    break
            readable = select.select([supervisor] if ended else [supervisor, process.stdout],
                                     [], [], 0.12)[0]
            if supervisor in readable:
                error = "The Linux job supervisor stopped."
                break
            if process.stdout in readable:
                chunk = os.read(process.stdout.fileno(), 8192)
                if chunk:
                    length += len(chunk)
                    tail.extend(chunk)
                    del tail[:-MAX_OUTPUT]
                else:
                    ended = True
            if length != saved_length and now - last_save >= 0.4:
                atomic_job_file(directory / "output.log", tail)
                last_save, saved_length = now, length
    finally:
        try:
            stop_job_group(process.pid, signal.SIGKILL)
        except PermissionError:
            # Darwin reports EPERM for a group containing only its zombie
            # leader. When descendants remain it still delivers the signal.
            if sys.platform != "darwin" or not os.waitid(
                os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT,
            ):
                raise
        finally:
            code = process.wait()
    atomic_job_file(directory / "output.log", tail)
    return code, length > MAX_OUTPUT, error


def save_job_artifact(directory, root, name):
    if not name:
        return {}
    try:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise RequestError("The configured job artifact must be relative to the project.")
        visible_name = file_name(path.name)
        # Open each component relative to its already-open parent. A linked
        # output folder must not turn a project artifact into a read elsewhere.
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        parent = os.open(root, directory_flags)
        try:
            for part in path.parts[:-1]:
                child = os.open(part, directory_flags, dir_fd=parent)
                os.close(parent)
                parent = child
            data = read_job_file(visible_name, MAX_ARTIFACT, parent)
        finally:
            os.close(parent)
        if len(data) > MAX_ARTIFACT:
            raise RequestError("The job artifact is above the 2 MiB transfer limit.")
        atomic_job_file(directory / "artifact.bin", data)
        return {"artifactName": visible_name, "artifactSha256": sha256(data).hexdigest()}
    except RequestError as error:
        return {"artifactError": str(error)}
    except (OSError, ValueError):
        return {"artifactError": "The configured job artifact could not be collected."}


def run_job(identifier, worker_fd, project_fd):
    # Only this supervisor owns the write end. The monitor survives a signal
    # to the supervisor's PID or process group and observes EOF immediately.
    read_end, write_end = os.pipe()
    with os.fdopen(read_end, "rb"), os.fdopen(write_end, "wb"):
        with subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--watch-job", identifier,
             str(worker_fd), str(project_fd), str(read_end)],
            stdin=sys.stdin, start_new_session=True, pass_fds=(worker_fd, project_fd, read_end),
        ) as monitor:
            monitor.wait()


def watch_job(identifier, worker_fd, project_fd, supervisor_fd):
    directory = JOBS / job_id(identifier)
    # These are inherited open file descriptions from start_job. Keep both
    # locks held through the final job state write.
    with (os.fdopen(worker_fd, "rb") as owner, os.fdopen(project_fd, "rb") as project_lock,
          os.fdopen(supervisor_fd, "rb") as supervisor):
        if not os.path.samestat(os.fstat(owner.fileno()), (directory / "worker.lock").stat()):
            return
        fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with job_transaction():
            job = read_job(directory)
            if job["state"] == "cancelling":
                write_job(directory, job, state="cancelled")
                return
            if job["state"] != "queued":
                return
            if select.select([supervisor], [], [], 0)[0]:
                write_job(directory, job, state="failed", error="The Linux job supervisor stopped.")
                return
            write_job(directory, job, state="running")

        started = time.monotonic()
        fields = {}
        try:
            spec = json.load(sys.stdin)
            env = {key: os.environ[key] for key in
                   ("HOME", "USER", "PATH", "LANG", "LC_ALL", "TMPDIR", "XDG_CACHE_HOME")
                   if key in os.environ}
            with subprocess.Popen(
                spec["argv"], cwd=spec["cwd"], env=env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
                pass_fds=(project_lock.fileno(),),
            ) as process:
                code, truncated, error = collect_job_output(process, directory, supervisor)
            fields.update(exitCode=code, truncated=truncated)
            if error:
                fields["error"] = error
            elif code == 0 and read_job(directory)["state"] != "cancelling":
                fields.update(save_job_artifact(directory, Path(spec["cwd"]), spec.get("artifact")))
        except (OSError, TypeError, ValueError, KeyError, subprocess.SubprocessError):
            fields["error"] = "The Linux job could not run. Check the configured executable and folder."

        with job_transaction():
            job = read_job(directory)
            if job["state"] == "cancelling":
                fields = {key: value for key, value in fields.items() if key in {"exitCode", "truncated"}}
                state = "cancelled"
            else:
                state = "succeeded" if fields.get("exitCode") == 0 and not fields.get("error") else "failed"
            write_job(directory, job, state=state, elapsedMs=round((time.monotonic() - started) * 1000),
                      **fields)


def job_request(action, payload):
    if action == "job-start":
        return {"job": start_job(payload)}
    with job_transaction():
        if action == "job-list":
            records = sorted(JOBS.glob("*/job.json"), key=lambda path: path.stat().st_mtime_ns, reverse=True)
            return {"jobs": [recover_job(path.parent, read_job(path.parent)) for path in records[:50]]}
        directory = JOBS / job_id(payload.get("job"))
        job = recover_job(directory, read_job(directory))
        if action == "job-cancel" and job["state"] in {"queued", "running"}:
            job = write_job(directory, job, state="cancelling")
    if action == "job-status":
        try:
            output = read_job_file(directory / "output.log", MAX_OUTPUT)
        except FileNotFoundError:
            output = b""
        return {"job": job, "output": output[:MAX_OUTPUT].decode(errors="replace"),
                "truncated": job.get("truncated", False) or len(output) > MAX_OUTPUT}
    if action == "job-artifact":
        if job["state"] != "succeeded" or not job.get("artifactName"):
            raise RequestError(job.get("artifactError") or "This job has no available artifact.")
        try:
            data = read_job_file(directory / "artifact.bin", MAX_ARTIFACT)
        except OSError as error:
            raise RequestError("This job artifact is no longer available.") from error
        digest = sha256(data).hexdigest()
        if len(data) > MAX_ARTIFACT or digest != job["artifactSha256"]:
            raise RequestError("The saved job artifact failed its checksum check.")
        return {"job": job, "artifact": {"name": job["artifactName"],
                                        "data": base64.b64encode(data).decode("ascii"), "sha256": digest}}
    return {"job": job}


def public_addresses(host):
    records = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    for family, _, _, _, address in records:
        ip = ipaddress.ip_address(address[0])
        if (family not in (socket.AF_INET, socket.AF_INET6)
                or not ip.is_global or ip.is_multicast or ip.is_reserved):
            raise RequestError("Scrape is limited to public HTTPS destinations.")
    return list(dict.fromkeys(record[4][0] for record in records))


class PublicHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        # Validate and connect to the same address, with TLS still checked for the hostname.
        last_error = OSError("The hostname has no public address.")
        for address in public_addresses(self.host):
            try:
                with_socket = socket.create_connection((address, 443), self.timeout)
                try:
                    self.sock = self._context.wrap_socket(with_socket, server_hostname=self.host)
                except BaseException:
                    with_socket.close()
                    raise
                return
            except OSError as error:
                last_error = error
        raise last_error


class PageText(HTMLParser):
    blocks = {"p", "div", "section", "article", "h1", "h2", "h3", "li", "br"}
    ignored = {"script", "style", "noscript", "template"}

    def __init__(self):
        super().__init__()
        self.parts = []
        self.skip = 0
        self.in_title = False
        self.title = ""

    def handle_starttag(self, tag, attrs):
        if tag in self.ignored:
            self.skip += 1
        if tag == "title":
            self.in_title = True
        if tag in self.blocks and not self.skip:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in self.ignored:
            self.skip = max(0, self.skip - 1)
        if tag == "title":
            self.in_title = False
        if tag in self.blocks and not self.skip:
            self.parts.append("\n")

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        elif not self.skip:
            self.parts.append(data)


def scrape(url):
    if not isinstance(url, str) or len(url) > 2048:
        raise RequestError("Enter a public HTTPS URL.")
    start = time.monotonic()
    for _ in range(5):
        if re.search(r"[\x00-\x20\x7f]", url):
            raise RequestError("The URL contains unescaped spaces or controls.")
        parsed = urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise RequestError("Use a public HTTPS URL without credentials.")
        if parsed.port not in (None, 443):
            raise RequestError("Only the standard HTTPS port is supported.")
        host = parsed.hostname.encode("idna").decode()
        connection = PublicHTTPSConnection(host, timeout=5, context=ssl.create_default_context())
        try:
            target = parsed.path or "/"
            if parsed.query:
                target += "?" + parsed.query
            connection.request("GET", target, headers={"Accept": "text/html,text/plain",
                                                       "Accept-Encoding": "identity",
                                                       "User-Agent": "DesktopLink/1.0"})
            response = connection.getresponse()
            if response.status in (301, 302, 303, 307, 308) and response.getheader("Location"):
                url = urljoin(url, response.getheader("Location"))
                continue
            if response.status != 200:
                raise RequestError(f"The site returned HTTP {response.status}.")
            mime = response.headers.get_content_type()
            if mime not in {"text/html", "text/plain", "application/xhtml+xml"}:
                raise RequestError("The page must contain HTML or plain text.")
            if response.getheader("Content-Encoding", "identity").lower() != "identity":
                raise RequestError("The website returned an unsupported text encoding.")
            raw = response.read(MAX_PAGE + 1)
            page = raw[:MAX_PAGE].decode(response.headers.get_content_charset() or "utf-8", errors="replace")
        finally:
            connection.close()
        if mime == "text/plain":
            title, output = host, page
        else:
            parser = PageText()
            parser.feed(page)
            title = " ".join(parser.title.split())[:120] or host
            lines = [" ".join(line.split()) for line in "".join(parser.parts).splitlines()]
            output = "\n".join(line for line in lines if line)
        return {"title": title, "output": output[:MAX_OUTPUT], "exitCode": 0,
                "truncated": len(raw) > MAX_PAGE or len(output) > MAX_OUTPUT,
                "elapsedMs": round((time.monotonic() - start) * 1000)}
    raise RequestError("The website redirected too many times.")


def desktop_status():
    if not shutil.which("gliff-server"):
        return "needsGliff"
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    for endpoint in (runtime / "hypr").glob("*/.socket.sock"):
        with socket.socket(socket.AF_UNIX) as compositor:
            compositor.settimeout(0.2)
            try:
                compositor.connect(str(endpoint))
                return "ready"
            except OSError:
                continue
    return "needsHyprland"


def request(payload):
    if payload.get("version") != VERSION:
        raise RequestError("Update the Mac and Linux components to the same protocol version.")
    action = payload.get("action")
    if action == "pair":
        try:
            clipboard_tools()
            clipboard_available = True
        except (OSError, RequestError, subprocess.SubprocessError):
            clipboard_available = False
        return {"name": socket.gethostname(), "system": "Linux",
                "projects": [display(item) for item in projects()], "volumes": storage(),
                "desktopStatus": desktop_status(), "clipboardAvailable": clipboard_available,
                "jobProtocol": 1, "transferProtocol": 1}
    if action in {"job-start", "job-list", "job-status", "job-cancel", "job-artifact"}:
        return job_request(action, payload)
    if action == "desktop":
        status = desktop_status()
        if status == "needsHyprland":
            raise RequestError("Sign in to Hyprland on Linux, then try Open Desktop again.")
        server = shutil.which("gliff-server")
        if not server:
            raise RequestError("Install Gliff on this Linux device to open its desktop.")
        version = subprocess.run([server, "--version"], capture_output=True, text=True, timeout=3, check=True)
        reply = {"title": version.stdout.strip()}
        if probe := shutil.which("gliff-probe"):
            displays = subprocess.run([probe, "outputs"], capture_output=True, text=True, timeout=5)
            if displays.returncode == 0:
                outputs = re.findall(r"^\s*wl_output ([A-Za-z0-9_.-]+) ", displays.stdout, re.MULTILINE)
                reply["desktopOutput"] = next((name for name in outputs if not name.startswith("gliff-")), None)
        return reply
    if action == "open-link":
        open_desktop(browser_url(payload.get("url")))
        return {}
    if action == "deliver-link":
        return deliver_link(payload.get("url"), payload.get("project"))
    if action == "reveal-upload":
        return reveal_upload(payload.get("project"))
    if action == "upload-status":
        return upload_status(payload.get("project"), payload.get("text"))
    if action == "pending":
        deadline_at = time.monotonic() + 18
        while True:
            queued = mailbox()
            if queued or time.monotonic() >= deadline_at:
                return {"handoffs": [json.loads(path.read_text()) for path in queued]}
            time.sleep(0.5)
    if action == "ack":
        token = ticket_id(payload.get("project"))
        (OUTBOX / f"{token}.json").unlink(missing_ok=True)
        (OUTBOX / f"{token}.bin").unlink(missing_ok=True)
        return {}
    if action == "save":
        return save_project(payload.get("name"), payload.get("path"))
    if action in {"clipboard-put", "clipboard-get"}:
        return clipboard(action, payload.get("text"))
    if action == "scrape":
        signal.alarm(20)
        try:
            return scrape(payload.get("url"))
        finally:
            signal.alarm(0)
    if action in {"open", "open-terminal", "build"}:
        project = next((entry for entry in projects() if entry["id"] == payload.get("project")), None)
        if not project:
            raise RequestError("This project is no longer saved on Linux.")
        directory = Path(project["path"]).resolve(strict=True)
        if not directory.is_dir():
            raise RequestError("The project folder is unavailable.")
        if action == "build":
            with project_build_lock(project["id"]).open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise RequestError("This project already has a build running.") from error
                return build_project(project, directory)
        if action == "open-terminal":
            open_terminal(directory)
        else:
            open_desktop(directory)
        return {"title": project["name"]}
    raise RequestError("Unknown Handoff Fox action.")


def deadline(_signum, _frame):
    raise RequestError("The Linux action took too long to respond.")


def end_clipboard_stream(_signum, _frame):
    raise EOFError


def main():
    signal.signal(signal.SIGALRM, deadline)
    os.umask(0o077)
    if len(sys.argv) == 5 and sys.argv[1] == "--run-job":
        run_job(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        return
    if len(sys.argv) == 6 and sys.argv[1] == "--watch-job":
        watch_job(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--clipboard-event":
        try:
            clipboard_event(Path(sys.argv[2]))
        except (OSError, ValueError, RequestError, subprocess.SubprocessError):
            pass
        return
    if sys.argv[1:] == ["--watch-clipboard"]:
        signal.signal(signal.SIGHUP, end_clipboard_stream)
        signal.signal(signal.SIGTERM, end_clipboard_stream)
        try:
            clipboard_stream()
        except (EOFError, OSError, ValueError, AttributeError, RequestError, subprocess.SubprocessError):
            pass
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--download":
        try:
            token = ticket_id(sys.argv[2])
            if not (OUTBOX / f"{token}.json").is_file():
                raise RequestError("This file is no longer queued.")
            with (OUTBOX / f"{token}.bin").open("rb") as source:
                shutil.copyfileobj(source, sys.stdout.buffer, 262_144)
        except (OSError, RequestError):
            raise SystemExit(1)
        return
    try:
        args = sys.argv[1:]
        if args in (["--upload"], ["--upload-ticket"]):
            result = upload_file(durable=args == ["--upload-ticket"])
        elif len(args) in {2, 3} and args[0] == "--queue":
            result = {"handoffs": [queue_for_mac(args[1], args[2] if len(args) == 3 else None)]}
        else:
            body = sys.stdin.buffer.read(MAX_REQUEST + 1)
            if len(body) > MAX_REQUEST:
                raise RequestError("The request is too large.")
            payload = json.loads(body)
            if not isinstance(payload, dict):
                raise RequestError("The request must be a JSON object.")
            result = request(payload)
        answer = {"version": VERSION, "ok": True} | result
    except RequestError as error:
        answer = {"version": VERSION, "ok": False, "error": str(error)}
    except (OSError, ValueError, KeyError, TypeError, LookupError, subprocess.SubprocessError,
            http.client.HTTPException):
        answer = {"version": VERSION, "ok": False,
                  "error": "Linux could not complete the request. Check the receiver, project, or website."}
    print(json.dumps(answer))


if __name__ == "__main__":
    main()
