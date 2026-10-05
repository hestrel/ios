import ComposableArchitecture
import Foundation

extension AlertState {
    /// Asks before deleting a conversation; `action` is sent when the user confirms.
    static func confirmDelete(_ conversation: Conversation, action: Action) -> Self {
        AlertState {
            TextState("Delete Chat?")
        } actions: {
            ButtonState(role: .destructive, action: action) {
                TextState("Delete")
            }
            ButtonState(role: .cancel) {
                TextState("Cancel")
            }
        } message: {
            TextState("This will delete “\(conversation.title)”.")
        }
    }
}
