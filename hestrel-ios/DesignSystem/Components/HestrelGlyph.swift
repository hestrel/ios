import SwiftUI

/// The Hestrel "H" mark, drawn from `hestrel-glyph.svg` (a 1024×1024 viewBox with 96pt strokes).
/// Being a shape, it scales crisply and takes the current foreground style.
///
/// The shape fits the glyph itself rather than the SVG's padded canvas, so its frame is its visible size.
struct HestrelGlyph: Shape {
    /// The glyph's extent in SVG units: the bars sit at x 330 and 694 with 96-unit strokes, from y 248 to 776.
    private static let bounds = CGRect(x: 282, y: 248, width: 460, height: 528)

    func path(in rect: CGRect) -> Path {
        let bounds = Self.bounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let origin = CGPoint(
            x: rect.midX - bounds.midX * scale,
            y: rect.midY - bounds.midY * scale
        )
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        path.move(to: point(330, 248))
        path.addLine(to: point(330, 776))
        path.move(to: point(694, 248))
        path.addLine(to: point(694, 776))
        path.move(to: point(330, 604))
        path.addLine(to: point(512, 458))
        path.addLine(to: point(694, 604))

        return path.strokedPath(StrokeStyle(lineWidth: 96 * scale, lineJoin: .miter, miterLimit: 10))
    }
}

#Preview {
    HestrelGlyph()
        .frame(width: 120, height: 120)
}
