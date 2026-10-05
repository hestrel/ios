import SwiftUI

/// The sidebar "hamburger": three left-aligned lines of decreasing length.
///
/// Drawn from svgrepo.com's "menu-alt-1" (a 24×24 grid with 2pt round-capped strokes),
/// so it scales crisply and takes the current foreground style.
struct MenuIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        for (y, endX) in [(6.0, 20.0), (12.0, 14.0), (18.0, 9.0)] {
            path.move(to: point(4, y))
            path.addLine(to: point(endX, y))
        }
        return path.strokedPath(StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round))
    }
}

#Preview {
    MenuIcon()
        .frame(width: 96, height: 96)
}
