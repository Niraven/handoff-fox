import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Published private(set) var receivingPeer: String?
    @Published private(set) var connectionCheck: ConnectionCheck?
    @Published private(set) var checkingConnection = false
    @Published private(set) var lastProjects: [String: LinuxProject]
    @Published private(set) var jobs: [LinuxJob] = []
    @Published private(set) var jobDetail: PeerReply?
    @Published private(set) var supportsJobs = false
    private var transferProtocols: [String: Bool]
    private var loadedPeer: String?
    private var checkingJobs = false
    private var jobRevision = 0

    let inbox: HandoffInbox

    var selectedName: String { peers.first(where: { $0.address == selected })?.name ?? "Linux" }

    init(inbox: HandoffInbox) {
        self.inbox = inbox
        let defaults = UserDefaults.standard
        transferProtocols = defaults.dictionary(forKey: "durableTransferPeers") as? [String: Bool] ?? [:]
        lastProjects = defaults.data(forKey: "lastLinuxProjects").flatMap {
            try? JSONDecoder().decode([String: LinuxProject].self, from: $0)
        } ?? [:]
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
        let incoming = defaults.string(forKey: "receivingLinuxPeer") ?? defaults.string(forKey: "initialLinuxPeer")
        receivingPeer = incoming.flatMap { PeerClient.validAddress($0) ? $0 : nil }
    }

    func select(_ address: String) async {
        guard running == nil, peers.contains(where: { $0.address == address }) else { return }
        if selected != address {
            loadedPeer = nil
            projects = []
            volumes = []
            result = nil
            desktopAvailability = nil
            connectionCheck = nil
            jobs = []
            jobDetail = nil
            supportsJobs = false
            jobRevision += 1
        }
        selected = address
        UserDefaults.standard.set(address, forKey: "selectedLinuxPeer")
        await send(PeerRequest(action: "pair"), label: "Contacting Linux")
    }

    func loadSelectedIfNeeded(_ address: String) async {
        if selected == address, loadedPeer != address { await select(address) }
    }

    func pair(_ address: String, receiveHandoffs: Bool = false) async {
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
        connectionCheck = nil
        jobs = []
        jobDetail = nil
        supportsJobs = info.jobProtocol == 1
        rememberTransferProtocol(info, for: address)
        loadedPeer = address
        jobRevision += 1
        result = nil
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: "linuxPeers")
        }
        UserDefaults.standard.set(address, forKey: "selectedLinuxPeer")
        if receiveHandoffs { enableReceiving(from: address) }
        notice = "Paired with \(peer.name)."
    }

    func enableReceiving(from address: String?) {
        guard address == nil || peers.contains(where: { $0.address == address }) else { return }
        receivingPeer = address
        UserDefaults.standard.set(address ?? "", forKey: "receivingLinuxPeer")
    }

    func diagnose() async {
        guard let address = selected, !checkingConnection else { return }
        checkingConnection = true
        connectionCheck = nil
        defer { checkingConnection = false }
        let check = await Task.detached(priority: .utility) { PeerClient.checkConnection(address) }.value
        if selected == address { connectionCheck = check }
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

    func openLink(_ text: String, to address: String? = nil) async {
        guard running == nil, let target = address ?? selected, peers.contains(where: { $0.address == target }) else { return }
        running = "Sending link"
        error = nil
        notice = nil
        defer { running = nil }
        do {
            if try await supportsDurableTransfers(on: target) {
                try await inbox.sendLink(text, to: target)
            } else {
                _ = try await Task.detached(priority: .userInitiated) {
                    try PeerClient.request(PeerRequest(action: "open-link", url: text), on: target)
                }.value
            }
            notice = "Opened on \(deviceName(target))."
        } catch { self.error = error.localizedDescription }
    }

    func sendFile(_ file: URL, volume: String, to address: String? = nil) async {
        guard running == nil, let target = address ?? selected, peers.contains(where: { $0.address == target }) else { return }
        running = "Sending file"
        error = nil
        notice = nil
        defer { running = nil }
        do {
            let path: String
            if try await supportsDurableTransfers(on: target) {
                path = try await inbox.sendFile(file, to: target, volume: volume)
            } else {
                path = try await Task.detached(priority: .userInitiated) {
                    try FileHandoff.send(file, on: target, volume: volume)
                }.value
            }
            notice = "Saved on \(deviceName(target)): \(path)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deviceName(_ address: String) -> String {
        peers.first(where: { $0.address == address })?.name ?? address
    }

    var sendVolume: String {
        guard let selected else { return "home" }
        let preferred = inbox.preferredVolume(for: selected)
        return volumes.contains(where: { $0.id == preferred }) ? preferred : "home"
    }

    func chooseFile(imagesOnly: Bool = false) {
        guard let target = selected, running == nil else { return }
        let destination = sendVolume
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        panel.message = "Send to \(deviceName(target))"
        if imagesOnly { panel.allowedContentTypes = [.image] }
        panel.begin { answer in
            guard answer == .OK, let file = panel.url else { return }
            Task { await self.sendFile(file, volume: destination, to: target) }
        }
    }

    func chooseReceiveFolder() {
        guard let target = selected else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { answer in
            guard answer == .OK, let folder = panel.url else { return }
            self.inbox.setPreferredFolder(folder, for: target)
        }
    }

    func save(name: String, path: String) async {
        await send(PeerRequest(action: "save", name: name, path: path), label: "Saving project")
    }

    func open(_ project: LinuxProject, on address: String? = nil) async {
        guard let target = address ?? selected else { return }
        if await send(PeerRequest(action: "open", project: project.id), label: "Opening folder", on: target) != nil {
            lastProjects[target] = project
            if let data = try? JSONEncoder().encode(lastProjects) {
                UserDefaults.standard.set(data, forKey: "lastLinuxProjects")
            }
            notice = "Opened \(project.name) on Linux."
        }
    }

    func openTerminal(_ project: LinuxProject) async {
        if await send(PeerRequest(action: "open-terminal", project: project.id), label: "Opening terminal") != nil {
            notice = "Opened the terminal for \(project.name)."
        }
    }

    func build(_ project: LinuxProject, preset: String = "build") async {
        guard let selected, running == nil else { return }
        if !supportsJobs {
            await send(PeerRequest(action: "build", project: project.id), label: "Building \(project.name)")
            return
        }
        let defaults = UserDefaults.standard
        let index = [selected, project.id, preset].joined(separator: "/")
        var pending = defaults.dictionary(forKey: "pendingJobStarts") ?? [:]
        let token = pending[index] as? String ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Save the ticket before the request so a lost response can be retried without starting a second job.
        pending[index] = token
        defaults.set(pending, forKey: "pendingJobStarts")
        if let reply = await send(PeerRequest(action: "job-start", project: project.id, job: token, preset: preset),
                                  label: "Starting \(project.name)"), let job = reply.job {
            pending.removeValue(forKey: index)
            defaults.set(pending, forKey: "pendingJobStarts")
            jobDetail = reply
            updateJob(job)
        }
    }

    func refreshJobs() async {
        guard supportsJobs, !checkingJobs, let address = selected else { return }
        checkingJobs = true
        let revision = jobRevision
        defer { checkingJobs = false }
        let reply = try? await Task.detached(priority: .utility) {
            try PeerClient.request(PeerRequest(action: "job-list"), on: address)
        }.value
        guard !Task.isCancelled, selected == address, revision == jobRevision, let list = reply?.jobs else { return }
        jobs = list
    }

    func inspectJob(_ job: LinuxJob, action: String = "job-status") async {
        if let reply = await send(PeerRequest(action: action, job: job.id), label: action == "job-cancel" ? "Cancelling job" : "Reading job") {
            jobDetail = reply
            if let job = reply.job { updateJob(job) }
        }
    }

    func fetchArtifact(for job: LinuxJob) async -> BuildArtifact? {
        await send(PeerRequest(action: "job-artifact", job: job.id), label: "Fetching artifact")?.artifact
    }

    private func updateJob(_ job: LinuxJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            guard jobs[index].updatedAt <= job.updatedAt else { return }
            jobs[index] = job
        } else { jobs.insert(job, at: 0) }
        jobRevision += 1
    }

    func scrape(_ url: String) async {
        await send(PeerRequest(action: "scrape", url: url), label: "Scraping on Linux")
    }

    private func rememberTransferProtocol(_ reply: PeerReply, for host: String) {
        transferProtocols[host] = reply.transferProtocol == 1
        UserDefaults.standard.set(transferProtocols, forKey: "durableTransferPeers")
    }

    private func supportsDurableTransfers(on host: String) async throws -> Bool {
        if let supported = transferProtocols[host] { return supported }
        let reply = try await Task.detached(priority: .utility) {
            try PeerClient.request(PeerRequest(action: "pair"), on: host)
        }.value
        guard reply.system == "Linux" else {
            throw PeerClient.Failure(reason: "The receiver did not identify a Linux system.", kind: .receiverError)
        }
        rememberTransferProtocol(reply, for: host)
        return reply.transferProtocol == 1
    }

    @discardableResult
    private func send(_ request: PeerRequest, label: String, on address: String? = nil) async -> PeerReply? {
        guard running == nil, let target = address ?? selected, peers.contains(where: { $0.address == target }) else { return nil }
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
            if request.action == "pair" {
                loadedPeer = target
                desktopAvailability = reply.desktopAvailability
                supportsJobs = reply.jobProtocol == 1
                rememberTransferProtocol(reply, for: target)
            }
            if ["build", "scrape"].contains(request.action), reply.output != nil { result = reply }
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
            if let target = model.selected {
                Toggle("Automatic with \(model.selectedName)", isOn: Binding(
                    get: { sync.isEnabled(for: target) },
                    set: { sync.setEnabled($0, for: target) }
                ))
                if sync.isEnabled(for: target) {
                    Text(sync.address == target && sync.ready ? "Automatic sharing connected" : "Waiting for its input or desktop link")
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
    @ObservedObject var input: LinkModel
    @State private var address = ""
    @State private var projectName = ""
    @State private var projectPath = ""
    @State private var url = ""
    @State private var showPair = false
    @State private var showSave = false
    @State private var showResearch = false
    @State private var showConnection = false
    @State private var receiveWhenPaired = false
    @State private var link = ""

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
                        if showConnection { connectionDetails }
                        handoff
                        TransferInboxView(inbox: inbox, address: model.selected)
                        projects
                        if model.supportsJobs { JobPanel(model: model) }
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
            Toggle("Receive handoffs from this device on this Mac", isOn: $receiveWhenPaired)
                .font(.callout)
            if let error = model.pairingError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if model.needsHostVerification, PeerClient.validAddress(target) {
                Text("In Terminal, compare the fingerprint SSH shows with the host key on Linux before approving it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Copy verification command") { copyVerificationCommand(for: target) }
            }
        }
        .disabled(model.running != nil)
    }

    private func pair(_ target: String) {
        guard PeerClient.validAddress(target) else { return }
        Task {
            await model.pair(target, receiveHandoffs: receiveWhenPaired)
            if model.pairingError == nil, model.selected == target {
                showPair = false
                receiveWhenPaired = false
                address = ""
            }
        }
    }

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Send to \(model.selectedName)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if !model.volumes.isEmpty {
                    Picker("Save to", selection: Binding(
                        get: { model.sendVolume },
                        set: { volume in
                            if let selected = model.selected { inbox.setPreferredVolume(volume, for: selected) }
                        }
                    )) {
                        ForEach(model.volumes) { disk in Text(disk.name).tag(disk.id) }
                    }
                    .fixedSize()
                }
                Button("Send file…") { model.chooseFile() }
                    .help("Choose or drop one file to send")
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
            if let selected = model.selected, model.receivingPeer == selected {
                HStack {
                    Label("Receive in \(inbox.preferredFolder(for: selected).lastPathComponent)", systemImage: "tray.and.arrow.down")
                        .lineLimit(1)
                        .help(inbox.preferredFolder(for: selected).path)
                    Spacer()
                    Button("Choose folder…") { model.chooseReceiveFolder() }
                }
                .font(.caption)
            }
        }
        .disabled(model.running != nil)
        .dropDestination(for: URL.self) { items, _ in
            guard let target = model.selected, model.running == nil, items.count == 1,
                  let file = items.first, file.isFileURL else { return false }
            let volume = model.sendVolume
            Task { await model.sendFile(file, volume: volume, to: target) }
            return true
        }
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
            VStack(alignment: .trailing, spacing: 4) {
                OpenDesktopMenu(desktop: desktop, address: model.selected).fixedSize()
                Button(model.checkingConnection ? "Checking…" : "Check connection") {
                    showConnection = true
                    Task { await model.diagnose() }
                }
                .controlSize(.small)
                .disabled(model.checkingConnection)
            }
        }
        .padding(15)
        .background(.purple.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.purple.opacity(0.18)))
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let report = model.connectionCheck {
                ForEach(report.steps) { step in
                    checkRow(step.name, detail: step.detail, status: step.state)
                }
                if report.offersHostVerification, let selected = model.selected {
                    Button("Copy verification command") { copyVerificationCommand(for: selected) }
                }
            } else if model.checkingConnection {
                ProgressView().controlSize(.small).accessibilityLabel("Checking the connection")
            }
            if let selected = model.selected {
                let inputReady = input.inputPeerAddress == selected && input.status?.connected == true
                checkRow("Shared keyboard and mouse",
                         detail: inputReady ? "Input link connected" : "Check the Deskflow and Waynergy pairing for this device",
                         status: inputReady ? .ready : .unchecked)
                checkRow("Automatic clipboard",
                         detail: clipboardSync.address == selected && clipboardSync.ready ? "Connected" : "Turn on sharing for this device in Clipboard",
                         status: clipboardSync.address == selected && clipboardSync.ready ? .ready : .unchecked)
                Toggle("Receive handoffs from \(model.selectedName) on this Mac", isOn: Binding(
                    get: { model.receivingPeer == selected },
                    set: { model.enableReceiving(from: $0 ? selected : nil) }
                ))
            }
        }
        .font(.caption)
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 9))
    }

    private func checkRow(_ title: String, detail: String, status: ConnectionCheck.State) -> some View {
        let symbol = status == .ready ? "checkmark.circle" : status == .actionNeeded ? "exclamationmark.circle" : "circle.dashed"
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(status == .actionNeeded ? Color.orange : .secondary)
            Text(title).fontWeight(.medium)
            Text(detail).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func copyVerificationCommand(for target: String) {
        guard PeerClient.validAddress(target) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "ssh -o StrictHostKeyChecking=ask -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -- '\(target)' true",
            forType: .string
        )
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
                    if model.supportsJobs { Button("Terminal") { Task { await model.openTerminal(project) } } }
                    if let presets = project.presets, !presets.isEmpty, model.supportsJobs {
                        Menu("Run") {
                            ForEach(presets, id: \.id) { preset in
                                Button(preset.name) { Task { await model.build(project, preset: preset.id) } }
                            }
                        }
                        .fixedSize()
                    } else if project.canBuild {
                        Button("Build") { Task { await model.build(project) } }
                    }
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
