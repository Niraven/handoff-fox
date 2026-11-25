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
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 210),
                                 styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            window.title = "Handoff Fox Quick Actions"
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            let view = NSHostingController(rootView: QuickActions(model: workbenchModel, desktop: desktop,
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
        let needsAttention = warning
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .none
            art.draw(in: NSRect(x: 1, y: lift, width: 18, height: 18))
            if needsAttention {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 14, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        menuItem.button?.image = image
    }
}

struct LinkPanel: View {
    @ObservedObject var model: LinkModel
    @ObservedObject var devices: WorkbenchModel
    @ObservedObject var clipboardSync: ClipboardSync
    @ObservedObject var desktop: RemoteDesktop
    let close: () -> Void
    let workbench: () -> Void
    @AppStorage("foxShowsJobs") private var showsJobs = false
    @State private var hoveringFox = false
    @State private var targetingFile = false
    @State private var celebrating = false
    @State private var celebration: Task<Void, Never>?
    @State private var jobsReachable: Bool?

    private let ink = Color(red: 0.09, green: 0.06, blue: 0.13)
    private let plum = Color(red: 0.16, green: 0.10, blue: 0.23)
    private let mint = Color(red: 0.71, green: 0.92, blue: 0.83)
    private let muted = Color(red: 0.83, green: 0.78, blue: 0.90)
    private let lilac = Color(red: 0.83, green: 0.73, blue: 0.99)
    private let apricot = Color(red: 1.0, green: 0.76, blue: 0.61)

    private var showsInput: Bool {
        model.inputPeerAddress != nil && model.inputPeerAddress == devices.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if devices.selected == nil {
                Button(action: workbench) { primaryLabel("Pair Linux", symbol: "plus") }
                    .buttonStyle(.plain)
            } else {
                OpenDesktopMenu(desktop: desktop, address: devices.selected, accent: lilac)
                HStack(spacing: 6) {
                    Button(action: workbench) { Label("Send & projects", systemImage: "arrow.left.arrow.right") }
                        .help("Open handoff and projects · Control Option J")
                    ClipboardMenu(model: devices, sync: clipboardSync)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(lilac)
                if showsJobs { jobActivity }
                if showsInput { deviceDetails }
            }
            if let feedback = desktop.message ?? devices.error ?? model.message ?? devices.clipboardFeedback ?? devices.notice {
                Text(feedback)
                    .foregroundStyle(desktop.message != nil || devices.error != nil || model.message != nil ? .pink : muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 278, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(LinearGradient(colors: [plum, ink], startPoint: .topTrailing, endPoint: .bottomLeading))
        .preferredColorScheme(.dark)
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
            if showsInput { celebrate() }
        }
        .onChange(of: devices.jobs) { previous, current in
            guard showsJobs else { return }
            let running = Set(previous.filter { $0.state.isActive }.map(\.id))
            if current.contains(where: { $0.state == .succeeded && running.contains($0.id) }) { celebrate() }
        }
        .onDisappear {
            celebration?.cancel()
            celebrating = false
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            FoxCompanion(attentive: hoveringFox || targetingFile, celebrating: celebrating)
                .onHover { hoveringFox = $0 }
            VStack(alignment: .leading, spacing: 2) {
                Text(devices.selected == nil ? "Handoff Fox" : devices.selectedName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let status = showsInput ? model.status : nil {
                    Label(status.connected ? "Input connected" : status.title, systemImage: "circle.fill")
                        .labelStyle(CompactStatusLabel())
                        .foregroundStyle(status.connected ? mint : muted)
                }
                if targetingFile, devices.selected != nil {
                    Text("Drop to send").font(.caption).foregroundStyle(apricot)
                }
            }
            Spacer(minLength: 0)
            if showsInput, let status = model.status {
                let active = status.serverRunning
                icon(active ? "pause.fill" : "play.fill", label: active ? "Pause input" : "Resume input") {
                    Task { await model.setPaused(active) }
                }
                .disabled(model.updating)
            }
            if devices.selected != nil {
                Menu {
                    Toggle("Show Linux jobs", isOn: $showsJobs)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14))
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(lilac)
                .accessibilityLabel("Fox options")
            }
            icon("xmark", label: "Close status", action: close)
        }
        .padding(9)
        .background(lilac.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targetingFile ? apricot : lilac.opacity(0.10)))
        .dropDestination(for: URL.self) { items, _ in devices.acceptFileDrop(items) } isTargeted: { value in
            targetingFile = value && devices.selected != nil && devices.running == nil
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
                        .foregroundStyle(job.state == .failed ? apricot : mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.title).lineLimit(1).foregroundStyle(.white)
                        Text(job.state.label).font(.caption).foregroundStyle(muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(lilac)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(9)
            .background(lilac.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .help("Open this job in Handoff Fox")
        } else {
            Label(jobsReachable == nil ? "Checking Linux jobs…" :
                    jobsReachable == true ? "No recent Linux jobs" : "Linux job status unavailable",
                  systemImage: "terminal")
                .foregroundStyle(muted)
        }
    }

    private func celebrate() {
        celebration?.cancel()
        celebrating = true
        celebration = Task {
            try? await Task.sleep(for: .milliseconds(230))
            if !Task.isCancelled { celebrating = false }
        }
    }

    private var deviceDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                if let free = model.activity?.workspaceFreeGiB {
                    Button {
                        Task { await model.open(.workspace) }
                    } label: {
                        Label("\(free) GiB free", systemImage: "internaldrive").monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .help("Open Workspace on Linux")
                    .accessibilityLabel("Open Workspace. \(free) GiB free.")
                }
                Spacer(minLength: 0)
                Menu("Tools") {
                    Button(model.activity?.hermesActive == true ? "Hermes · Running" : "Open Hermes") {
                        Task { await model.open(.hermes) }
                    }
                    Button(model.activity?.herdrAgents.map { "Herdr · \($0) agents" } ?? "Open Herdr") {
                        Task { await model.open(.herdr) }
                    }
                    if model.activity?.workspaceFreeGiB == nil {
                        Button("Open Workspace") { Task { await model.open(.workspace) } }
                    }
                    Divider()
                    Button("Refresh activity") { Task { await model.loadActivity() } }
                        .disabled(model.activityLoading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let info = model.activity, info.needsAttention {
                Text(info.attentionSummary)
                    .foregroundStyle(apricot)
            }
            if model.status?.connected == true {
                HStack {
                    Text("Return to Mac")
                    Spacer()
                    Text("⌃ ⌥ Esc").monospaced().foregroundStyle(lilac)
                }
                .accessibilityLabel("Return to Mac. Control Option Escape.")
            }
        }
        .foregroundStyle(muted)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(lilac.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(lilac.opacity(0.10)))
    }

    private func primaryLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(lilac, in: RoundedRectangle(cornerRadius: 10))
    }

    private func icon(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 23, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(lilac)
        .help(label).accessibilityLabel(label)
    }
}

private struct CompactStatusLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 5)).accessibilityHidden(true)
            configuration.title.font(.system(size: 11))
        }
    }
}
