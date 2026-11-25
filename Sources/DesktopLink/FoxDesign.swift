import SwiftUI

struct FoxPalette {
    let scheme: ColorScheme

    private var dark: Bool { scheme == .dark }

    var accent: Color {
        dark ? Color(red: 0.82, green: 0.72, blue: 0.99) : Color(red: 0.42, green: 0.25, blue: 0.65)
    }
    var onAccent: Color {
        dark ? Color(red: 0.10, green: 0.07, blue: 0.15) : .white
    }
    var raised: Color {
        dark ? Color.white.opacity(0.07) : Color.black.opacity(0.035)
    }
    var sunken: Color {
        dark ? Color.black.opacity(0.22) : Color.black.opacity(0.045)
    }
    var border: Color {
        dark ? Color.white.opacity(0.13) : Color.black.opacity(0.09)
    }
    var textPrimary: Color {
        dark ? Color(red: 0.96, green: 0.95, blue: 0.98) : Color(red: 0.11, green: 0.09, blue: 0.15)
    }
    var textSecondary: Color {
        dark ? Color(red: 0.76, green: 0.73, blue: 0.83) : Color(red: 0.35, green: 0.33, blue: 0.42)
    }
    var textTertiary: Color {
        dark ? Color(red: 0.58, green: 0.55, blue: 0.66) : Color(red: 0.48, green: 0.46, blue: 0.55)
    }
    var success: Color {
        dark ? Color(red: 0.60, green: 0.90, blue: 0.76) : Color(red: 0.05, green: 0.44, blue: 0.30)
    }
    var warning: Color {
        dark ? Color(red: 1.0, green: 0.79, blue: 0.55) : Color(red: 0.62, green: 0.35, blue: 0.03)
    }
    var danger: Color {
        dark ? Color(red: 1.0, green: 0.64, blue: 0.63) : Color(red: 0.68, green: 0.13, blue: 0.16)
    }
}

extension View {
    func foxCard(raised: Bool = true, radius: CGFloat = 12) -> some View {
        modifier(FoxCard(raised: raised, radius: radius))
    }
}

private struct FoxCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let raised: Bool
    let radius: CGFloat

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    func body(content: Content) -> some View {
        content
            .background(raised ? palette.raised : palette.sunken,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(palette.border))
    }
}

struct FoxPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var compact = false

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: compact ? 30 : 40)
            .padding(.horizontal, 10)
            .background(palette.accent.opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct FoxSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var compact = false

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 9)
            .frame(minHeight: compact ? 24 : 30)
            .background(palette.raised.opacity(configuration.isPressed ? 0.55 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.border))
            .contentShape(Rectangle())
    }
}

struct FoxIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? palette.raised : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}

enum PeerReachability: Equatable {
    case unknown
    case checking
    case reachable
    case unreachable(String)

    var summary: String {
        switch self {
        case .unknown: "Not checked yet"
        case .checking: "Checking…"
        case .reachable: "Connected"
        case .unreachable(let reason): reason
        }
    }

    var isReachable: Bool {
        if case .reachable = self { return true }
        return false
    }

    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}

struct FoxStatusLine: View {
    @Environment(\.colorScheme) private var scheme
    let reachability: PeerReachability
    var compact = false

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    private var dot: Color {
        switch reachability {
        case .unknown, .checking: palette.textTertiary
        case .reachable: palette.success
        case .unreachable: palette.warning
        }
    }

    private var label: Color {
        if case .unreachable = reachability { return palette.warning }
        return palette.textSecondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(reachability.summary)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Linux computer: \(reachability.summary)")
    }
}
