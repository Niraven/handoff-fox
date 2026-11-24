#!/usr/bin/env python3
"""Controls for the user's paired Mac input on the Omarchy desktop."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess

UNIT = os.environ.get("HANDOFF_FOX_INPUT_UNIT", "citadel-waynergy.service")


def command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=5, check=False)


def read_status():
    result = command("systemctl", "--user", "show", "-p", "ActiveState", "-p", "MainPID", "--", UNIT)
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    active = fields.get("ActiveState") == "active"
    pid = fields.get("MainPID", "")
    connected = False
    if active and pid.isdecimal() and int(pid) > 0:
        sockets = command("ss", "-Htnp", "state", "established", "dport = :24800")
        connected = sockets.returncode == 0 and any(
            "127.0.0.1:24800" in line and re.search(rf'\("waynergy",pid={pid},', line)
            for line in sockets.stdout.splitlines()
        )
    return {"active": active, "connected": connected}


def just_connected(previous, current):
    return previous is False and current is True


def read_json(*args):
    try:
        result = command(*args)
        return json.loads(result.stdout) if result.returncode == 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def read_activity():
    health = command("curl", "-fsS", "--max-time", "3", "-o", "/dev/null", "http://127.0.0.1:8001/health")
    hermes = command("systemctl", "--user", "is-active", "hermes-gateway.service")
    herdr = read_json("herdr", "agent", "list")
    factory = read_json(str(Path.home() / ".local/bin/citadel-factory"), "stats", "--json")
    agents = herdr.get("result", herdr).get("agents") if isinstance(herdr, dict) else None
    statuses = factory.get("by_status") if isinstance(factory, dict) else None
    return {
        "scraperReady": health.returncode == 0,
        "hermesActive": hermes.returncode == 0,
        "herdrAgents": len(agents) if isinstance(agents, list) else None,
        "reviews": int(statuses.get("review", 0)) if isinstance(statuses, dict) else None,
        "workspaceFreeGiB": shutil.disk_usage("/workspace").free // 2**30
        if os.path.ismount("/workspace") else None,
    }


def control(verb):
    result = command("systemctl", "--user", verb, "--", UNIT)
    if result.returncode:
        return f"Could not {verb} the Waynergy service."
    return None


SHORTCUTS = ("hermes", "herdr", "workspace")


def open_shortcut(target):
    if target == "workspace":
        args = ("xdg-open", "/workspace")
    elif target == "hermes":
        args = ("gtk-launch", "com.nousresearch.hermes")
    elif target == "herdr":
        herdr = shutil.which("herdr")
        if not herdr:
            raise OSError("Herdr is not installed")
        if shutil.which("omarchy-launch-terminal") and shutil.which("foot"):
            args = ("foot", "--app-id=local.desktoplink.herdr", "--title=Herdr", herdr)
        else:
            args = ("xdg-terminal-exec", herdr)
    else:
        raise ValueError("Unknown Desktop Link shortcut")
    if shutil.which("systemd-run"):
        result = command("systemd-run", "--user", "--quiet", "--collect", "--property=Type=exec",
                         "--property=ExitType=cgroup", "--", *args)
        if result.returncode == 0:
            return
        if not (os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")):
            raise OSError("The graphical session is unavailable")
    subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


TRAY_ITEM = """
<node><interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    <signal name="NewIcon"/><signal name="NewToolTip"/>
</interface></node>
"""


def attention_summary(info):
    if not info:
        return ""
    reasons = []
    if info["reviews"]:
        reasons.append(f'{info["reviews"]} in review')
    free = info["workspaceFreeGiB"]
    if free is not None and free < 15:
        reasons.append("Workspace low")
    return " · ".join(reasons)


def peer_call(*args, payload=None):
    peer = str(Path.home() / ".local/bin/desktop-link-peer")
    completed = subprocess.run((peer, *args), input=json.dumps(payload) if payload else "",
                               capture_output=True, text=True, timeout=20, check=False)
    answer = json.loads(completed.stdout)
    if not answer.get("ok"):
        raise ValueError(answer.get("error") or "Handoff could not be completed.")
    return answer


def open_panel(start_hidden, show_handoff=False):
    os.environ.setdefault("GSK_RENDERER", "cairo")
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk

    app = Gtk.Application(application_id="local.desktoplink.control")

    def activate(application):
        if application.get_windows():
            window = next(window for window in application.get_windows() if window.get_title() == "Handoff Fox")
            if window.get_visible():
                window.hide()
            else:
                window.present()
            return

        application.hold()
        executor = ThreadPoolExecutor(max_workers=2)
        state = {"status": None, "busy": False, "loading": False, "attention": "", "title": "Checking link"}
        window = Gtk.ApplicationWindow(application=application, title="Handoff Fox", hide_on_close=True)
        window.set_resizable(False)
        window.add_css_class("desktop-link")
        style = Gtk.CssProvider()
        style.load_from_string("""
            window.desktop-link {
                background-color: #171021;
                background-image: linear-gradient(140deg, #302044, #171021);
                color: #f7efff;
            }
            window.desktop-link headerbar {
                min-height: 0; padding: 8px 12px; background: transparent;
                box-shadow: none; border: 0; color: #f7efff;
            }
            window.desktop-link button { min-height: 25px; padding: 3px 9px; border-radius: 9px; }
            window.desktop-link label { font-size: 13px; }
            window.desktop-link .fox-heading { font-weight: 700; font-size: 16px; }
            window.desktop-link .fox-status { font-size: 11px; color: #d5c6e8; }
            window.desktop-link .fox-status.connected { color: #b7ebd3; }
            window.desktop-link .fox-emblem {
                min-width: 36px; min-height: 36px; background-color: rgba(212,185,252,.15);
                border: 1px solid rgba(212,185,252,.22); border-radius: 12px;
            }
            window.desktop-link .fox-primary {
                min-height: 35px; padding: 4px 12px; font-weight: 700;
                background-image: linear-gradient(125deg, #dbc0ff, #c6a6f7);
                color: #20142e; border: 1px solid #dec5ff;
            }
            window.desktop-link .fox-primary:hover {
                background-image: linear-gradient(125deg, #e5d0ff, #d5baff);
            }
            window.desktop-link .fox-details {
                padding: 9px; background-color: rgba(212,185,252,.075);
                border: 1px solid rgba(212,185,252,.12); border-radius: 12px;
            }
            window.desktop-link .fox-details .warning { color: #ffc29b; }
            window.desktop-link .fox-key { font-family: monospace; color: #d9bfff; font-size: 11px; }
        """)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), style, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        header = Gtk.HeaderBar()
        header.set_decoration_layout(":close")
        emblem = Gtk.Image.new_from_icon_name("local.desktoplink.control")
        emblem.set_pixel_size(23)
        emblem.add_css_class("fox-emblem")
        header.pack_start(emblem)
        title = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        destination = Gtk.Label(label="Mac")
        destination.add_css_class("fox-heading")
        title.append(destination)
        status = Gtk.Label(label="Checking link")
        status.add_css_class("fox-status")
        title.append(status)
        header.set_title_widget(title)
        action = Gtk.Button(icon_name="media-playback-pause-symbolic", tooltip_text="Pause input", sensitive=False)
        header.pack_end(action)
        window.set_titlebar(header)

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=11, width_request=248)
        for edge in ("top", "bottom", "start", "end"):
            getattr(card, f"set_margin_{edge}")(13)
        handoff_button = Gtk.Button(label="Send to Mac…")
        handoff_button.add_css_class("fox-primary")
        handoff_button.set_tooltip_text("Handoff · Ctrl + Alt + J")
        handoff_button.connect("clicked", lambda _: present_handoff())
        card.append(handoff_button)
        details = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        details.add_css_class("fox-details")
        card.append(details)
        agents = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        values = []
        for name, target in zip(("Hermes", "Herdr", "Workspace"), SHORTCUTS):
            row = Gtk.Box(spacing=6)
            row.append(Gtk.Label(label=name, xalign=0, hexpand=True))
            value = Gtk.Label(label="…", xalign=1)
            row.append(value)
            row.append(Gtk.Image.new_from_icon_name("go-next-symbolic"))
            button = Gtk.Button(child=row, has_frame=False, tooltip_text=f"Open {name} on this desktop")
            button.connect("clicked", lambda _, target=target: launch(target))
            (details if target == "workspace" else agents).append(button)
            values.append(value)
        tools = Gtk.Expander(label="Agent tools", child=agents)
        details.append(tools)
        notice = Gtk.Label(xalign=0, visible=False, wrap=True, max_width_chars=30)
        notice.add_css_class("warning")
        details.append(notice)
        hint = Gtk.Box(spacing=8)
        hint.append(Gtk.Label(label="Return to Mac", xalign=0, hexpand=True))
        key = Gtk.Label(label="Ctrl+Option+Esc")
        key.add_css_class("fox-key")
        hint.append(key)
        details.append(hint)
        window.set_child(card)

        palette = None

        def present_handoff():
            nonlocal palette
            if palette is not None:
                palette.present()
                return
            palette = Gtk.ApplicationWindow(application=application, title="Handoff",
                                            default_width=400, hide_on_close=True)
            palette.set_resizable(False)
            panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9)
            for side in ("top", "bottom", "start", "end"):
                getattr(panel, f"set_margin_{side}")(14)
            palette.set_child(panel)
            feedback = Gtk.Label(xalign=0, wrap=True)

            def run_action(fn, success, result=None):
                def work():
                    try:
                        answer = fn()
                        if result:
                            GLib.idle_add(result, answer)
                        elif success:
                            GLib.idle_add(feedback.set_label, success)
                    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                        GLib.idle_add(feedback.set_label, str(error))
                executor.submit(work)

            def choose_file(_button):
                picker = Gtk.FileChooserNative.new("Send file to Mac", palette, Gtk.FileChooserAction.OPEN,
                                                   "Send", "Cancel")
                palette.file_picker = picker

                def selected(dialog, answer):
                    if answer == Gtk.ResponseType.ACCEPT:
                        chosen = dialog.get_file()
                        path = chosen.get_path() if chosen else None
                        if path:
                            run_action(lambda: peer_call("--queue", "file", path), "File queued for your Mac.")
                    dialog.destroy()
                    palette.file_picker = None

                picker.connect("response", selected)
                picker.show()

            send = Gtk.Button(label="Send file to Mac…")
            send.connect("clicked", choose_file)
            panel.append(send)
            link_row = Gtk.Box(spacing=5)
            link = Gtk.Entry(placeholder_text="https://…", hexpand=True)
            link_row.append(link)
            send_link = Gtk.Button(label="Open link on Mac")

            def forward_link(_button):
                address = link.get_text().strip()
                run_action(lambda: peer_call("--queue", "link", address), "Link queued for your Mac.")

            send_link.connect("clicked", forward_link)
            link.connect("activate", forward_link)
            link_row.append(send_link)
            panel.append(link_row)

            projects_on_mac = Gtk.Button(label="Show projects on Mac")
            projects_on_mac.connect("clicked", lambda _: run_action(
                lambda: peer_call("--queue", "projects"), "Projects queued for your Mac."
            ))
            panel.append(projects_on_mac)
            saved = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            panel.append(saved)
            panel.append(feedback)

            def show_projects(info):
                for project in info.get("projects", []):
                    jump = Gtk.Button(label=project["name"])
                    jump.connect("clicked", lambda _button, key=project["id"]: run_action(
                        lambda: peer_call(payload={"version": 1, "action": "open", "project": key}),
                        "Opened on Linux."
                    ))
                    saved.append(jump)

            run_action(lambda: peer_call(payload={"version": 1, "action": "pair"}), None, show_projects)
            palette.present()

        handoff = Gio.SimpleAction.new("handoff", None)
        handoff.connect("activate", lambda *_: present_handoff())
        application.add_action(handoff)

        def launch(target):
            try:
                open_shortcut(target)
            except (OSError, subprocess.SubprocessError):
                notice.set_label(f"Could not open {target}.")
                notice.set_visible(True)

        def toggle():
            if window.get_visible():
                window.hide()
            else:
                window.present()

        def key_pressed(_controller, key, _keycode, _modifiers):
            if key != Gdk.KEY_Escape:
                return False
            window.hide()
            return True

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", key_pressed)
        window.add_controller(keys)

        data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        art = GdkPixbuf.Pixbuf.new_from_file(str(data_home / "desktop-link/TrayFox.png"))
        source = art.get_pixels()
        size = art.get_width()

        def pixmap(lift=0):
            pixels = bytearray(size * size * 4)
            for y in range(lift, size):
                for x in range(size):
                    offset = y * art.get_rowstride() + x * 4
                    r, g, b, a = source[offset:offset + 4]
                    dest = ((y - lift) * size + x) * 4
                    pixels[dest:dest + 4] = bytes((a, r, g, b))
            if state["attention"]:
                for x, y in ((19, 2), (20, 1), (20, 2), (20, 3), (21, 2)):
                    offset = (y * size + x) * 4
                    pixels[offset:offset + 4] = bytes((255, 255, 224, 127))
            return [(size, size, bytes(pixels))]

        item = "org.kde.StatusNotifierItem"
        path = "/StatusNotifierItem"
        watcher = "org.kde.StatusNotifierWatcher"
        bus = application.get_dbus_connection()
        icon = pixmap()

        def tray_property(_connection, _sender, _path, _interface, prop):
            properties = {
                "Category": ("s", "ApplicationStatus"), "Id": ("s", "desktop-link"),
                "Title": ("s", "Handoff Fox"), "Status": ("s", "Active"),
                "IconName": ("s", ""), "IconPixmap": ("a(iiay)", icon), "ItemIsMenu": ("b", False),
                "ToolTip": ("(sa(iiay)ss)", ("", [], "Handoff Fox",
                            " · ".join(filter(None, (state["title"], state["attention"]))))),
            }
            return GLib.Variant(*properties[prop])

        def tray_action(_connection, _sender, _path, _interface, _method, _args, invocation):
            toggle()
            invocation.return_value(None)

        def notify_tray(signal):
            if bus:
                bus.emit_signal(None, path, item, signal, None)

        def redraw(lift=0):
            nonlocal icon
            icon = pixmap(lift)
            notify_tray("NewIcon")
            return False

        if bus:
            interface = Gio.DBusNodeInfo.new_for_xml(TRAY_ITEM).interfaces[0]
            bus.register_object(path, interface, tray_action, tray_property, None)

            def register(connection, _name, _owner):
                connection.call(watcher, "/StatusNotifierWatcher", watcher, "RegisterStatusNotifierItem",
                                GLib.Variant("(s)", (path,)), None, Gio.DBusCallFlags.NONE, 3000,
                                None, None, None)

            Gio.bus_watch_name_on_connection(bus, watcher, Gio.BusNameWatcherFlags.NONE, register, None)

        def show_status(value, error, change):
            previous = state["status"]
            state.update(status=value or previous, busy=False)
            if value:
                connected = value["connected"]
                title = "Connected" if connected else "Waiting for Mac" if value["active"] else "Input paused"
                if title != state["title"]:
                    state["title"] = title
                    status.set_label(title)
                    notify_tray("NewToolTip")
                if connected:
                    status.add_css_class("connected")
                else:
                    status.remove_css_class("connected")
                if (just_connected(previous["connected"] if previous else None, connected)
                        and Gtk.Settings.get_default().get_property("gtk-enable-animations")):
                    redraw(2)
                    GLib.timeout_add(170, redraw)
                action.set_icon_name("media-playback-pause-symbolic" if value["active"] else "media-playback-start-symbolic")
                action.set_tooltip_text("Pause input" if value["active"] else "Resume input")
            elif not previous:
                status.set_label("Link unavailable")
            if error or change:
                notice.set_label(error or state["attention"])
                notice.set_visible(bool(error or state["attention"]))
            action.set_sensitive(state["status"] is not None)
            return False

        def update(verb=None):
            if state["busy"]:
                return
            state["busy"] = True
            if verb:
                action.set_sensitive(False)

            def task():
                try:
                    error = control(verb) if verb else None
                    value = read_status()
                except (OSError, subprocess.SubprocessError):
                    value, error = None, "Could not read the input service."
                GLib.idle_add(show_status, value, error, verb is not None)

            executor.submit(task)

        def show_activity(info):
            state["loading"] = False
            if not info:
                for label in values:
                    label.set_label("Unavailable")
            else:
                agents, free = info["herdrAgents"], info["workspaceFreeGiB"]
                values[0].set_label("Running" if info["hermesActive"] else "Stopped")
                values[1].set_label(f"{agents} tracked" if agents is not None else "Unavailable")
                values[2].set_label(f"{free} GiB free" if free is not None else "Unavailable")
            attention = attention_summary(info)
            if attention != state["attention"]:
                state["attention"] = attention
                redraw()
                notify_tray("NewToolTip")
            notice.set_label(attention)
            notice.set_visible(bool(attention))
            return False

        def load_activity(*_):
            if state["loading"]:
                return True
            state["loading"] = True

            def task():
                try:
                    info = read_activity()
                except (OSError, ValueError, subprocess.SubprocessError):
                    info = None
                GLib.idle_add(show_activity, info)

            executor.submit(task)
            return True

        def tick():
            update()
            return True

        action.connect("clicked", lambda _: state["status"] and update("stop" if state["status"]["active"] else "start"))
        window.connect("map", load_activity)
        GLib.timeout_add_seconds(4, tick)
        GLib.timeout_add_seconds(120, load_activity)
        update()
        load_activity()
        if show_handoff:
            present_handoff()
        elif not start_hidden:
            window.present()

    app.connect("activate", activate)
    return app.run([])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--status", action="store_true", help="read the local link status as JSON")
    group.add_argument("--activity", action="store_true", help="read tool and agent health as JSON")
    group.add_argument("--tray", action="store_true", help="start with the card closed")
    group.add_argument("--open", choices=SHORTCUTS, help="open an installed desktop shortcut")
    group.add_argument("--handoff", action="store_true", help="open the handoff palette")
    args = parser.parse_args()
    if args.handoff:
        action = command("gdbus", "call", "--session", "--dest", "local.desktoplink.control",
                         "--object-path", "/local/desktoplink/control", "--method",
                         "org.gtk.Actions.Activate", "handoff", "[]", "{}")
        if action.returncode == 0:
            return 0
        return open_panel(True, show_handoff=True)
    if args.activity:
        print(json.dumps(read_activity()))
        return 0
    if args.status:
        print(json.dumps(read_status()))
        return 0
    if args.open:
        open_shortcut(args.open)
        return 0
    return open_panel(args.tray)


if __name__ == "__main__":
    raise SystemExit(main())
