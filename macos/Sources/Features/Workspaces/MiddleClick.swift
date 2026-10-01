import AppKit
import SwiftUI

extension View {
    /// Runs `action` when the middle mouse button is pressed and released
    /// inside the view. Other mouse buttons pass through unchanged.
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        overlay { MiddleClickReceiver(action: action) }
    }
}

/// SwiftUI doesn't expose mouse buttons before macOS 26, so this view uses an
/// AppKit click recognizer. It only participates in hit testing for the middle
/// button, leaving SwiftUI's left-click and context-menu handling unchanged.
private struct MiddleClickReceiver: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickTrackingView {
        let view = MiddleClickTrackingView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MiddleClickTrackingView, context: Context) {
        view.action = action
    }
}

private final class MiddleClickTrackingView: NSView {
    var action: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown,
              event.buttonNumber == 2 else { return nil }
        // `point` is in the superview's coordinates, which this checks.
        return super.hitTest(point)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let click = NSClickGestureRecognizer(target: self, action: #selector(middleClicked))
        // AppKit's button mask uses bit 2 for its middle button, number 2.
        click.buttonMask = 1 << 2
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func middleClicked() {
        action?()
    }
}
