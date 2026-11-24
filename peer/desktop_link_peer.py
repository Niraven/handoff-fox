#!/usr/bin/env python3
"""Handoff Fox's user-level SSH receiver. Accept one JSON request on stdin."""

import base64
from collections import deque
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


class RequestError(Exception):
    pass


def projects():
    if not CONFIG.exists():
        return []
    return json.loads(CONFIG.read_text())["projects"]


def display(project):
    return {key: project[key] for key in ("id", "name")} | {"canBuild": bool(project.get("build"))}


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


def open_desktop(target):
    # OpenSSH sessions normally have no display variables. Use the Linux user's
    # graphical service manager or the current graphical session, if available.
    if shutil.which("systemd-run"):
        session = subprocess.run(["systemctl", "--user", "is-active", "graphical-session.target"],
                                 capture_output=True, timeout=4, check=False)
        if session.returncode == 0:
            found = subprocess.run(
                ["systemd-run", "--user", "--quiet", "--collect", "--property=Type=exec",
                 "--property=ExitType=cgroup", "--", "xdg-open", str(target)],
                capture_output=True, timeout=4, check=False,
            )
            if found.returncode == 0:
                return
    if os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY"):
        subprocess.Popen(["xdg-open", str(target)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return
    raise RequestError("Open a graphical Linux session before using this action.")


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
    elif kind != "projects":
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
        target.write(buffer)
    if expected is not None and total != expected:
        raise RequestError("The transfer stopped before all bytes arrived.")
    return total, digest.hexdigest()


def upload_file():
    header = json.loads(sys.stdin.buffer.readline(8192))
    name = file_name(header["name"])
    token = ticket_id(header["id"])
    size = header["size"]
    volume = header["volume"]
    if type(size) is not int or not 0 <= size <= MAX_FILE:
        raise RequestError("Files can be up to 128 MiB.")
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
        os.link(temp.name, destination)
    return {"path": str(destination), "sha256": digest}


def clipboard_tools():
    env = os.environ.copy()
    if not (env.get("WAYLAND_DISPLAY") or env.get("DISPLAY")) and shutil.which("systemctl"):
        session = subprocess.run(["systemctl", "--user", "show-environment"],
                                 capture_output=True, text=True, timeout=4, check=False)
        for line in session.stdout.splitlines():
            name, _, value = line.partition("=")
            if name in {"WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR"}:
                env[name] = value
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
        return {"name": socket.gethostname(), "system": "Linux",
                "projects": [display(item) for item in projects()], "volumes": storage(),
                "desktopStatus": desktop_status()}
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
    if action in {"open", "build"}:
        project = next((entry for entry in projects() if entry["id"] == payload.get("project")), None)
        if not project:
            raise RequestError("This project is no longer saved on Linux.")
        directory = Path(project["path"]).resolve(strict=True)
        if not directory.is_dir():
            raise RequestError("The project folder is unavailable.")
        if action == "build":
            key = sha256(project["id"].encode()).hexdigest()
            with (CONFIG.parent / f"build-{key}.lock").open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise RequestError("This project already has a build running.") from error
                return build_project(project, directory)
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
        if args == ["--upload"]:
            result = upload_file()
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
