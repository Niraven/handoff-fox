import AppKit
import SwiftUI

struct FoxCompanion: View {
    let attentive: Bool
    let reaction: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var jumping = false
    @State private var delivered = false
    @State private var landing: Task<Void, Never>?

    private static let resting = NSImage(named: "FoxRest")
    private static let alert = NSImage(named: "FoxAlert")
    private var palette: FoxPalette { FoxPalette(scheme: scheme) }
    private var perked: Bool { hovering || attentive }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let sprite = perked ? Self.alert : Self.resting {
                    Image(nsImage: sprite).resizable().interpolation(.none)
                } else {
                    Image(systemName: "pawprint.fill").foregroundStyle(palette.accent)
                }
            }
            .frame(width: 34, height: 34)
            .rotationEffect(.degrees(!reduceMotion && perked ? -4 : 0))
            .scaleEffect(!reduceMotion && attentive ? 1.05 : 1)
            .offset(y: jumping ? -7 : 0)
            .animation(reduceMotion ? nil : FoxMotion.perk, value: perked)
            .animation(reduceMotion ? nil : FoxMotion.celebrate, value: jumping)

            if jumping && !reduceMotion {
                PixelSpark()
                    .fill(palette.warning)
                    .frame(width: 9, height: 9)
                    .offset(x: jumping ? 4 : 1, y: jumping ? -7 : -2)
                    .opacity(jumping ? 1 : 0)
                    .animation(reduceMotion ? nil : FoxMotion.fade, value: jumping)
            }
            if delivered {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.success)
                    .background(Circle().fill(palette.raisedBottom).padding(-1.5))
                    .scaleEffect(delivered ? 1 : 0.5)
                    .offset(x: 2, y: -2)
                    .animation(reduceMotion ? nil : FoxMotion.celebrate, value: delivered)
                    .transition(.opacity)
            }
        }
        .frame(width: 38, height: 38)
        .background(
            LinearGradient(colors: [palette.raisedTop, palette.sunken],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: reaction) { _, _ in
            celebrate()
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

    /// A delivered handoff gets a lift and a spark, or just the badge when motion is reduced.
    private func celebrate() {
        landing?.cancel()
        delivered = true
        if !reduceMotion { jumping = true }
        landing = Task {
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled { jumping = false }
            }
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { delivered = false }
        }
    }

    private func settle() {
        landing?.cancel()
        jumping = false
        delivered = false
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
