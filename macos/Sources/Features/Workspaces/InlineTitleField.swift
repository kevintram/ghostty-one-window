import SwiftUI

/// A title being edited in place: a tab's in the tab strip, or a
/// workspace's in the sidebar. Return saves it, and so does leaving it:
/// clicking elsewhere, or the window losing key status when switching apps,
/// which ends the rename and removes the field. Escape cancels.
struct InlineTitleField: View {
    let placeholder: String
    let end: (_ title: String?) -> Void

    @State private var text: String
    @State private var ended = false
    @FocusState private var isFocused: Bool

    /// - Parameter end: Called once when editing ends, with the edited title
    ///   or nil if it was cancelled.
    init(_ placeholder: String, title: String, end: @escaping (_ title: String?) -> Void) {
        self.placeholder = placeholder
        self.end = end
        _text = State(initialValue: title)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            // Once the update that shows the field has settled: it can replace
            // another field (renaming a tab while renaming a workspace), in
            // another hosting view, whose removal would take the focus back.
            .onAppear { DispatchQueue.main.async { isFocused = true } }
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onChange(of: isFocused) { focused in
                if !focused { finish(text) }
            }
            .onDisappear { finish(text) }
    }

    /// Ends the rename once, however it ends.
    private func finish(_ title: String?) {
        guard !ended else { return }
        ended = true
        end(title)
    }
}
