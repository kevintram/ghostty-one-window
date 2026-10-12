import AppKit

/// Follows a mouse drag app-wide from the press that began it.
///
/// Pressing a tab or a workspace selects it, which swaps the terminal and
/// can re-render the pressed view, so the pressed view's own gesture can't
/// be relied on to follow the rest of the drag. The tracker follows it with
/// an app-wide event monitor instead.
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

    /// The event's position on screen.
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

/// Slots in a row or column, one of which is being dragged to reorder it:
/// the tab strip's tabs or the sidebar's workspaces. Each slot has its own
/// length, since the strip keeps the selected tab wider and a workspace is as
/// tall as the tabs listed under it. The dragged slot passes another once
/// it's dragged past that slot's middle.
struct ReorderSlots {
    /// Each slot's length, including any gap after it.
    let lengths: [CGFloat]

    var count: Int { lengths.count }

    /// Where the slot at `index` starts, from the start of the first.
    func start(of index: Int) -> CGFloat {
        lengths[..<index].reduce(0, +)
    }

    /// The slot at `position`, from the start of the first, if any.
    func slot(at position: CGFloat) -> Int? {
        guard position >= 0 else { return nil }
        var end: CGFloat = 0
        return lengths.firstIndex { length in
            end += length
            return position < end
        }
    }

    /// Keeps the slot at `index`, dragged by `offset`, within the slots.
    func clamped(_ offset: CGFloat, from index: Int) -> CGFloat {
        let after = lengths[(index + 1)...].reduce(0, +)
        return min(max(offset, -start(of: index)), after)
    }

    /// Where the slot at `index`, dragged by `offset`, would land.
    func destination(from index: Int, offset: CGFloat) -> Int {
        var to = index
        var passed: CGFloat = 0
        if offset > 0 {
            while to + 1 < count, offset > passed + lengths[to + 1] / 2 {
                passed += lengths[to + 1]
                to += 1
            }
        } else {
            while to > 0, -offset > passed + lengths[to - 1] / 2 {
                passed += lengths[to - 1]
                to -= 1
            }
        }
        return to
    }

    /// How far the slot at `index` is drawn from its place while the slot at
    /// `from` is dragged by `offset`: the dragged slot by the drag, and the
    /// slots it has passed by its length toward where it came from.
    func offset(of index: Int, draggingFrom from: Int, by offset: CGFloat) -> CGFloat {
        if index == from { return offset }
        let to = destination(from: from, offset: offset)
        if from < to, (from + 1...to).contains(index) { return -lengths[from] }
        if to < from, (to..<from).contains(index) { return lengths[from] }
        return 0
    }

    /// How far the slot at `from` moves to land in slot `to`.
    func distance(from: Int, to: Int) -> CGFloat {
        if to > from { return lengths[(from + 1)...to].reduce(0, +) }
        return -lengths[to..<from].reduce(0, +)
    }
}
