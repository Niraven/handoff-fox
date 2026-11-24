import AppKit
import SwiftUI

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published private(set) var peers: [LinuxPeer]
    @Published private(set) var selected: String?
    @Published private(set) var projects: [LinuxProject] = []
    @Published private(set) var volumes: [LinuxVolume] = []
    @Published private(set) var running: String?
    @Published private(set) var notice: String?
    @Published private(set) var error: String?
    @Published private(set) var result: PeerReply?
    @Published private(set) var clipboardBusy = false
    @Published private(set) var clipboardFeedback: String?
    @Published private(set) var pairingError: String?
    @Published private(set) var needsHostVerification = false
    @Published private(set) var desktopAvailability: DesktopAvailability?

    var selectedName: String { peers.first(where: { $0.address == selected })?.name ?? "Linux" }

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "linuxPeers")
            .flatMap { try? JSONDecoder().decode([LinuxPeer].self, from: $0) }
        peers = saved ?? []
        if saved == nil, let address = defaults.string(forKey: "initialLinuxPeer"),
           PeerClient.validAddress(address) {
            peers = [LinuxPeer(address: address, name: "Citadel")]
        }
        selected = defaults.string(forKey: "selectedLinuxPeer").flatMap { address in
            peers.contains { $0.address == address } ? address : nil
        } ?? peers.first?.address
    }

    func select(_ address: String) async {
        guard running == nil else { return }
        if selected != address {
            projects = []
            volumes = []
            result = nil
            desktopAvailability = nil
        }
        selected = address
        UserDefaults.standard.set(address, forKey: "selectedLinuxPeer")
        await send(PeerRequest(action: "pair"), label: "Contacting Linux")
    }

    func pair(_ address: String) async {
        guard running == nil, PeerClient.validAddress(address) else { return }
        running = "Pairing Linux"
        clearPairingError()
        notice = nil
        error = nil
        defer { running = nil }
        let receiver = Bundle.main.url(forResource: "desktop-link-peer", withExtension: nil)
        let info: PeerReply
        do {
            info = try await Task.detached(priority: .userInitiated) {
                try PeerClient.pair(address, receiver: receiver)
            }.value
            guard info.system == "Linux" else {
                pairingError = "This device didn’t identify itself as Linux."
                return
            }
        } catch {
            pairingError = error.localizedDescription
            needsHostVerification = (error as? PeerClient.Failure)?.kind == .untrustedHost
            return
        }
        let peer = LinuxPeer(address: address, name: info.name ?? address)
        peers.removeAll { $0.id == peer.id }
        peers.append(peer)
        selected = peer.address
        projects = info.projects ?? []
        volumes = info.volumes ?? []
        desktopAvailability = info.desktopAvailability
        result = nil
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: "linuxPeers")
        }
        UserDefaults.standard.set(address, forKey: "selectedLinuxPeer")
        notice = "Paired with \(peer.name)."
    }

    func clearPairingError() {
        pairingError = nil
        needsHostVerification = false
    }

    func transferClipboard(_ direction: ClipboardDirection) async {
        guard !clipboardBusy, let address = selected else { return }
        let name = selectedName
        clipboardBusy = true
        clipboardFeedback = nil
        defer { clipboardBusy = false }
        do {
            try await ClipboardTransfer.perform(direction, host: address)
            clipboardFeedback = direction == .sendToLinux ? "Copied to \(name)." : "Copied from \(name)."
        } catch {
            clipboardFeedback = error.localizedDescription
        }
    }

    func openLink(_ text: String) async {
        if await send(PeerRequest(action: "open-link", url: text), label: "Opening link") != nil {
            notice = "Opened on \(selectedName)."
        }
    }

    func sendFile(_ file: URL, volume: String) async {
        guard running == nil, let target = selected else { return }
        running = "Sending file"
        error = nil
        notice = nil
        defer { running = nil }
        do {
            let path = try await Task.detached(priority: .userInitiated) {
                try FileHandoff.send(file, on: target, volume: volume)
            }.value
            notice = "Saved on \(selectedName): \(path)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(name: String, path: String) async {
        await send(PeerRequest(action: "save", name: name, path: path), label: "Saving project")
    }

    func open(_ project: LinuxProject) async {
        if await send(PeerRequest(action: "open", project: project.id), label: "Opening folder") != nil {
            notice = "Opened \(project.name) on Linux."
        }
    }

    func build(_ project: LinuxProject) async {
        await send(PeerRequest(action: "build", project: project.id), label: "Building \(project.name)")
    }

    func scrape(_ url: String) async {
        await send(PeerRequest(action: "scrape", url: url), label: "Scraping on Linux")
    }

    @discardableResult
    private func send(_ request: PeerRequest, label: String) async -> PeerReply? {
        guard running == nil, let target = selected else { return nil }
        running = label
        error = nil
        notice = nil
        if request.action == "build" || request.action == "scrape" { result = nil }
        defer { running = nil }
        do {
            let reply = try await Task.detached(priority: .userInitiated) {
                try PeerClient.request(request, on: target)
            }.value
            if let updated = reply.projects { projects = updated }
            if let disks = reply.volumes { volumes = disks }
            if request.action == "pair" { desktopAvailability = reply.desktopAvailability }
            if reply.output != nil { result = reply }
            if request.action == "save" { notice = "Project saved on Linux." }
            return reply
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

struct ClipboardMenu: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var sync: ClipboardSync

    var body: some View {
        Menu {
            if sync.address != nil {
                let name = model.peers.first(where: { $0.address == sync.address })?.name ?? "input device"
                Toggle("Automatic with \(name)", isOn: Binding(
                    get: { sync.enabled },
                    set: { enabled in
                        UserDefaults.standard.set(enabled, forKey: "automaticClipboard")
                        sync.setEnabled(enabled)
                    }
                ))
                if sync.enabled {
                    Text(sync.ready ? "Automatic sharing connected" : "Waiting for a connection")
                }
                Divider()
            }
            Button("Send to \(model.selectedName)") {
                Task { await model.transferClipboard(.sendToLinux) }
            }
            Button("Copy from \(model.selectedName)") {
                Task { await model.transferClipboard(.copyFromLinux) }
            }
        } label: {
            Text(model.clipboardBusy ? "Copying…" : "Clipboard")
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("Transfer plain text with the selected Linux device")
        .disabled(model.selected == nil || model.clipboardBusy)
    }
}

struct Workbench: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var clipboardSync: ClipboardSync
    @ObservedObject var inbox: HandoffInbox
    @ObservedObject var desktop: RemoteDesktop
    @State private var address = ""
    @State private var projectName = ""
    @State private var projectPath = ""
    @State private var url = ""
    @State private var showPair = false
    @State private var showSave = false
    @State private var showResearch = false
    @State private var link = ""
    @State private var volume = "home"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showPair || model.peers.isEmpty { pairForm }
                    if let running = model.running {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(running)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let error = desktop.message {
                        Label(error, systemImage: "display.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    if let clipboard = model.clipboardFeedback {
                        Label(clipboard, systemImage: "clipboard").foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    if let receipt = inbox.lastReceived {
                        Label(receipt, systemImage: "arrow.down.left").foregroundStyle(.secondary)
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    if model.selected != nil {
                        desktopCard
                        handoff
                        projects
                        DisclosureGroup("Research tools", isExpanded: $showResearch) {
                            scrape.padding(.top, 8)
                        }
                    }
                    if let result = model.result { output(result) }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 530, minHeight: 410)
        .task {
            if let selected = model.selected { await model.select(selected) }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text(model.selected == nil ? "Set up Handoff Fox" : "Handoff").font(.headline)
            Spacer()
            if !model.peers.isEmpty {
                ClipboardMenu(model: model, sync: clipboardSync).fixedSize()
                Picker("Device", selection: Binding(
                    get: { model.selected ?? "" },
                    set: { address in Task { await model.select(address) } }
                )) {
                    ForEach(model.peers) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
            if !model.peers.isEmpty {
                Button {
                    showPair.toggle()
                } label: {
                    Image(systemName: showPair ? "minus" : "plus").frame(width: 18)
                }
                .help(showPair ? "Close pairing" : "Pair another Linux computer")
                .accessibilityLabel(showPair ? "Close pairing" : "Pair another Linux computer")
            }
        }
        .padding(14)
        .disabled(model.running != nil)
    }

    private var pairForm: some View {
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 7) {
            Text("Pair a Linux computer").font(.subheadline.weight(.semibold))
            HStack {
                TextField("SSH alias or user@hostname", text: $address)
                    .accessibilityLabel("SSH address")
                    .onSubmit { pair(target) }
                    .onChange(of: address) { _, _ in model.clearPairingError() }
                Button("Pair") { pair(target) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!PeerClient.validAddress(target))
            }
            Text("Use a Linux account you can reach with an SSH key. Pair adds the receiver to that account if it’s missing.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.pairingError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if model.needsHostVerification, PeerClient.validAddress(target) {
                Text("In Terminal, compare the fingerprint SSH shows with the host key on Linux before approving it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Copy verification command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        "ssh -o StrictHostKeyChecking=ask -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -- '\(target)' true",
                        forType: .string
                    )
                }
            }
        }
        .disabled(model.running != nil)
    }

    private func pair(_ target: String) {
        guard PeerClient.validAddress(target) else { return }
        Task {
            await model.pair(target)
            if model.pairingError == nil, model.selected == target { showPair = false; address = "" }
        }
    }

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Send to \(model.selectedName)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if !model.volumes.isEmpty {
                    Picker("Save to", selection: $volume) {
                        ForEach(model.volumes) { disk in Text(disk.name).tag(disk.id) }
                    }
                    .fixedSize()
                }
                Button("Send file…") { pickFile() }
            }
            HStack {
                TextField("https://…", text: $link).accessibilityLabel("Link to open on Linux")
                Button("Open link on Linux") {
                    let address = link.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await model.openLink(address)
                        if model.error == nil { link = "" }
                    }
                }
                .disabled(FileHandoff.browserURL(link.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
            }
            ForEach(model.volumes) { disk in
                HStack {
                    Label(disk.name, systemImage: "internaldrive")
                    Spacer()
                    Text(disk.capacity).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.running != nil)
        .onChange(of: model.selected) { _, _ in volume = "home" }
    }

    private var desktopCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color(red: 0.67, green: 0.50, blue: 0.94))
                .frame(width: 40, height: 40)
                .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Remote desktop").font(.subheadline.weight(.semibold))
                desktopSetup
            }
            Spacer(minLength: 8)
            OpenDesktopMenu(desktop: desktop, address: model.selected)
                .fixedSize()
        }
        .padding(15)
        .background(.purple.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.purple.opacity(0.18)))
    }

    @ViewBuilder private var desktopSetup: some View {
        switch model.desktopAvailability {
        case .ready:
            Label("Desktop ready", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .needsGliff:
            HStack {
                Label("Desktop sharing needs Gliff on Linux.", systemImage: "display")
                Link("Gliff setup", destination: URL(string: "https://github.com/omacom/gliff")!)
            }
            .font(.caption).foregroundStyle(.secondary)
        case .needsHyprland:
            Label("Sign in to Hyprland on Linux to share its desktop.", systemImage: "display")
                .font(.caption).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let destination = volume
        panel.begin { answer in
            guard answer == .OK, let file = panel.url else { return }
            Task { await model.sendFile(file, volume: destination) }
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Saved projects").font(.subheadline.weight(.semibold))
                Spacer()
                Button(showSave ? "Cancel" : "Save folder…") { showSave.toggle() }
            }
            if showSave {
                HStack {
                    TextField("Project name", text: $projectName).accessibilityLabel("Project name")
                    TextField("/path/on/linux", text: $projectPath).accessibilityLabel("Linux folder path")
                    Button("Save") {
                        Task {
                            await model.save(name: projectName, path: projectPath)
                            if model.error == nil { showSave = false; projectName = ""; projectPath = "" }
                        }
                    }
                    .disabled(projectName.isEmpty || projectPath.isEmpty)
                }
            }
            if model.projects.isEmpty {
                Text("Save a folder to open it on this Linux desktop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.projects) { project in
                HStack {
                    Label(project.name, systemImage: "folder")
                        .lineLimit(1)
                    Spacer()
                    Button("Open on Linux") { Task { await model.open(project) } }
                    Button("Build") { Task { await model.build(project) } }
                        .disabled(!project.canBuild)
                        .help(project.canBuild ? "Run its preset on Linux" : "Add a build preset on Linux")
                }
                .padding(7)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .disabled(model.running != nil)
    }

    private var scrape: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Scrape on Linux").font(.subheadline.weight(.semibold))
            HStack {
                TextField("https://example.com/", text: $url).accessibilityLabel("Public HTTPS page")
                Button("Run scrape") { Task { await model.scrape(url.trimmingCharacters(in: .whitespaces)) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme != "https")
            }
        }
        .disabled(model.running != nil)
    }

    private func output(_ reply: PeerReply) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(reply.title ?? "Result").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button("Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reply.output ?? "", forType: .string)
                }
                Button("Save result…") { saveFile(Data((reply.output ?? "").utf8), name: "linux-result.txt") }
            }
            let elapsed = (reply.elapsedMs ?? 0).formatted()
            Text((reply.exitCode == 0 ? "Completed" : "Exit \(reply.exitCode ?? 1)") + " · \(elapsed) ms" +
                 (reply.truncated == true ? " · Output clipped" : ""))
                .font(.caption).foregroundStyle(reply.exitCode == 0 ? Color.secondary : .orange)
            if let artifact = reply.artifact {
                Button {
                    saveFile(artifact.data, name: URL(fileURLWithPath: artifact.name).lastPathComponent)
                } label: {
                    Label("Save \(artifact.name)…", systemImage: "arrow.down.to.line")
                }
            }
            if let error = reply.artifactError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                let text = reply.output ?? ""
                Text(text.isEmpty ? "No text output." : text)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
            }
            .frame(maxHeight: 175)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func saveFile(_ data: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.begin { result in
            guard result == .OK, let file = panel.url else { return }
            do { try data.write(to: file, options: .atomic) }
            catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}
