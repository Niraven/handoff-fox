import SwiftUI

/// Colours sampled from the fox sprites, so the interface and the mascot agree:
/// rust `#E87B46`, apricot `#FFA564`, cream `#FFDEA6`, wine `#914554`.
struct FoxPalette {
    let scheme: ColorScheme

    private var dark: Bool { scheme == .dark }

    var accent: Color {
        dark ? Color(red: 0.94, green: 0.54, blue: 0.33) : Color(red: 0.73, green: 0.29, blue: 0.14)
    }
    var onAccent: Color {
        dark ? Color(red: 0.12, green: 0.07, blue: 0.03) : .white
    }
    var raisedTop: Color {
        dark ? Color.white.opacity(0.085) : Color.white
    }
    var raisedBottom: Color {
        dark ? Color.white.opacity(0.025) : Color(red: 0.98, green: 0.965, blue: 0.95)
    }
    var sunken: Color {
        dark ? Color.black.opacity(0.24) : Color(red: 0.965, green: 0.95, blue: 0.937)
    }
    var border: Color {
        dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }
    var borderStrong: Color {
        dark ? Color.white.opacity(0.16) : Color.black.opacity(0.13)
    }
    var shadow: Color {
        dark ? Color.black.opacity(0.34) : Color.black.opacity(0.07)
    }
    var textPrimary: Color {
        dark ? Color(red: 0.96, green: 0.93, blue: 0.91) : Color(red: 0.12, green: 0.09, blue: 0.08)
    }
    var textSecondary: Color {
        dark ? Color(red: 0.78, green: 0.72, blue: 0.68) : Color(red: 0.36, green: 0.31, blue: 0.29)
    }
    var textTertiary: Color {
        dark ? Color(red: 0.58, green: 0.52, blue: 0.49) : Color(red: 0.54, green: 0.49, blue: 0.46)
    }
    var success: Color {
        dark ? Color(red: 0.44, green: 0.83, blue: 0.64) : Color(red: 0.10, green: 0.50, blue: 0.33)
    }
    var warning: Color {
        dark ? Color(red: 0.94, green: 0.71, blue: 0.36) : Color(red: 0.66, green: 0.38, blue: 0.10)
    }
    var danger: Color {
        dark ? Color(red: 0.94, green: 0.54, blue: 0.50) : Color(red: 0.70, green: 0.21, blue: 0.18)
    }
}

extension View {
    func foxCard(raised: Bool = true, radius: CGFloat = 11) -> some View {
        modifier(FoxCard(raised: raised, radius: radius))
    }
}

/// A card that sits on the surface rather than being painted into it: a shallow
/// vertical gradient, a lit top edge, a hairline border and one soft shadow.
private struct FoxCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let raised: Bool
    let radius: CGFloat

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: raised ? [palette.raisedTop, palette.raisedBottom] : [palette.sunken, palette.sunken],
                        startPoint: .top,
                        endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(
                        colors: [palette.borderStrong, palette.border],
                        startPoint: .top,
                        endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: palette.shadow, radius: raised ? 5 : 0, x: 0, y: raised ? 2 : 0)
    }
}

struct FoxPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var compact = false

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .foregroundStyle(palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: compact ? 28 : 36)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [palette.accent, palette.accent.opacity(configuration.isPressed ? 0.75 : 0.88)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.onAccent.opacity(0.12))
            )
            .shadow(color: palette.accent.opacity(configuration.isPressed ? 0 : 0.28),
                    radius: 4, x: 0, y: 1)
            .contentShape(Rectangle())
    }
}

struct FoxSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var compact = false

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 8)
            .frame(minHeight: compact ? 24 : 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [palette.raisedTop, palette.raisedBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(configuration.isPressed ? 0.6 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(palette.border)
            )
            .contentShape(Rectangle())
    }
}

struct FoxIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
            .frame(width: 26, height: 26)
            .background(configuration.isPressed ? palette.sunken : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// One motion vocabulary for the whole app: small amplitudes, springs that settle
/// fast, and no animation on anything pressed dozens of times a day.
enum FoxMotion {
    static let perk = Animation.spring(response: 0.24, dampingFraction: 0.72)
    static let celebrate = Animation.spring(response: 0.30, dampingFraction: 0.80)
    static let fade = Animation.easeOut(duration: 0.16)
}

struct FoxChecklist: View {
    @Environment(\.colorScheme) private var scheme
    let steps: [ConnectionCheck.Step]
    var compact = true

    private var palette: FoxPalette { FoxPalette(scheme: scheme) }

    private func symbol(_ state: ConnectionCheck.State) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .actionNeeded: "exclamationmark.circle.fill"
        case .unchecked: "circle.dashed"
        }
    }

    private func tone(_ state: ConnectionCheck.State) -> Color {
        switch state {
        case .ready: palette.success
        case .actionNeeded: palette.warning
        case .unchecked: palette.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(step.state))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tone(step.state))
                    Text(step.name)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Text(step.detail)
                        .font(.system(size: compact ? 9.5 : 10.5))
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
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
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: compact ? 4.5 : 5.5, height: compact ? 4.5 : 5.5)
            Text(reachability.summary)
                .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                .foregroundStyle(label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Linux computer: \(reachability.summary)")
    }
}
