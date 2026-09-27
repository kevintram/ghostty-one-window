import AppKit

/// Follows a mouse drag app-wide from the press that began it.
///
/// Pressing a tab or a workspace selects it, which shows another tab window
/// (each tab is its own window), so the rest of the drag may be delivered to
/// either window and the pressed view's own gesture can't follow it. The
/// tracker follows it with an app-wide event monitor instead.
///
/// One drag is followed at a time. It's cancelled when another drag begins,
/// when another press arrives before its release (the release was never
/// seen, e.g. consumed by a nested tracking loop), or when the app
/// deactivates (releasing in another app never reaches us).
@MainActor
enum PressDragTracker {
    private static var monitor: Any?
    private static var resignObserver: NSObjectProtocol?
    private static var onCancel: (() -> Void)?

    /// Begins following the drag that `press` began. Translations are from
    /// the press, with y pointing down as in SwiftUI.
    ///
    /// - Parameters:
    ///   - moved: Called for each drag event. Returning false stops following
    ///     the drag and swallows the event, e.g. when the drag is handed off
    ///     to a system drag. `cancelled` isn't called then, so the caller
    ///     cleans up whatever it needs to.
    ///   - released: Called on release.
    ///   - cancelled: Called if the drag ends without a release.
    static func begin(
        from press: NSEvent,
        moved: @escaping (_ event: NSEvent, _ translation: CGSize) -> Bool,
        released: @escaping (_ translation: CGSize) -> Void,
        cancelled: @escaping () -> Void
    ) {
        cancel()
        onCancel = cancelled

        // Added while handling the press, so it only sees what follows.
        let start = screenPoint(of: press)
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { event in
            let point = screenPoint(of: event)
            let translation = CGSize(width: point.x - start.x, height: start.y - point.y)

            switch event.type {
            case .leftMouseDragged:
                guard moved(event, translation) else {
                    stop()
                    return nil
                }

            case .leftMouseUp:
                stop()
                released(translation)

            default:
                cancel()
            }
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { cancel() }
        }
    }

    /// The event's position on screen, comparable across the tab windows a
    /// drag may be delivered to.
    static func screenPoint(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private static func cancel() {
        let cancelled = onCancel
        stop()
        cancelled?()
    }

    private static func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        onCancel = nil
    }
}

/// Equally spaced slots in a row or column, one of which is being dragged to
/// reorder it: the tab strip's tabs or the sidebar's workspaces. The dragged
/// slot may be a different size from the others (the tab strip keeps the
/// selected tab wider).
struct ReorderSlots {
    let count: Int

    /// The distance between adjacent slots other than the dragged one.
    let stride: CGFloat

    /// The distance the dragged slot takes up, which the slots it passes
    /// move by.
    let draggedStride: CGFloat

    init(count: Int, stride: CGFloat, draggedStride: CGFloat? = nil) {
        self.count = count
        self.stride = stride
        self.draggedStride = draggedStride ?? stride
    }

    /// Keeps the slot at `index`, dragged by `offset`, within the slots.
    func clamped(_ offset: CGFloat, from index: Int) -> CGFloat {
        min(max(offset, -CGFloat(index) * stride), CGFloat(count - 1 - index) * stride)
    }

    /// Where the slot at `index`, dragged by `offset`, would land.
    func destination(from index: Int, offset: CGFloat) -> Int {
        guard stride > 0 else { return index }
        return min(max(index + Int((offset / stride).rounded()), 0), count - 1)
    }

    /// How far the slot at `index` is drawn from its place while the slot at
    /// `from` is dragged by `offset`: the dragged slot by the drag, and the
    /// slots it has passed by one slot toward where it came from.
    func offset(of index: Int, draggingFrom from: Int, by offset: CGFloat) -> CGFloat {
        if index == from { return offset }
        let to = destination(from: from, offset: offset)
        if from < to, (from + 1...to).contains(index) { return -draggedStride }
        if to < from, (to..<from).contains(index) { return draggedStride }
        return 0
    }
}
