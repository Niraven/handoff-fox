import AppKit
import SwiftUI

struct FoxCompanion: View {
    let attentive: Bool
    let reaction: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var jumping = false
    @State private var landing: Task<Void, Never>?

    private static let resting = NSImage(named: "FoxRest")
    private static let alert = NSImage(named: "FoxAlert")
    private var perked: Bool { hovering || attentive }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let sprite = perked ? Self.alert : Self.resting {
                    Image(nsImage: sprite).resizable().interpolation(.none)
                } else {
                    Image(systemName: "pawprint.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: 44, height: 44)
            .rotationEffect(.degrees(!reduceMotion && perked ? -5 : 0))
            .offset(y: jumping ? -4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: perked)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.11), value: jumping)

            if jumping {
                PixelSpark()
                    .fill(Color(red: 1, green: 0.91, blue: 0.68))
                    .frame(width: 10, height: 10)
                    .offset(x: 3, y: -2)
            }
        }
        .frame(width: 44, height: 44)
        .background(Color(red: 0.18, green: 0.12, blue: 0.23), in: RoundedRectangle(cornerRadius: 11))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: reaction) { _, _ in
            guard !reduceMotion else { return }
            landing?.cancel()
            jumping = true
            landing = Task {
                try? await Task.sleep(for: .milliseconds(130))
                if !Task.isCancelled { jumping = false }
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { settle() }
        }
        .onDisappear {
            hovering = false
            settle()
        }
        .accessibilityHidden(true)
    }

    private func settle() {
        landing?.cancel()
        jumping = false
    }
}

private struct PixelSpark: Shape {
    func path(in rect: CGRect) -> Path {
        let pixel = rect.width / 5
        var path = Path()
        path.addRect(CGRect(x: 2 * pixel, y: 0, width: pixel, height: rect.height))
        path.addRect(CGRect(x: 0, y: 2 * pixel, width: rect.width, height: pixel))
        return path
    }
}

struct FoxTransferFeedback: View {
    @ObservedObject var inbox: HandoffInbox
    let address: String?
    let device: String
    var busy = false
    @Environment(\.colorScheme) private var scheme

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    var body: some View {
        if let record = inbox.latestOutgoingFile(to: address) {
            HStack(alignment: .center, spacing: 8) {
                if record.status == .queued || record.status == .sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol(for: record.status))
                        .foregroundStyle(record.status == .retry ? palette.warning : palette.success)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(record.status == .delivered ? "Delivered to \(record.destination)"
                                                     : (record.error ?? record.status.label))
                        .font(.system(size: 10))
                        .foregroundStyle(record.status == .retry ? palette.warning : palette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if record.status == .queued || record.status == .retry {
                    Button("Retry") { Task { await inbox.retry(record) } }
                        .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                        .disabled(busy)
                        .accessibilityLabel("Retry \(record.title)")
                } else if record.status == .delivered {
                    Button("Show") { Task { await inbox.reveal(record) } }
                        .buttonStyle(FoxSecondaryButtonStyle(compact: true))
                }
            }
            .padding(8)
            .foxCard(raised: false, radius: 9)
            .accessibilityElement(children: .contain)
        }
    }

    private func symbol(for status: HandoffTransfer.Status) -> String {
        switch status {
        case .queued, .sending: "arrow.up.circle"
        case .delivered: "checkmark.circle"
        case .retry: "exclamationmark.circle"
        }
    }
}
