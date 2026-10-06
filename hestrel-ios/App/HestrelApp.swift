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
                .onOpenURL { url in
                    // `hestrel://pair?code=…` from a bridge's QR code; everything else is Google sign-in.
                    if url.scheme?.lowercased() == "hestrel" {
                        Self.store.send(.openURL(url))
                    } else {
                        GIDSignIn.sharedInstance.handle(url)
                    }
                }
        }
    }
}
