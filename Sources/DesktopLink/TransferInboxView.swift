import SwiftUI

struct TransferInboxView: View {
    @ObservedObject var inbox: HandoffInbox
    let address: String?
    @State private var discardCandidate: HandoffTransfer?

    private var transfers: [HandoffTransfer] {
        inbox.records.filter { address == nil || $0.address == address }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let problem = inbox.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                if transfers.isEmpty {
                    Text("Files and links you send or receive appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(transfers) { transfer in
                    row(transfer)
                }
            }
            .font(.callout)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Transfer Inbox", systemImage: "tray")
                .font(.headline)
        }
        .accessibilityIdentifier("transfer-inbox")
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
        HStack(alignment: .top) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.title).fontWeight(.medium)
                    Text(transfer.status.label)
                        .foregroundStyle(.secondary)
                    Text(transfer.destination)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    if let error = transfer.error {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: transfer.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(transfer.direction == .incoming ? "Received" : "Sent")
            }
            Spacer()
            if transfer.status == .retry || transfer.status == .queued {
                Button("Retry") { Task { await inbox.retry(transfer) } }
                if transfer.direction == .outgoing {
                    Button("Discard…") { discardCandidate = transfer }
                }
            } else if transfer.status == .delivered, transfer.item.kind == "file" {
                Button("Show in Folder") { Task { await inbox.reveal(transfer) } }
            }
        }
    }
}
