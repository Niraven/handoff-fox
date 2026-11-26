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
    @Published private(set) var reachability: [String: PeerReachability] = [:]
    @Published private(set) var lastSeen: [String: Date] = [:]
    @Published private(set) var agents: [LinuxAgentSession] = []
    @Published private(set) var agentsUnavailable = false
    @Published private(set) var hostKeys: [HostTrust.Key] = []
    @Published private(set) var hostKeyError: String?
    @Published private(set) var loadingHostKeys = false
    @Published private(set) var gliffHint: PeerReply?
    @Published private(set) var preflight: ConnectionCheck?
    @Published private(set) var checkingPreflight = false
    private var lastJobRefresh = Date.distantPast
    private var lastAgentProbe = Date.distantPast
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
            notice = nil
            error = nil
            clipboardFeedback = nil
            preflight = nil
            agents = []
            agentsUnavailable = false
            clearPairingError()
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
            if needsHostVerification { await loadHostKeys(address) }
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
        agentsUnavailable = false
        rememberTransferProtocol(info, for: address)
        loadedPeer = address
        jobRevision += 1
        result = nil
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: "linuxPeers")
        }
        UserDefaults.standard.set(address, forKey: "selectedLinuxPeer")
        if receiveHandoffs { enableReceiving(from: address) }
        noteReachable(address)
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
        if selected == address {
            connectionCheck = check
            if let failing = check.steps.first(where: { $0.state == .actionNeeded }) {
                reachability[address] = .unreachable(String(failing.detail.prefix(52)))
            } else {
                noteReachable(address)
            }
        }
    }

    /// Reports which stage a new address fails at before anything is installed,
    /// so pairing a machine that is not ready is a diagnosis rather than an error.
    func preflightCheck(_ address: String) async {
        guard PeerClient.validAddress(address), !checkingPreflight else { return }
        checkingPreflight = true
        preflight = nil
        defer { checkingPreflight = false }
        let check = await Task.detached(priority: .utility) { PeerClient.checkConnection(address) }.value
        preflight = check
        if let failing = check.steps.first(where: { $0.state == .actionNeeded }) {
            reachability[address] = .unreachable(String(failing.detail.prefix(52)))
        } else if check.steps.allSatisfy({ $0.state == .ready || $0.state == .unchecked }) {
            noteReachable(address)
        }
    }

    /// Shows the key the machine presents so the person can compare it with the
    /// Linux side themselves. Nothing is trusted until they say so.
    func loadHostKeys(_ address: String) async {
        guard PeerClient.validAddress(address), !loadingHostKeys else { return }
        loadingHostKeys = true
        hostKeyError = nil
        hostKeys = []
        defer { loadingHostKeys = false }
        do {
            hostKeys = try await Task.detached(priority: .userInitiated) {
                try HostTrust.keys(for: address)
            }.value
        } catch {
            hostKeyError = error.localizedDescription
        }
    }

    func trustHost(_ address: String) async -> Bool {
        let keys = hostKeys
        do {
            try await Task.detached(priority: .userInitiated) { try HostTrust.trust(keys) }.value
            needsHostVerification = false
            hostKeys = []
            return true
        } catch {
            hostKeyError = error.localizedDescription
            return false
        }
    }

    /// How Gliff would be installed here, if the owner wants it. Reported, never run.
    func loadGliffHint(for address: String) async {
        guard gliffHint == nil else { return }
        gliffHint = try? await Task.detached(priority: .utility) {
            try PeerClient.request(PeerRequest(action: "setup-hint"), on: address)
        }.value
    }

    func savePreset(_ project: LinuxProject, name: String, script: String, arguments: String, artifact: String) async {
        var argv = [script.trimmingCharacters(in: .whitespacesAndNewlines)]
        argv += arguments.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        var request = PeerRequest(action: "save-preset", project: project.id, name: name)
        request.argv = argv
        let trimmed = artifact.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { request.artifact = trimmed }
        await send(request, label: "Saving preset")
    }

    /// Read-only: which known coding agents are running on the Linux side.
    /// A receiver that predates the probe answers "unknown action", and the row
    /// stays hidden rather than reporting zero.
    func loadAgents() async {
        guard let address = selected, !agentsUnavailable else { return }
        if Date().timeIntervalSince(lastAgentProbe) < 5 { return }
        lastAgentProbe = Date()
        do {
            let reply = try await Task.detached(priority: .utility) {
                try PeerClient.request(PeerRequest(action: "agents"), on: address)
            }.value
            if selected == address { agents = reply.agents ?? [] }
        } catch let failure as PeerClient.Failure where failure.reason.contains("Unknown Handoff Fox action") {
            agentsUnavailable = true
            agents = []
        } catch {
            agents = []
        }
    }

    /// Opens the authenticated session when the panel is shown, so the first
    /// action does not pay for the handshake the user is waiting on.
    func prewarm() async {
        guard let address = selected, running == nil else { return }
        _ = try? await Task.detached(priority: .utility) {
            try PeerClient.request(PeerRequest(action: "pair"), on: address)
        }.value
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

    func setSendVolume(_ volume: String) {
        guard let selected else { return }
        inbox.setPreferredVolume(volume, for: selected)
    }

    func volumeName(_ id: String) -> String {
        volumes.first(where: { $0.id == id })?.name ?? (id == "workspace" ? "Workspace" : "Home")
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

    func acceptFileDrop(_ items: [URL]) -> Bool {
        guard let target = selected, running == nil, items.count == 1,
              let file = items.first, file.isFileURL else { return false }
        let volume = sendVolume
        Task { await sendFile(file, volume: volume, to: target) }
        return true
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

    @discardableResult
    func refreshJobs() async -> Bool {
        guard supportsJobs, !checkingJobs, let address = selected else { return false }
        if Date().timeIntervalSince(lastJobRefresh) < 1 { return !jobs.isEmpty }
        checkingJobs = true
        let revision = jobRevision
        defer { checkingJobs = false }
        let reply = try? await Task.detached(priority: .utility) {
            try PeerClient.request(PeerRequest(action: "job-list"), on: address)
        }.value
        guard !Task.isCancelled, selected == address, revision == jobRevision, let list = reply?.jobs else { return false }
        lastJobRefresh = Date()
        jobs = list
        return true
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
        noteChecking(target)
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
                gliffHint = nil
                if reply.desktopAvailability == .needsGliff { Task { await loadGliffHint(for: target) } }
                rememberTransferProtocol(reply, for: target)
            }
            if ["build", "scrape"].contains(request.action), reply.output != nil { result = reply }
            if request.action == "save" { notice = "Project saved on Linux." }
            noteReachable(target)
            return reply
        } catch {
            self.error = error.localizedDescription
            noteUnreachable(target, error: error)
            return nil
        }
    }

    func reachability(for address: String?) -> PeerReachability {
        guard let address else { return .unknown }
        return reachability[address] ?? .unknown
    }

    private func noteChecking(_ address: String) {
        if reachability[address] == nil { reachability[address] = .checking }
    }

    private func noteReachable(_ address: String) {
        reachability[address] = .reachable
        lastSeen[address] = Date()
    }

    private func noteUnreachable(_ address: String, error: Error) {
        let reason: String
        if let failure = error as? PeerClient.Failure {
            switch failure.kind {
            case .timeout: reason = "Linux didn’t answer"
            case .unreachable: reason = "Not reachable"
            case .untrustedHost, .changedHost: reason = "Host key needs checking"
            case .authentication: reason = "SSH key rejected"
            case .missingReceiver: reason = "Receiver missing"
            case .receiverError, .other: reason = "Linux returned an error"
            }
        } else {
            reason = error.localizedDescription
        }
        reachability[address] = .unreachable(reason)
    }

    func cancel(_ job: LinuxJob) async {
        guard let address = selected, supportsJobs else { return }
        let revision = jobRevision
        do {
            let reply = try await Task.detached(priority: .userInitiated) {
                try PeerClient.request(PeerRequest(action: "job-cancel", job: job.id), on: address)
            }.value
            // The person can switch devices while this is in flight, and a
            // result for another machine must not be shown as this one's.
            guard selected == address, revision == jobRevision else { return }
            jobDetail = reply
            if let updated = reply.job { updateJob(updated) }
        } catch {
            guard selected == address, revision == jobRevision else { return }
            self.error = error.localizedDescription
        }
    }

    func copyHostVerificationCommand(for target: String) {
        guard PeerClient.validAddress(target) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "ssh -o StrictHostKeyChecking=ask -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -- '\(target)' true",
            forType: .string
        )
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
    @State private var showPreset = false
    @State private var presetProject = ""
    @State private var presetName = ""
    @State private var presetScript = ""
    @State private var presetArguments = ""
    @State private var presetArtifact = ""
    @State private var link = ""
    @FocusState private var addressFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    private var statusMessage: (text: String, symbol: String, tone: Color)? {
        if let error = model.error { return (error, "exclamationmark.circle", palette.danger) }
        if let error = model.pairingError { return (error, "person.badge.key", palette.danger) }
        if let message = desktop.message { return (message, "display.trianglebadge.exclamationmark", palette.warning) }
        if let clipboard = model.clipboardFeedback { return (clipboard, "clipboard", palette.textSecondary) }
        if let receipt = inbox.lastReceived { return (receipt, "arrow.down.left", palette.textSecondary) }
        if let notice = model.notice { return (notice, "checkmark.circle", palette.textSecondary) }
        return nil
    }

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
                    if let status = statusMessage {
                        Label(status.text, systemImage: status.symbol)
                            .font(.callout)
                            .foregroundStyle(status.tone)
                            .fixedSize(horizontal: false, vertical: true)
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
        return VStack(alignment: .leading, spacing: 8) {
            Text("Pair a Linux computer").font(.subheadline.weight(.semibold))
            Text(model.peers.isEmpty
                 ? "Your SSH key has to reach the account first. Then pair once and the fox opens it in a click."
                 : "Add another Linux computer you reach over SSH.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("SSH alias or user@hostname", text: $address)
                    .accessibilityLabel("SSH address")
                    .focused($addressFocused)
                    .onSubmit { pair(target) }
                    .onChange(of: address) { _, _ in model.clearPairingError() }
                Button("Pair") { pair(target) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!PeerClient.validAddress(target))
            }
            if PeerClient.validAddress(target) {
                Text("Check it first: ssh \(target) should sign in without asking for a password.")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if PeerClient.validAddress(target) {
                Button(model.checkingPreflight ? "Checking…" : "Check this address first") {
                    Task { await model.preflightCheck(target) }
                }
                .controlSize(.small)
                .disabled(model.checkingPreflight)
            }
            if let check = model.preflight, check.steps.contains(where: { $0.state != .ready }) {
                FoxChecklist(steps: check.steps, compact: false)
            }
            Toggle("Receive handoffs from this device on this Mac", isOn: $receiveWhenPaired)
                .font(.callout)
            if model.needsHostVerification, PeerClient.validAddress(target) {
                if model.hostKeys.isEmpty {
                    Text("Compare the fingerprint SSH shows with the host key on Linux before approving it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Copy verification command") { model.copyHostVerificationCommand(for: target) }
                } else {
                    Text("Compare with the key on Linux, then trust it:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.hostKeys.prefix(2)) { key in
                        Text("\(key.type) \(key.fingerprint)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                    HStack {
                        Button("Trust and pair") {
                            Task {
                                if await model.trustHost(target) { pair(target) }
                            }
                        }
                        Button("Copy verification command") { model.copyHostVerificationCommand(for: target) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .disabled(model.running != nil)
        .onAppear { addressFocused = true }
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
        .dropDestination(for: URL.self) { items, _ in model.acceptFileDrop(items) }
    }

    private var desktopCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 40, height: 40)
                .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        .padding(14)
        .foxCard()
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let report = model.connectionCheck {
                ForEach(report.steps) { step in
                    checkRow(step.name, detail: step.detail, status: step.state)
                }
                if report.offersHostVerification, let selected = model.selected {
                    Button("Copy verification command") { model.copyHostVerificationCommand(for: selected) }
                }
            } else if model.checkingConnection {
                ProgressView().controlSize(.small).accessibilityLabel("Checking the connection")
            }
            if let selected = model.selected {
                let inputReady = input.inputPeerAddress == selected && input.status?.connected == true
                checkRow("Shared keyboard and mouse",
                         detail: inputReady ? "Connected · Control Option Esc returns to this Mac"
                                            : "Check the Deskflow and Waynergy pairing for this device",
                         status: inputReady ? .ready : .unchecked)
                checkRow("Automatic clipboard",
                         detail: clipboardSync.address == selected && clipboardSync.ready ? "Connected" : "Turn on sharing for this device in Clipboard",
                         status: clipboardSync.address == selected && clipboardSync.ready ? .ready : .unchecked)
                Toggle("Receive handoffs from \(model.selectedName) on this Mac", isOn: Binding(
                    get: { model.receivingPeer == selected },
                    set: { model.enableReceiving(from: $0 ? selected : nil) }
                ))
                HStack(spacing: 6) {
                    ForEach([Shortcut.hermes, Shortcut.herdr, Shortcut.workspace], id: \.rawValue) { target in
                        Button(target.rawValue.capitalized) { Task { await input.open(target) } }
                            .disabled(input.inputPeerAddress == nil)
                    }
                }
                .controlSize(.small)
            }
        }
        .font(.caption)
        .padding(12)
        .foxCard(raised: false, radius: 9)
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

    @ViewBuilder private var desktopSetup: some View {
        switch model.desktopAvailability {
        case .ready:
            Label("Desktop ready", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .needsGliff:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label("Desktop sharing needs Gliff on Linux.", systemImage: "display")
                    Link("Gliff setup", destination: URL(string: "https://github.com/omacom/gliff")!)
                }
                if let hint = model.gliffHint {
                    if let command = hint.command {
                        HStack(spacing: 6) {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    } else if hint.packageManager != nil {
                        Text("No package for this distribution. Build it from the Gliff source.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        case .needsHyprland:
            Label("Sign in to Hyprland on Linux to share its desktop.", systemImage: "display")
                .font(.caption).foregroundStyle(.secondary)
        case nil:
            Label("Not checked yet · Check connection", systemImage: "circle.dashed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Saved projects").font(.subheadline.weight(.semibold))
                Spacer()
                if !model.projects.isEmpty {
                    Button(showPreset ? "Cancel preset" : "New preset…") { showPreset.toggle() }
                }
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
            if showPreset {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("Project", selection: $presetProject) {
                            ForEach(model.projects) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        TextField("Preset name", text: $presetName)
                    }
                    HStack {
                        TextField("./ci/test.sh", text: $presetScript)
                            .accessibilityLabel("Script inside the project")
                        TextField("Arguments", text: $presetArguments)
                            .accessibilityLabel("Script arguments")
                    }
                    HStack {
                        TextField("Artifact, optional", text: $presetArtifact)
                            .accessibilityLabel("Artifact path inside the project")
                        Button("Save preset") {
                            guard let project = model.projects.first(where: { $0.id == presetProject }) else { return }
                            Task {
                                await model.savePreset(project, name: presetName, script: presetScript,
                                                       arguments: presetArguments, artifact: presetArtifact)
                                if model.error == nil {
                                    showPreset = false
                                    presetName = ""
                                    presetScript = ""
                                    presetArguments = ""
                                    presetArtifact = ""
                                }
                            }
                        }
                        .disabled(presetName.isEmpty || presetScript.isEmpty || presetProject.isEmpty)
                    }
                    Text("The script must already exist inside the project and be executable. Handoff Fox cannot add one the Linux owner didn't put there.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .foxCard(raised: false, radius: 8)
                .onAppear { if presetProject.isEmpty { presetProject = model.projects.first?.id ?? "" } }
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
                .padding(8)
                .foxCard(radius: 8)
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
                    .buttonStyle(.bordered)
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
            .foxCard(raised: false, radius: 8)
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
