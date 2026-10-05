import SwiftUI
import UIKit

/// Monochrome design tokens. Everything is black on white in light mode and white on black in dark mode.
enum Theme {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let bubble: CGFloat = 20
        static let composer: CGFloat = 26
    }

    /// Readable line length for chat content on wide screens.
    static let maxContentWidth: CGFloat = 760
}

extension Color {
    static let surface = Color(.secondarySystemBackground)
    static let fill = Color(.secondarySystemFill)
    static let subtleFill = Color(.tertiarySystemFill)
    static let hairline = Color(.separator)

    /// Toggles can't use the app's black/white tint: a white track hides the white knob in dark mode.
    static let toggleTint = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray : .black
    })
}
