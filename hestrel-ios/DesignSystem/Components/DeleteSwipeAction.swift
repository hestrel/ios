import SwiftUI

extension View {
    /// A red swipe-to-delete action for list rows.
    ///
    /// Deliberately not `role: .destructive`: that makes the List animate the row away at once, but
    /// deletions here wait for a confirmation alert, and the List then crashes ("invalid number of
    /// items in section") when the data catches up. The red comes from an explicit tint, because the
    /// app's black/white tint would make the button white-on-white in dark mode.
    func deleteSwipeAction(_ action: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", action: action)
                .tint(.red)
        }
    }
}
