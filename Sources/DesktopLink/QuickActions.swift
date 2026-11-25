import SwiftUI

struct QuickActions: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var desktop: RemoteDesktop
    let close: () -> Void
    let workbench: () -> Void

    @State private var link = ""
    @State private var enteringLink = false
    @FocusState private var linkFocused: Bool

    private var desktopPeer: String? {
        if let last = desktop.lastHost, model.peers.contains(where: { $0.address == last }) { return last }
        return model.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let target = model.selected {
                    Text(model.deviceName(target)).font(.headline)
                } else {
                    Text("Pair a Linux device").font(.headline)
                }
                Spacer()
                Button(model.selected == nil ? "Pair…" : "All controls", action: workbench)
            }
            if let target = model.selected {
                if let desktopPeer {
                    Button {
                        close()
                        Task { await desktop.showOrOpen(host: desktopPeer) }
                    } label: {
                        Label("Resume Desktop on \(model.deviceName(desktopPeer))", systemImage: "display")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(desktop.opening)
                }
                HStack {
                    Button("Send file…") { model.chooseFile() }
                    Button("Send link…") { enteringLink = true; linkFocused = true }
                    Menu {
                        Button("Send screenshot…") { model.chooseFile(imagesOnly: true) }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel("More send options")
                    }
                    .fixedSize()
                }
                .disabled(model.running != nil)
                if enteringLink {
                    HStack {
                        TextField("https://…", text: $link)
                            .accessibilityLabel("Link to open on Linux")
                            .focused($linkFocused)
                            .onSubmit { sendLink(to: target) }
                        Button("Send") { sendLink(to: target) }
                            .disabled(model.running != nil || FileHandoff.browserURL(cleanLink) == nil)
                    }
                }
                if let project = model.lastProjects[target] {
                    Button {
                        Task { await model.open(project, on: target) }
                    } label: {
                        Label(project.name, systemImage: "folder")
                            .lineLimit(1)
                    }
                    .accessibilityLabel("Open last project, \(project.name) on \(model.deviceName(target))")
                    .help("Open the last project on \(model.deviceName(target))")
                    .disabled(model.running != nil)
                } else {
                    Button("Choose a saved project…", action: workbench).buttonStyle(.link)
                }
            }
            if let detail = model.error ?? desktop.message ?? model.notice {
                Text(detail).font(.caption).foregroundStyle(model.error != nil || desktop.message != nil ? Color.orange : .secondary)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: close)
        .task(id: model.selected) {
            if let target = model.selected { await model.loadSelectedIfNeeded(target) }
        }
    }

    private var cleanLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendLink(to target: String) {
        guard FileHandoff.browserURL(cleanLink) != nil else { return }
        let address = cleanLink
        Task {
            guard model.running == nil else { return }
            await model.openLink(address, to: target)
            if model.error == nil {
                link = ""
                enteringLink = false
            }
        }
    }
}
