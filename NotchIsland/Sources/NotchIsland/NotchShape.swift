import SwiftUI

/// The single black shape that *is* the island.
/// Top edge sits on the screen edge; `flare` draws the inward-curving "shoulders" that make it
/// look like it grows out of the bezel; `bottomRadius` rounds the two lower corners.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set { flare = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let f = max(0, min(flare, r.height / 2))
        let bodyWidth = max(0, r.width - 2 * f)
        let br = max(0, min(bottomRadius, r.height - f, bodyWidth / 2))

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        // left shoulder
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.minY + f),
                       control: CGPoint(x: r.minX + f, y: r.minY))
        // left side
        p.addLine(to: CGPoint(x: r.minX + f, y: r.maxY - br))
        // bottom-left corner
        p.addCurve(to: CGPoint(x: r.minX + f + br, y: r.maxY),
                   control1: CGPoint(x: r.minX + f, y: r.maxY - br * 0.45),
                   control2: CGPoint(x: r.minX + f + br * 0.45, y: r.maxY))
        // bottom
        p.addLine(to: CGPoint(x: r.maxX - f - br, y: r.maxY))
        // bottom-right corner
        p.addCurve(to: CGPoint(x: r.maxX - f, y: r.maxY - br),
                   control1: CGPoint(x: r.maxX - f - br * 0.45, y: r.maxY),
                   control2: CGPoint(x: r.maxX - f, y: r.maxY - br * 0.45))
        // right side
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + f))
        // right shoulder
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - f, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Content transition: shape moves first, content blurs/fades in ~80 ms later.

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 6 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeOut(duration: 0.26).delay(0.08)),
            removal: AnyTransition.modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeIn(duration: 0.12))
        )
    }
}
