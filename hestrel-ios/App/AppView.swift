import ComposableArchitecture
import SwiftUI

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                drawerLayout
            }
        }
        .tint(.primary)
        .task { await store.send(.task).finish() }
        .task { await store.send(.account(.task)).finish() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.send(.becameActive) }
        }
        .sheet(item: $store.scope(state: \.settings, action: \.settings)) { settingsStore in
            SettingsView(store: settingsStore)
        }
        .sheet(item: $store.scope(state: \.pairing, action: \.pairing)) { pairingStore in
            PairComputerView(store: pairingStore)
        }
    }

    /// iPhone: a ChatGPT-style drawer that slides the chat aside.
    private var drawerLayout: some View {
        DrawerContainer(isOpen: $store.isSidebarOpen) {
            SidebarView(store: store.scope(state: \.sidebar, action: \.sidebar))
        } content: {
            mainStack(showsSidebarButton: true)
        }
    }

    /// iPad: a native split view with a persistent sidebar column.
    private var splitLayout: some View {
        NavigationSplitView {
            SidebarView(store: store.scope(state: \.sidebar, action: \.sidebar))
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            mainStack(showsSidebarButton: false)
        }
    }

    /// The section picked in the sidebar at the root, with detail pages pushed on top.
    private func mainStack(showsSidebarButton: Bool) -> some View {
        NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
            sectionRoot
                .toolbar {
                    if showsSidebarButton {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                store.send(.sidebarButtonTapped)
                            } label: {
                                // Explicit color: glass toolbar buttons dim custom shapes drawn in `.primary`.
                                MenuIcon()
                                    .fill(colorScheme == .dark ? Color.white : Color.black)
                                    .frame(width: 24, height: 24)
                            }
                            .accessibilityLabel("Menu")
                        }
                    }
                }
        } destination: { store in
            switch store.case {
            case let .artifactDetail(store):
                ArtifactDetailView(store: store)
            case let .pluginDetail(store):
                PluginDetailView(store: store)
            }
        }
    }

    @ViewBuilder
    private var sectionRoot: some View {
        switch store.section {
        case .chat:
            ChatView(store: store.scope(state: \.chat, action: \.chat))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Chat", systemImage: "plus") {
                            store.send(.newChatTapped)
                        }
                    }
                }
        case .chats:
            ChatsView(store: store.scope(state: \.chats, action: \.chats))
        case .artifacts:
            ArtifactsView(store: store.scope(state: \.artifacts, action: \.artifacts))
        case .plugins:
            PluginsView(store: store.scope(state: \.plugins, action: \.plugins))
        }
    }
}

#Preview {
    AppView(store: Store(initialState: AppFeature.State()) {
        AppFeature()
    })
}
