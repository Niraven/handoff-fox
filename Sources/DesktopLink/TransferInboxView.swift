import AppKit
import SwiftUI

struct TransferInboxView: View {
    @ObservedObject var inbox: HandoffInbox
    let address: String?
    @State private var discardCandidate: HandoffTransfer?
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    private var transfers: [HandoffTransfer] {
        inbox.records.filter { address == nil || $0.address == address }
    }

    private var unfinished: Int {
        transfers.filter { $0.status == .queued || $0.status == .sending || $0.status == .retry }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray").foregroundStyle(palette.textSecondary)
                    Text("Transfer inbox")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    if !transfers.isEmpty {
                        Text("\(transfers.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(palette.raised, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transfer inbox, \(transfers.count) items")
            .accessibilityIdentifier("transfer-inbox")

            if expanded {
                if let problem = inbox.problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if transfers.isEmpty {
                    Text("Files and links you send or receive appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
                ForEach(transfers) { transfer in
                    row(transfer)
                }
            }
        }
        .onAppear { if unfinished > 0 { expanded = true } }
        .onChange(of: unfinished) { _, count in
            if count > 0 { expanded = true }
        }
        .confirmationDialog("Discard the local transfer?", isPresented: Binding(
            get: { discardCandidate != nil },
            set: { if !$0 { discardCandidate = nil } }
        ), presenting: discardCandidate) { transfer in
            Button("Discard Local Transfer", role: .destructive) { inbox.discard(transfer) }
        } message: { _ in
            Text("The original and any copy already received on Linux will stay.")
        }
    }

    private func row(_ transfer: HandoffTransfer) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: transfer.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(palette.textTertiary)
                .accessibilityLabel(transfer.direction == .incoming ? "Received" : "Sent")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transfer.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    pill(transfer)
                }
                Text(transfer.destination)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(palette.textTertiary)
                if let error = transfer.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            actions(transfer)
        }
        .padding(8)
        .foxCard(raised: false, radius: 9)
    }

    @ViewBuilder
    private func actions(_ transfer: HandoffTransfer) -> some View {
        HStack(spacing: 6) {
            if transfer.status == .retry || transfer.status == .queued {
                Button("Retry") { Task { await inbox.retry(transfer) } }
                    .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                    .disabled(transfer.direction == .incoming)
                if transfer.direction == .outgoing {
                    Button("Discard") { discardCandidate = transfer }
                        .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                }
            } else if transfer.status == .delivered {
                if transfer.direction == .incoming, let path = transfer.path {
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                } else if transfer.item.kind == "file" {
                    Button("Show on Linux") { Task { await inbox.reveal(transfer) } }
                        .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                }
            }
        }
    }

    private func pill(_ transfer: HandoffTransfer) -> some View {
        let tone: Color
        switch transfer.status {
        case .queued: tone = palette.textSecondary
        case .sending: tone = palette.accent
        case .delivered: tone = palette.success
        case .retry: tone = palette.warning
        }
        return Text(transfer.status == .sending ? "Sending…" : transfer.status.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(tone.opacity(0.13), in: Capsule())
    }
}
