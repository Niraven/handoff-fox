import SwiftUI

struct QuickActions: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var desktop: RemoteDesktop
    @ObservedObject var inbox: HandoffInbox
    let close: () -> Void
    let workbench: () -> Void

    @State private var link = ""
    @State private var enteringLink = false
    @State private var targetingFile = false
    @State private var reaction = 0
    @FocusState private var linkFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    private var desktopPeer: String? {
        if let last = desktop.lastHost, model.peers.contains(where: { $0.address == last }) { return last }
        return model.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.selected != nil {
                if let desktopPeer {
                    Button {
                        close()
                        Task { await desktop.showOrOpen(host: desktopPeer) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "display")
                            Text("Resume Desktop")
                            Text("· \(model.deviceName(desktopPeer))")
                                .foregroundStyle(palette.onAccent.opacity(0.7))
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(FoxPrimaryButtonStyle())
                    .disabled(desktop.opening)
                }
                if enteringLink {
                    linkRow
                } else {
                    sendRow
                }
                lastProject
                FoxTransferFeedback(inbox: inbox, address: model.selected, device: model.selectedName,
                                    busy: model.running != nil)
            } else {
                Button("Pair a Linux computer…", action: workbench)
                    .buttonStyle(FoxPrimaryButtonStyle())
            }
            if let detail = model.error ?? desktop.message {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(model.error != nil ? palette.danger : palette.warning)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 350, alignment: .leading)
        .onExitCommand(perform: close)
        .onDisappear {
            targetingFile = false
            enteringLink = false
            link = ""
        }
        .onReceive(inbox.fileDeliveries) { file in
            if inbox.latestOutgoingFile(to: model.selected)?.id == file.id { reaction += 1 }
        }
        .task(id: model.selected) {
            if let target = model.selected { await model.loadSelectedIfNeeded(target) }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            FoxCompanion(attentive: targetingFile, reaction: reaction)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selected.map { model.deviceName($0) } ?? "Pair a Linux device")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let target = model.selected {
                    FoxStatusLine(reachability: model.reachability(for: target), compact: true)
                }
                if targetingFile, let target = model.selected {
                    Text("Drop to send to \(model.deviceName(target))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(model.selected == nil ? "Pair…" : "All controls", action: workbench)
                .buttonStyle(FoxSecondaryButtonStyle(compact: true))
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { items, _ in model.acceptFileDrop(items) } isTargeted: { value in
            targetingFile = value && model.selected != nil && model.running == nil
        }
    }

    private var sendRow: some View {
        HStack(spacing: 6) {
            Button("Send file…") { model.chooseFile() }
                .buttonStyle(FoxSecondaryButtonStyle())
                .disabled(model.running != nil)
            Button("Send link…") {
                enteringLink = true
                linkFocused = true
            }
            .buttonStyle(FoxSecondaryButtonStyle())
            .disabled(model.running != nil)
            Spacer(minLength: 0)
            Menu {
                Button("Send screenshot…") { model.chooseFile(imagesOnly: true) }
                Button("Choose receive folder…") { model.chooseReceiveFolder() }
                Divider()
                if let target = model.selected {
                    Toggle("Receive handoffs from \(model.selectedName)", isOn: Binding(
                        get: { model.receivingPeer == target },
                        set: { model.enableReceiving(from: $0 ? target : nil) }
                    ))
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More send options")
        }
    }

    private var linkRow: some View {
        HStack(spacing: 6) {
            TextField("https://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Link to open on Linux")
                .focused($linkFocused)
                .onSubmit(sendLink)
            Button("Open", action: sendLink)
                .buttonStyle(FoxPrimaryButtonStyle(compact: true))
                .disabled(model.running != nil || FileHandoff.browserURL(cleanLink) == nil)
            Button {
                enteringLink = false
                link = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(FoxIconButtonStyle())
            .accessibilityLabel("Cancel link")
        }
    }

    @ViewBuilder private var lastProject: some View {
        if let target = model.selected, let project = model.lastProjects[target] {
            Button {
                Task { await model.open(project, on: target) }
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
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foxCard(radius: 9)
            .disabled(model.running != nil)
            .accessibilityLabel("Open last project, \(project.name) on \(model.deviceName(target))")
        }
    }

    private var cleanLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendLink() {
        guard FileHandoff.browserURL(cleanLink) != nil else { return }
        let address = cleanLink
        Task {
            guard model.running == nil else { return }
            await model.openLink(address)
            if model.error == nil {
                link = ""
                enteringLink = false
            }
        }
    }
}
