import SwiftUI

/// A brand logo on a white rounded tile, so colored logos read well in light and dark mode.
struct LogoTile: View {
    let image: Image
    var size: CGFloat = 32

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .background(.white, in: .rect(cornerRadius: size / 4))
            .overlay { RoundedRectangle(cornerRadius: size / 4).strokeBorder(Color.hairline) }
            .accessibilityHidden(true)
    }
}
