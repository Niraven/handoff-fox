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
    @Published private(set) var lastHost: String?
    private var app: NSRunningApplication?
    private var mode: DesktopMode?
    private var actualSize = false
    private var observer: NSObjectProtocol?
    private var beforeSleep: (host: String, mode: DesktopMode, actualSize: Bool)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastHost = defaults.string(forKey: "lastDesktopHost").flatMap { PeerClient.validAddress($0) ? $0 : nil }
    }

    func preferredMode(for host: String) -> DesktopMode {
        let stored = defaults.dictionary(forKey: "desktopModesByPeer")?[host] as? String
        return stored.flatMap(DesktopMode.init(rawValue:)) ?? .mirror
    }

    func prefersActualSize(for host: String) -> Bool {
        defaults.dictionary(forKey: "desktopActualSizeByPeer")?[host] as? Bool ?? false
    }

    func open(_ display: DesktopMode, host: String, replacing: Bool = false, actualSize: Bool = false) async {
        guard !opening else { return }
        if !replacing, activeHost == host, mode == display, self.actualSize == actualSize,
           let app, !app.isTerminated {
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
            let title = "Handoff Fox — \(display.rawValue)" + (actualSize ? " · Actual Size" : "")
            var arguments = ["--window-title", title, "--no-clipboard", "--no-audio"]
            if actualSize { arguments.append("--actual-size") }
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
            watchExit()
            guard !next.isTerminated else {
                throw PeerClient.Failure(reason: "The desktop viewer closed while starting. Try opening the desktop again.")
            }
            let last = app
            app = next
            mode = display
            self.actualSize = actualSize
            activeHost = host
            var modes = defaults.dictionary(forKey: "desktopModesByPeer") ?? [:]
            modes[host] = display.rawValue
            defaults.set(modes, forKey: "desktopModesByPeer")
            var sizes = defaults.dictionary(forKey: "desktopActualSizeByPeer") ?? [:]
            sizes[host] = actualSize
            defaults.set(sizes, forKey: "desktopActualSizeByPeer")
            defaults.set(host, forKey: "lastDesktopHost")
            lastHost = host
            last?.terminate()
        } catch {
            message = error.localizedDescription
        }
    }

    func disconnect() {
        beforeSleep = nil
        app?.terminate()
    }

    func reconnect() async {
        guard let mode, let activeHost else { return }
        await open(mode, host: activeHost, replacing: true, actualSize: actualSize)
    }

    func showOrOpen(host: String) async {
        let sameHost = activeHost == host
        await open(sameHost ? (mode ?? preferredMode(for: host)) : preferredMode(for: host),
                   host: host, actualSize: sameHost ? actualSize : prefersActualSize(for: host))
    }

    func prepareForSleep() {
        if let activeHost, let mode, app?.isTerminated == false {
            beforeSleep = (activeHost, mode, actualSize)
        } else {
            beforeSleep = nil
        }
    }

    func recoverAfterWake() async {
        let session = beforeSleep
        beforeSleep = nil
        // A surviving viewer owns the stream retry. Replace only a viewer that exited while asleep.
        guard let session, !opening, app?.isTerminated != false,
              activeHost == nil || activeHost == session.host else { return }
        await open(session.mode, host: session.host, actualSize: session.actualSize)
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
                self.actualSize = false
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
    @Environment(\.colorScheme) private var scheme

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    private var modeName: String {
        guard let address else { return "Mirror" }
        return desktop.preferredMode(for: address) == .mirror ? "Mirror" : "Private"
    }

    var body: some View {
        if let address {
            HStack(spacing: 2) {
                Button {
                    Task { await desktop.showOrOpen(host: address) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "display")
                        Text(desktop.opening ? "Connecting…" : "Open Desktop")
                        Text("· \(modeName)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.onAccent.opacity(0.7))
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(FoxPrimaryButtonStyle())
                Menu {
                    choices(for: address)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .background(palette.accent.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityLabel("Desktop options")
                .help("Choose a display mode or reconnect")
            }
            .disabled(desktop.opening)
        }
    }

    @ViewBuilder
    private func choices(for address: String) -> some View {
        Button("Mirror screen · Fit to Window") { Task { await desktop.open(.mirror, host: address) } }
        Button("Private screen · Fit to Window") { Task { await desktop.open(.privateScreen, host: address) } }
        Menu("Actual Size") {
            Button("Mirror screen") { Task { await desktop.open(.mirror, host: address, actualSize: true) } }
            Button("Private screen") { Task { await desktop.open(.privateScreen, host: address, actualSize: true) } }
        }
        if desktop.activeHost == address {
            Divider()
            Button("Reconnect") { Task { await desktop.reconnect() } }
            Button("Disconnect") { desktop.disconnect() }
        }
        Divider()
        Text("Shift + Esc releases the viewer keyboard")
    }
}
