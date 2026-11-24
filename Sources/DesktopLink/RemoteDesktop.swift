import AppKit
import Combine
import Foundation
import Security
import SwiftUI

enum DesktopMode: String {
    case mirror = "Mirror screen"
    case privateScreen = "Private screen"
}

@MainActor
final class RemoteDesktop: ObservableObject {
    @Published private(set) var activeHost: String?
    @Published private(set) var opening = false
    @Published private(set) var message: String?
    private var app: NSRunningApplication?
    private var mode: DesktopMode?
    private var observer: NSObjectProtocol?

    func open(_ display: DesktopMode, host: String, replacing: Bool = false) async {
        guard !opening else { return }
        if !replacing, activeHost == host, mode == display, let app, !app.isTerminated {
            app.activate(options: [])
            return
        }
        opening = true
        message = nil
        defer { opening = false }
        do {
            let (viewer, peer) = try await Task.detached(priority: .utility) {
                let viewer = try Self.verifiedViewer()
                let peer = try PeerClient.request(PeerRequest(action: "desktop"), on: host)
                return (viewer, peer)
            }.value
            guard let shim = Bundle.main.resourceURL?.appendingPathComponent("gliff-ssh"),
                  FileManager.default.isExecutableFile(atPath: shim.appendingPathComponent("ssh").path)
            else { throw PeerClient.Failure(reason: "The Handoff Fox viewer launcher is missing.") }

            let profile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Handoff Fox/Gliff", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            var arguments = ["--window-title", "Handoff Fox — \(display.rawValue)", "--no-clipboard", "--no-audio"]
            switch display {
            case .mirror:
                if let output = peer.desktopOutput { arguments += ["--output", output] }
            case .privateScreen:
                arguments.append("--headless")
            }
            config.arguments = arguments + [host]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = shim.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            environment["XDG_CONFIG_HOME"] = profile.appendingPathComponent("config").path
            environment["XDG_CACHE_HOME"] = profile.appendingPathComponent("cache").path
            environment["XDG_STATE_HOME"] = profile.appendingPathComponent("state").path
            config.environment = environment
            let next = try await NSWorkspace.shared.openApplication(at: viewer, configuration: config)
            let last = app
            app = next
            mode = display
            activeHost = host
            watchExit()
            last?.terminate()
        } catch {
            message = error.localizedDescription
        }
    }

    func disconnect() {
        app?.terminate()
    }

    func reconnect() async {
        guard let mode, let activeHost else { return }
        await open(mode, host: activeHost, replacing: true)
    }

    func showOrOpen(host: String) async {
        await open(activeHost == host ? (mode ?? .mirror) : .mirror, host: host)
    }

    private func watchExit() {
        let center = NSWorkspace.shared.notificationCenter
        if let observer { center.removeObserver(observer) }
        observer = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                      object: nil, queue: .main) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, pid == self.app?.processIdentifier else { return }
                self.app = nil
                self.activeHost = nil
                self.mode = nil
            }
        }
    }

    nonisolated private static func verifiedViewer() throws -> URL {
        let app = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/Handoff Fox Desktop.app", isDirectory: true)
        guard Bundle(url: app)?.bundleIdentifier == "local.desktoplink.viewer" else {
            throw PeerClient.Failure(reason: "The desktop viewer is missing. Reinstall Handoff Fox to restore it.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let policy = #"identifier "local.desktoplink.viewer""#
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(policy as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw PeerClient.Failure(reason: "The bundled desktop viewer failed its integrity check. Reinstall Handoff Fox.")
        }
        return app
    }
}

struct OpenDesktopMenu: View {
    @ObservedObject var desktop: RemoteDesktop
    let address: String?
    var accent: Color? = nil

    var body: some View {
        Group {
            if let address, let accent {
                HStack(spacing: 2) {
                    Button {
                        Task { await desktop.showOrOpen(host: address) }
                    } label: {
                        Label(desktop.opening ? "Connecting…" : "Open Desktop", systemImage: "display")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .contentShape(Rectangle())
                            .foregroundStyle(Color(red: 0.11, green: 0.08, blue: 0.16))
                            .background(accent)
                    }
                    .buttonStyle(.plain)
                    Menu { choices } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Desktop options")
                    .help("Choose a display mode or reconnect")
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.18))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Menu { choices } label: {
                    Label(desktop.opening ? "Connecting…" : "Open Desktop", systemImage: "display")
                }
            }
        }
        .help("Release the viewer keyboard with Shift + Escape")
        .disabled(address == nil || desktop.opening)
    }

    @ViewBuilder private var choices: some View {
        if let address {
            Button("Mirror screen") { Task { await desktop.open(.mirror, host: address) } }
            Button("Private screen") { Task { await desktop.open(.privateScreen, host: address) } }
            if desktop.activeHost == address {
                Divider()
                Button("Reconnect") { Task { await desktop.reconnect() } }
                Button("Disconnect") { desktop.disconnect() }
            }
        }
    }
}
