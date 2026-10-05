import ComposableArchitecture
import SwiftUI
import GoogleSignIn

@main
struct HestrelApp: App {
    @MainActor static let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    var body: some Scene {
        WindowGroup {
            AppView(store: Self.store)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}
