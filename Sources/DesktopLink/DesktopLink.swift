import AppKit
import Combine
import Carbon
import OSLog
import SwiftUI

@MainActor
final class LinkModel: ObservableObject {
    let inputPeerAddress = UserDefaults.standard.string(forKey: "initialLinuxPeer")
        .flatMap { PeerClient.validAddress($0) ? $0 : nil }
    @Published private(set) var status: InputStatus?
    @Published private(set) var hop = 0
    @Published private(set) var updating = false
    @Published private(set) var message: String?
    @Published private(set) var activity: CitadelActivity?
    @Published private(set) var activityLoading = false

    func refresh() async {
        guard !updating else { return }
        await update()
    }

    func setPaused(_ pause: Bool) async {
        guard !updating else { return }
        await update(pause: pause)
    }

    private func update(pause: Bool? = nil) async {
        updating = true
        if let pause {
            message = await Task.detached(priority: .userInitiated) {
                pause ? InputService.pause() : InputService.resume()
            }.value
        }
        let next = await Task.detached(priority: .utility) { InputService.status() }.value
        if next.justConnected(after: status) { hop += 1 }
        if status != next { status = next }
        updating = false
    }


    func open(_ target: Shortcut) async {
        guard let inputPeerAddress else { return }
        message = await Task.detached(priority: .userInitiated) { InputService.open(target, on: inputPeerAddress) }.value
    }

    func loadActivity() async {
        guard let inputPeerAddress, !activityLoading else { return }
        activityLoading = true
        activity = await Task.detached(priority: .utility) { InputService.activity(on: inputPeerAddress) }.value
        activityLoading = false
    }
}

@main
@MainActor
enum DesktopLink {
    static func main() {
        let controller = LinkController()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
final class LinkController: NSObject, NSApplicationDelegate {
    let model = LinkModel()
    private let art = Bundle.main.url(forResource: "TrayFox", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
    private let popover = NSPopover()
    private lazy var workbenchModel = WorkbenchModel(inbox: inbox)
    private let clipboardSync = ClipboardSync(
        address: UserDefaults.standard.string(forKey: "initialLinuxPeer"),
        enabled: UserDefaults.standard.bool(forKey: "automaticClipboard"),
        defaults: .standard
    )
    private var workbenchWindow: NSWindow?
    private var quickWindow: NSPanel?
    private let inbox = HandoffInbox()
    private let notifier = FoxNotifier()
    private var announcedJobs = Set<String>()
    private var activeJobIDs = Set<String>()
    private let desktop = RemoteDesktop()
    private var hotkey: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private lazy var menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var refreshLoop: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()
    private var warning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuItem.autosaveName = "DesktopLinkFox"
        popover.behavior = .transient
        let panel = NSHostingController(rootView: LinkPanel(
            model: model,
            devices: workbenchModel,
            clipboardSync: clipboardSync,
            desktop: desktop,
            inbox: inbox,
            close: { [weak self] in self?.popover.performClose(nil) },
            workbench: { [weak self] in self?.showWorkbench() }
        ))
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel
        if let button = menuItem.button {
            button.setAccessibilityLabel("Handoff Fox")
            button.target = self
            button.action = #selector(toggle)
        }
        redraw()
        model.$status.sink { [weak self] value in
            guard let self else { return }
            self.menuItem.button?.toolTip = self.model.inputPeerAddress.flatMap { _ in value?.title } ?? "Handoff Fox"
            self.updateClipboard(inputConnected: value?.connected == true, desktopHost: self.desktop.activeHost,
                                 selected: self.workbenchModel.selected)
        }.store(in: &observations)
        desktop.$activeHost.sink { [weak self] address in
            guard let self else { return }
            self.updateClipboard(inputConnected: self.model.status?.connected == true, desktopHost: address,
                                 selected: self.workbenchModel.selected)
        }.store(in: &observations)
        workbenchModel.$selected.removeDuplicates().sink { [weak self] address in
            guard let self else { return }
            self.updateClipboard(inputConnected: self.model.status?.connected == true, desktopHost: self.desktop.activeHost,
                                 selected: address)
        }.store(in: &observations)
        workbenchModel.$receivingPeer.removeDuplicates().sink { [weak self] address in
            self?.startInbox(for: address)
        }.store(in: &observations)
        model.$activity.map { $0?.needsAttention ?? false }.removeDuplicates().sink { [weak self] warning in
            self?.warning = warning
            self?.redraw()
        }.store(in: &observations)
        workbenchModel.$reachability.dropFirst().sink { [weak self] _ in
            self?.redraw()
        }.store(in: &observations)
        model.$hop.dropFirst().sink { [weak self] _ in
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            self?.redraw(lift: 2)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(170))
                self?.redraw()
            }
        }.store(in: &observations)
        refreshLoop = Task { [weak self, model] in
            var nextActivity = Date.distantPast
            while !Task.isCancelled {
                guard self != nil else { return }
                await model.refresh()
                if Date() >= nextActivity {
                    nextActivity = Date().addingTimeInterval(120)
                    Task { await model.loadActivity() }
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        notifier.prepare()
        inbox.fileDeliveries.sink { [weak self] transfer in
            guard let self, self.notificationsEnabled else { return }
            self.notifier.post("Delivered", "\(transfer.title) landed on \(self.workbenchModel.selectedName).")
        }.store(in: &observations)
        inbox.$lastReceived.compactMap { $0 }.sink { [weak self] message in
            guard let self, self.notificationsEnabled else { return }
            self.notifier.post("Received", message)
        }.store(in: &observations)
        workbenchModel.$jobs.sink { [weak self] jobs in
            guard let self else { return }
            if self.notificationsEnabled {
                for job in jobs where !job.state.isActive && self.activeJobIDs.contains(job.id)
                    && !self.announcedJobs.contains(job.id) {
                    self.announcedJobs.insert(job.id)
                    self.notifier.post(job.title, job.state == .succeeded ? "Finished" : "Ended: \(job.state.label)")
                }
            }
            self.activeJobIDs = Set(jobs.filter { $0.state.isActive }.map(\.id))
        }.store(in: &observations)
        registerHotkey()
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        sleepObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.desktop.prepareForSleep() }
        }
        wakeObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clipboardSync.setTarget(self.workbenchModel.selected, connected: false)
                await self.model.refresh()
                self.updateClipboard(inputConnected: self.model.status?.connected == true,
                                     desktopHost: self.desktop.activeHost, selected: self.workbenchModel.selected)
                self.startInbox(for: self.workbenchModel.receivingPeer)
                await self.desktop.recoverAfterWake()
            }
        }
        if CommandLine.arguments.contains("--workbench") { showWorkbench() }
        if CommandLine.arguments.contains("--quick-actions") { showQuickActions() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggle() }
        return false
    }

    @objc func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = menuItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            Task { await model.loadActivity() }
            Task { await workbenchModel.prewarm() }
        }
    }

    private func updateClipboard(inputConnected: Bool, desktopHost: String?, selected: String?) {
        let sameInput = selected != nil && selected == model.inputPeerAddress && inputConnected
        let sameDesktop = selected != nil && selected == desktopHost
        clipboardSync.setTarget(selected, connected: sameInput || sameDesktop)
    }

    private func startInbox(for address: String?) {
        inbox.start(address: address, openProjects: { [weak self] in
            self?.showWorkbench()
        }, openDesktop: { [weak self] host in
            guard let self, self.workbenchModel.receivingPeer == host else { return }
            Task {
                guard self.workbenchModel.receivingPeer == host else { return }
                await self.desktop.showOrOpen(host: host)
            }
        })
    }

    private var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "foxNotifications") as? Bool ?? true
    }

    private func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<LinkController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.showQuickActions() }
            return noErr
        }, 1, &spec, context, &hotkeyHandler)
        guard installed == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x48414E44, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(controlKey | optionKey),
                                       identifier, GetApplicationEventTarget(), 0, &hotkey)
        Logger(subsystem: "local.desktoplink.control", category: "Handoff")
            .info("Handoff Control-Option-J registration status: \(status)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktop.disconnect()
        refreshLoop?.cancel()
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    private func showWorkbench() {
        quickWindow?.orderOut(nil)
        popover.performClose(nil)
        if workbenchWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 450),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Handoff Fox"
            window.contentMinSize = NSSize(width: 530, height: 410)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: Workbench(model: workbenchModel, clipboardSync: clipboardSync, inbox: inbox, desktop: desktop, input: model))
            window.center()
            workbenchWindow = window
        }
        NSApp.activate()
        workbenchWindow?.makeKeyAndOrderFront(nil)
    }

    private func showQuickActions() {
        popover.performClose(nil)
        if let quickWindow, quickWindow.isVisible {
            quickWindow.orderOut(nil)
            return
        }
        if quickWindow == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 332, height: 198),
                                 styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            window.title = "Handoff Fox Quick Actions"
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            let view = NSHostingController(rootView: QuickActions(model: workbenchModel, desktop: desktop, inbox: inbox,
                close: { [weak window] in window?.orderOut(nil) },
                workbench: { [weak self] in self?.showWorkbench() }))
            view.sizingOptions = [.preferredContentSize]
            window.contentViewController = view
            window.center()
            quickWindow = window
        }
        NSApp.activate()
        quickWindow?.makeKeyAndOrderFront(nil)
    }

    private func redraw(lift: CGFloat = 0) {
        guard let art else {
            menuItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
            return
        }
        let reachability = workbenchModel.reachability(for: workbenchModel.selected)
        let dimmed = reachability.isUnreachable
        let needsAttention = warning
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .none
            art.draw(in: NSRect(x: 1, y: lift, width: 18, height: 18),
                     from: .zero, operation: .sourceOver, fraction: dimmed ? 0.45 : 1)
            if needsAttention {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 14, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        menuItem.button?.image = image
        menuItem.button?.toolTip = workbenchModel.selected == nil
            ? "Handoff Fox"
            : "\(workbenchModel.selectedName) · \(reachability.summary)"
        menuItem.button?.setAccessibilityValue(reachability.summary)
    }
}


struct LinkPanel: View {
    @ObservedObject var model: LinkModel
    @ObservedObject var devices: WorkbenchModel
    @ObservedObject var clipboardSync: ClipboardSync
    @ObservedObject var desktop: RemoteDesktop
    @ObservedObject var inbox: HandoffInbox
    let close: () -> Void
    let workbench: () -> Void

    @AppStorage("foxShowsJobs") private var showsJobs = false
    @AppStorage("foxShowsAgents") private var showsAgents = false
    @State private var targetingFile = false
    @State private var reaction = 0
    @State private var jobsReachable: Bool?
    @State private var pairingAddress = ""
    @State private var pairing = false
    @State private var enteringLink = false
    @State private var link = ""
    @FocusState private var pairFocused: Bool
    @FocusState private var linkFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }
    private var reachability: PeerReachability { devices.reachability(for: devices.selected) }
    private var showsInput: Bool {
        model.inputPeerAddress != nil && model.inputPeerAddress == devices.selected
    }
    private var trimmedPair: String {
        pairingAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var noticeLine: (text: String, symbol: String, tone: Color)? {
        if let error = devices.error { return (error, "exclamationmark.circle", palette.danger) }
        if let message = desktop.message { return (message, "display.trianglebadge.exclamationmark", palette.warning) }
        if let feedback = devices.clipboardFeedback { return (feedback, "clipboard", palette.textSecondary) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if devices.selected == nil {
                firstRun
            } else {
                OpenDesktopMenu(desktop: desktop, address: devices.selected)
                if reachability.isUnreachable { recovery }
                sendRow
                if enteringLink { linkRow }
                FoxTransferFeedback(inbox: inbox, address: devices.selected, device: devices.selectedName,
                                    busy: devices.running != nil)
                lastProject
                if showsJobs { jobActivity }
                if showsAgents, !devices.agentsUnavailable { agentRow }
            }
            if let line = noticeLine {
                Label(line.text, systemImage: line.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(line.tone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(12)
        .frame(width: 264, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: close)
        .task(id: showsJobs ? devices.selected : nil) {
            jobsReachable = nil
            guard showsJobs, let host = devices.selected else { return }
            await devices.loadSelectedIfNeeded(host)
            while !Task.isCancelled {
                let ready = await devices.refreshJobs()
                guard !Task.isCancelled, devices.selected == host else { return }
                jobsReachable = ready
                try? await Task.sleep(for: .seconds(devices.jobs.contains { $0.state.isActive } ? 3 : 10))
            }
        }
        .onChange(of: model.hop) { _, _ in
            if showsInput { reaction += 1 }
        }
        .onChange(of: devices.jobs) { previous, current in
            guard showsJobs else { return }
            let running = Set(previous.filter { $0.state.isActive }.map(\.id))
            if current.contains(where: { $0.state == .succeeded && running.contains($0.id) }) { reaction += 1 }
        }
        .onReceive(inbox.fileDeliveries) { file in
            if inbox.latestOutgoingFile(to: devices.selected)?.id == file.id { reaction += 1 }
        }
        .onChange(of: devices.selected) { _, _ in
            enteringLink = false
            link = ""
        }
        .task(id: showsAgents ? devices.selected : nil) {
            guard showsAgents else { return }
            await devices.loadAgents()
        }
        .onDisappear {
            targetingFile = false
            enteringLink = false
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FoxCompanion(attentive: targetingFile, reaction: reaction)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(devices.selected.map { devices.deviceName($0) } ?? "Handoff Fox")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if devices.selected != nil {
                    FoxStatusLine(reachability: reachability)
                } else {
                    Text("No Linux computer paired")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textTertiary)
                }
                if targetingFile, devices.selected != nil {
                    Text("Drop to send to \(devices.selectedName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            optionsMenu
        }
        .padding(10)
        .foxCard()
        .dropDestination(for: URL.self) { items, _ in devices.acceptFileDrop(items) } isTargeted: { value in
            targetingFile = value && devices.selected != nil && devices.running == nil
        }
    }

    private var optionsMenu: some View {
        Menu {
            if devices.selected != nil {
                Button("Send a link…") {
                    enteringLink = true
                    linkFocused = true
                }
                Button("Send a screenshot…") { devices.chooseFile(imagesOnly: true) }
                Button("Choose receive folder…") { devices.chooseReceiveFolder() }
                Divider()
                Toggle("Show Linux jobs", isOn: $showsJobs)
                Toggle("Show Linux agents", isOn: $showsAgents)
                Button("Check connection") {
                    workbench()
                    Task { await devices.diagnose() }
                }
                Divider()
                ClipboardMenu(model: devices, sync: clipboardSync)
            }
            if showsInput, let status = model.status {
                Button(status.serverRunning ? "Pause keyboard sharing" : "Resume keyboard sharing") {
                    Task { await model.setPaused(status.serverRunning) }
                }
                .disabled(model.updating)
            }
            Divider()
            Button("All controls…", action: workbench)
            Button("Quit Handoff Fox") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More actions")
        .help("More actions")
    }

    private var firstRun: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pair the Linux computer you already reach over SSH. After that it is one click.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("user@host or SSH alias", text: $pairingAddress)
                .textFieldStyle(.roundedBorder)
                .focused($pairFocused)
                .accessibilityLabel("SSH address")
                .onSubmit(pair)
                .onChange(of: pairingAddress) { _, _ in devices.clearPairingError() }
            Button(pairing ? "Pairing…" : "Pair Linux") { pair() }
                .buttonStyle(FoxPrimaryButtonStyle())
                .disabled(pairing || !PeerClient.validAddress(trimmedPair))
            if PeerClient.validAddress(trimmedPair) {
                Button(devices.checkingPreflight ? "Checking…" : "Check this address first") {
                    Task { await devices.preflightCheck(trimmedPair) }
                }
                .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                .disabled(devices.checkingPreflight)
            }
            if let check = devices.preflight, check.steps.contains(where: { $0.state != .ready }) {
                FoxChecklist(steps: check.steps)
                    .padding(.top, 1)
            }
            Text("Check it first: ssh \(trimmedPair.isEmpty ? "user@host" : trimmedPair) should sign in without a password.")
                .font(.system(size: 10))
                .foregroundStyle(palette.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let error = devices.pairingError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if devices.needsHostVerification { hostKeyPrompt }
            }
        }
        .padding(11)
        .foxCard()
        .onAppear { pairFocused = true }
    }

    @ViewBuilder private var hostKeyPrompt: some View {
        VStack(alignment: .leading, spacing: 5) {
            if devices.loadingHostKeys {
                Text("Reading the host key…")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textTertiary)
            } else if devices.hostKeys.isEmpty {
                if let error = devices.hostKeyError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Copy the fingerprint command") {
                    devices.copyHostVerificationCommand(for: trimmedPair)
                }
                .buttonStyle(FoxSecondaryButtonStyle(compact: true))
            } else {
                Text("Compare this with the key on Linux before trusting it:")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textSecondary)
                ForEach(devices.hostKeys) { key in
                    Text("\(key.type) \(key.fingerprint)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Button("Trust and pair") {
                        Task {
                            if await devices.trustHost(trimmedPair) { pair() }
                        }
                    }
                    .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                    Button("Copy command") {
                        devices.copyHostVerificationCommand(for: trimmedPair)
                    }
                    .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                }
            }
        }
    }

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(devices.selectedName) is not answering. Wake it, or check that its SSH address still resolves.")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Try again") {
                    guard let address = devices.selected else { return }
                    Task { await devices.select(address) }
                }
                .buttonStyle(FoxPrimaryButtonStyle(compact: true))
                Button("Check connection") {
                    workbench()
                    Task { await devices.diagnose() }
                }
                .buttonStyle(FoxSecondaryButtonStyle(compact: true))
            }
        }
        .padding(10)
        .foxCard(raised: false)
    }

    private var sendRow: some View {
        HStack(spacing: 6) {
            Button { devices.chooseFile() } label: {
                Label("Send file…", systemImage: "arrow.up.doc")
            }
            .buttonStyle(FoxSecondaryButtonStyle())
            .disabled(devices.running != nil || reachability.isUnreachable)
            destinationMenu
            Spacer(minLength: 0)
        }
    }

    private var destinationMenu: some View {
        Menu {
            ForEach(devices.volumes) { disk in
                Button {
                    devices.setSendVolume(disk.id)
                } label: {
                    if disk.id == devices.sendVolume {
                        Label(disk.name, systemImage: "checkmark")
                    } else {
                        Text(disk.name)
                    }
                }
            }
            Divider()
            Button("Send a link…") {
                enteringLink = true
                linkFocused = true
            }
            Button("Choose receive folder…") { devices.chooseReceiveFolder() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                Text(devices.volumeName(devices.sendVolume)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(palette.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.border))
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Where this lands on Linux")
        .accessibilityLabel("Destination, \(devices.volumeName(devices.sendVolume))")
    }

    private var linkRow: some View {
        HStack(spacing: 6) {
            TextField("https://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .focused($linkFocused)
                .accessibilityLabel("Link to open on Linux")
                .onSubmit(sendLink)
            Button("Open", action: sendLink)
                .buttonStyle(FoxPrimaryButtonStyle(compact: true))
                .disabled(FileHandoff.browserURL(link.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
        }
    }

    @ViewBuilder private var lastProject: some View {
        if let address = devices.selected, let project = devices.lastProjects[address] {
            Button {
                Task { await devices.open(project) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(palette.textSecondary)
                    Text("Open \(project.name)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.textTertiary)
                }
                .padding(9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foxCard(radius: 10)
            .disabled(devices.running != nil)
        }
    }

    @ViewBuilder private var agentRow: some View {
        if devices.agents.isEmpty {
            Label("No agent sessions on Linux", systemImage: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(devices.agents.prefix(3)) { agent in
                    HStack(spacing: 6) {
                        Circle().fill(palette.success).frame(width: 5, height: 5)
                        Text(agent.agent)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                        Text(agent.session)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
                if devices.agents.count > 3 {
                    Text("+\(devices.agents.count - 3) more")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            .padding(9)
            .foxCard(raised: false, radius: 10)
        }
    }

    @ViewBuilder private var jobActivity: some View {
        if jobsReachable == true, let job = devices.jobs.first(where: { $0.state.isActive }) ?? devices.jobs.first {
            Button {
                let host = devices.selected
                workbench()
                Task {
                    if host == devices.selected { await devices.inspectJob(job) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: job.state.isActive ? "hourglass" :
                            job.state == .succeeded ? "checkmark.circle" :
                            job.state == .failed ? "exclamationmark.circle" : "minus.circle")
                        .foregroundStyle(job.state == .failed ? palette.warning : palette.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).lineLimit(1).foregroundStyle(palette.textPrimary)
                        Text(job.state.label).font(.system(size: 10)).foregroundStyle(palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.textTertiary)
                }
                .padding(9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foxCard(raised: false, radius: 10)
            .help("Open this job in Handoff Fox")
        } else {
            Label(jobsReachable == nil ? "Checking Linux jobs…" :
                    jobsReachable == true ? "No recent Linux jobs" : "Linux job status unavailable",
                  systemImage: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("All controls", action: workbench)
                .buttonStyle(FoxSecondaryButtonStyle(compact: true))
            Spacer(minLength: 0)
            if devices.selected != nil, case .unreachable = reachability,
               let seen = devices.lastSeen[devices.selected ?? ""] {
                Text("Last seen \(seen.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    private func pair() {
        guard PeerClient.validAddress(trimmedPair), !pairing else { return }
        pairing = true
        Task {
            await devices.pair(trimmedPair)
            pairing = false
            if devices.pairingError == nil {
                pairingAddress = ""
                pairFocused = false
            }
        }
    }

    private func sendLink() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileHandoff.browserURL(text) != nil else { return }
        Task {
            await devices.openLink(text)
            if devices.error == nil {
                link = ""
                enteringLink = false
            }
        }
    }
}
