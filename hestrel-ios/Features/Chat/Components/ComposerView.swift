import ComposableArchitecture
import PhotosUI
import SwiftUI

/// Claude-style prompt box: text on top, then attachments, tools and model selection along the bottom.
struct ComposerView: View {
    @Bindable var store: StoreOf<ChatFeature>
    var isFocused: FocusState<Bool>.Binding

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if !store.draftAttachments.isEmpty || store.isProcessingAttachments {
                attachmentStrip
            }

            TextField(store.kind == .code ? "Describe what to build" : "Chat with Hestrel", text: $store.draft, axis: .vertical)
                .lineLimit(1...8)
                .focused(isFocused)
                .padding(.horizontal, Theme.Spacing.xSmall)

            HStack(spacing: Theme.Spacing.small) {
                attachMenu
                Spacer(minLength: 0)
                modelMenu
                sendButton
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.small)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.composer))
        .frame(maxWidth: Theme.maxContentWidth)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.small)
        .sheet(isPresented: $store.isModelPickerPresented, onDismiss: { store.send(.modelPickerDismissed) }) {
            ModelSelectionView(store: store)
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $pickedPhotos,
            maxSelectionCount: 5,
            matching: .images
        )
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task {
                var images: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        images.append(data)
                    }
                }
                store.send(.imagesPicked(images))
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { store.send(.imagesPicked([$0])) }
                .ignoresSafeArea()
        }
    }

    // MARK: Attachments

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(store.draftAttachments) { attachment in
                    AttachmentThumbnail(attachment: attachment)
                        .overlay(alignment: .topTrailing) {
                            Button("Remove", systemImage: "xmark") {
                                store.send(.attachmentRemoved(attachment.id))
                            }
                            .labelStyle(.iconOnly)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.black.opacity(0.6), in: .circle)
                            .padding(4)
                        }
                }
                if store.isProcessingAttachments {
                    ProgressView()
                        .frame(width: 64, height: 64)
                        .background(Color.fill, in: .rect(cornerRadius: Theme.Radius.small))
                }
            }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") {
                isPhotoPickerPresented = true
            }
            if CameraPicker.isAvailable {
                Button("Camera", systemImage: "camera") {
                    isCameraPresented = true
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .frame(width: 34, height: 34)
                .background(Color.fill, in: .circle)
        }
        .accessibilityLabel("Add attachment")
    }

    // MARK: Model

    private var modelMenu: some View {
        Button {
            isFocused.wrappedValue = false
            store.send(.modelPickerTapped)
        } label: {
            HStack(spacing: 4) {
                Text(store.selectedModel?.displayName ?? "No model")
                    .lineLimit(1)
                if store.selectedModel != nil, store.effectiveEffort != .auto {
                    Text("· \(store.effectiveEffort.title)")
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.small)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel("Choose model")
        .accessibilityValue(store.selectedModel.map { model in
            store.effectiveEffort == .auto ? model.displayName : "\(model.displayName), \(store.effectiveEffort.title) effort"
        } ?? "No model selected")
    }

    // MARK: Send

    /// Explicit colors: adaptive ones like `.primary` don't resolve reliably inside glass.
    private var sendButton: some View {
        let isEnabled = store.isStreaming || store.canSend
        let isDark = colorScheme == .dark
        let foreground: Color = isEnabled ? (isDark ? .black : .white) : (isDark ? .white.opacity(0.35) : .black.opacity(0.3))
        let background: Color = isEnabled ? (isDark ? .white : .black) : (isDark ? .white.opacity(0.12) : .black.opacity(0.08))

        return Button {
            store.send(store.isStreaming ? .stopTapped : .sendTapped)
        } label: {
            Image(systemName: store.isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: store.isStreaming ? 13 : 16, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 34, height: 34)
                .background(background, in: .circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(!isEnabled)
        .animation(.snappy, value: isEnabled)
        .accessibilityLabel(store.isStreaming ? "Stop generating" : "Send")
    }
}
