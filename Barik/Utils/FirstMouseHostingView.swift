import SwiftUI

/// Hosting view for Barik's non-activating panels.
///
/// Barik's panels never become key and the app stays inactive, so every click
/// on them is a "window activation" click. Recent macOS releases no longer
/// deliver those clicks to SwiftUI gestures by default, which made widgets
/// (e.g. the window icons in the spaces widget) ignore the first — and in
/// practice every — click. Accepting first mouse and opting the hierarchy into
/// activation events restores click-through behavior.
final class FirstMouseHostingView<Content: View>: NSHostingView<
    FirstMouseHostingView.Root
>
{
    struct Root: View {
        let content: Content

        var body: some View {
            if #available(macOS 15.0, *) {
                content.allowsWindowActivationEvents()
            } else {
                content
            }
        }
    }

    init(rootView: Content) {
        super.init(rootView: Root(content: rootView))
    }

    @MainActor required init(rootView: Root) {
        super.init(rootView: rootView)
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
