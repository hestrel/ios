import SwiftUI

/// The signed-in account's initial, or a person glyph when signed out.
struct AccountAvatar: View {
    let email: String?
    /// The diameter; `nil` lets a containing button (such as a glass one) size and shape it.
    var size: CGFloat? = 44

    var body: some View {
        Group {
            if let initial = email?.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(initial).uppercased())
                    .fontWeight(.semibold)
            } else {
                // Inside Text the symbol takes a full line's height, so in a button it matches text buttons.
                Text(Image(systemName: "person.fill"))
            }
        }
        // Inside a button the standard control font applies; standalone it uses the headline size.
        .font(size == nil ? nil : .headline)
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
        .background {
            if size != nil { Circle().fill(Color.fill) }
        }
        .accessibilityHidden(true)
    }
}
