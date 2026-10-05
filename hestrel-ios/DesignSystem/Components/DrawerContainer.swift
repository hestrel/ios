import SwiftUI
import UIKit

/// A ChatGPT-style navigation drawer: the content slides aside to reveal the drawer underneath.
struct DrawerContainer<Drawer: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var drawer: Drawer
    @ViewBuilder var content: Content

    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var dragTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = min(proxy.size.width - 64, 400)
            let offset = min(max((isOpen ? drawerWidth : 0) + dragTranslation, 0), drawerWidth)
            let progress = offset / drawerWidth

            ZStack(alignment: .leading) {
                drawer
                    .frame(width: drawerWidth)
                    .offset(x: (progress - 1) * drawerWidth * 0.25)

                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color(.systemBackground))
                    .overlay {
                        Color.black
                            .opacity(0.25 * progress)
                            .ignoresSafeArea()
                            .contentShape(.rect)
                            .allowsHitTesting(isOpen)
                            .onTapGesture { isOpen = false }
                    }
                    .shadow(color: .black.opacity(0.15 * progress), radius: 16)
                    .offset(x: offset)
                    .simultaneousGesture(dragGesture(drawerWidth: drawerWidth))
            }
        }
        .animation(.snappy(duration: 0.3), value: isOpen)
        .onChange(of: isOpen) { _, isOpen in
            if isOpen { dismissKeyboard() }
        }
    }

    /// How far from the left edge a drag must start to open the drawer, like the system back swipe.
    private var openEdgeWidth: CGFloat { 30 }

    /// Opening only tracks drags that start at the left edge, so horizontal swipes elsewhere
    /// (code blocks, tables) scroll normally. Closing works from anywhere on the content.
    private func tracks(_ value: DragGesture.Value) -> Bool {
        value.isHorizontal && (isOpen || value.startLocation.x <= openEdgeWidth)
    }

    private func dragGesture(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($dragTranslation) { value, translation, _ in
                guard tracks(value) else { return }
                translation = value.translation.width
            }
            .onEnded { value in
                guard tracks(value) else { return }
                let projectedOffset = (isOpen ? drawerWidth : 0) + value.predictedEndTranslation.width
                isOpen = projectedOffset > drawerWidth / 2
            }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private extension DragGesture.Value {
    var isHorizontal: Bool {
        abs(translation.width) > abs(translation.height) * 1.5
    }
}
