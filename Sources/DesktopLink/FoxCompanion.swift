import SwiftUI

struct FoxCompanion: View {
    let attentive: Bool
    let celebrating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let fur = Color(red: 0.98, green: 0.63, blue: 0.39)
    private let cream = Color(red: 1, green: 0.87, blue: 0.73)
    private let dark = Color(red: 0.23, green: 0.12, blue: 0.20)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                let scale = size.width / 44
                func shape(_ draw: (inout Path) -> Void, color: Color) {
                    var path = Path()
                    draw(&path)
                    context.fill(path.applying(.init(scaleX: scale, y: scale)), with: .color(color))
                }
                shape({ path in
                    path.move(to: CGPoint(x: 7, y: 23))
                    path.addQuadCurve(to: CGPoint(x: 6, y: 8), control: CGPoint(x: 4, y: 16))
                    path.addQuadCurve(to: CGPoint(x: 18, y: 16), control: CGPoint(x: 12, y: 8))
                    path.addQuadCurve(to: CGPoint(x: 26, y: 16), control: CGPoint(x: 22, y: 15))
                    path.addQuadCurve(to: CGPoint(x: 38, y: 8), control: CGPoint(x: 32, y: 8))
                    path.addQuadCurve(to: CGPoint(x: 37, y: 23), control: CGPoint(x: 40, y: 16))
                    path.addQuadCurve(to: CGPoint(x: 22, y: 37), control: CGPoint(x: 39, y: 33))
                    path.addQuadCurve(to: CGPoint(x: 7, y: 23), control: CGPoint(x: 5, y: 33))
                    path.closeSubpath()
                }, color: fur)
                shape({ path in
                    path.addLines([CGPoint(x: 9, y: 12), CGPoint(x: 15, y: 17), CGPoint(x: 10, y: 20)])
                    path.closeSubpath()
                    path.addLines([CGPoint(x: 35, y: 12), CGPoint(x: 34, y: 20), CGPoint(x: 29, y: 17)])
                    path.closeSubpath()
                }, color: dark.opacity(0.50))
                shape({ path in
                    path.move(to: CGPoint(x: 7, y: 26))
                    path.addQuadCurve(to: CGPoint(x: 22, y: 30), control: CGPoint(x: 14, y: 23))
                    path.addQuadCurve(to: CGPoint(x: 37, y: 26), control: CGPoint(x: 30, y: 23))
                    path.addQuadCurve(to: CGPoint(x: 22, y: 37), control: CGPoint(x: 34, y: 35))
                    path.addQuadCurve(to: CGPoint(x: 7, y: 26), control: CGPoint(x: 10, y: 35))
                    path.closeSubpath()
                }, color: cream)
                shape({ path in
                    let height: CGFloat = attentive ? 5 : 3
                    let eyes: [CGFloat] = [14, 27]
                    for x in eyes {
                        path.addEllipse(in: CGRect(x: x, y: 25 - height / 2, width: 3, height: height))
                    }
                    path.addRoundedRect(in: CGRect(x: 20, y: 30, width: 4, height: 3),
                                        cornerSize: CGSize(width: 1.5, height: 1.5))
                }, color: dark)
            }
            .offset(y: reduceMotion || !celebrating ? 0 : -3)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.53), value: celebrating)

            if celebrating {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(cream)
                    .padding(3)
            }
        }
        .frame(width: 44, height: 44)
        .background(fur.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityHidden(true)
    }
}
