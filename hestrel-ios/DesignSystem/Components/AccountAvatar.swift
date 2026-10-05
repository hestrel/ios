import SwiftUI

struct AccountAvatar: View {
    let email: String?

    var body: some View {
        ZStack {
            Circle().fill(Color.fill)
            if let initial = email?.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(initial).uppercased())
                    .font(.headline)
            } else {
                Image(systemName: "person.fill")
                    .font(.body.weight(.medium))
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}
