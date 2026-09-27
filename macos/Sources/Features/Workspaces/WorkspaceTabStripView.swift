import Combine
import SwiftUI

/// The tab strip above the terminal. It replaces the native tab bar, which
/// would show the tabs of every workspace since they share one tab group.
///
/// The tabs are still native: each is a window in the logical window's
/// `NSWindowTabGroup`. This only draws the selected workspace's tabs and
/// forwards actions.
struct WorkspaceTabStripView: View {
    @ObservedObject var membership: WorkspaceMembership

    var body: some View {
        if let group = membership.group {
            TabStrip(group: group)
        } else {
            Color.clear
        }
    }
}

private struct TabStrip: View {
    @ObservedObject var group: WorkspaceWindowGroup

    private typealias Drag = WorkspaceWindowGroup.TabDrag

    private var drag: Drag? { group.tabDrag }

    /// The strip's width, which the tabs share equally.
    @State private var width: CGFloat = 0

    private static let spacing: CGFloat = 4
    private static let inset = (WorkspaceWindowGroup.tabStripHeight - 24) / 2
    private static let newTabWidth: CGFloat = 24
    private static let slideDuration = 0.15
    private static let slide = Animation.easeOut(duration: slideDuration)

    var body: some View {
        HStack(spacing: Self.spacing) {
            // A tab dragged out of the strip leaves it until the drag ends.
            ForEach(group.tabs.filter { phase(of: $0) != .draggingOut }) { tab in
                TabButton(tab: tab) {
                    if let window = tab.window { group.selectTab(window) }
                }
                .offset(x: offset(of: tab))
                // The dragged tab tracks the pointer; the others slide.
                .animation(phase(of: tab) == .following ? nil : Self.slide, value: offset(of: tab))
                .zIndex(phase(of: tab) == nil ? 0 : 1)
                .gesture(reorderGesture(for: tab))
            }

            Button {
                NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "plus")
                    .frame(width: Self.newTabWidth, height: 24)
            }
            .buttonStyle(.borderless)
            .help("New Tab")
        }
        // Match the vertical inset: 24pt tabs centered in the strip's height.
        .padding(.horizontal, Self.inset)
        .frame(height: WorkspaceWindowGroup.tabStripHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .onDrop(of: [.ghosttyWorkspaceTab], delegate: self)
    }

    /// The distance between the leading edges of adjacent tabs when the
    /// strip holds `count` tabs. Computed rather than measured, since while a
    /// tab is dragged out the strip holds one fewer.
    private func stride(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let tabs = width - 2 * Self.inset - Self.newTabWidth - CGFloat(count) * Self.spacing
        return max(tabs / CGFloat(count), TabButton.minWidth) + Self.spacing
    }

    // MARK: Reordering

    // Pressing a tab selects it right away, like a native tab, so a click
    // is just a drag that doesn't go anywhere. Dragging moves the tab with
    // the pointer while the tabs it passes slide into its place. The native
    // tab only moves on release.
    //
    // Selecting shows another tab window, so the rest of the drag may be
    // delivered to either window. It's followed with an app-wide event
    // monitor instead, and drawn from the group's shared `tabDrag`.
    //
    // Dragging a tab out of the strip hands off to a system drag, which the
    // sidebar's workspace rows accept (see `WorkspaceTabDragOut`). Dragged
    // back over the strip, the tab rejoins it under the pointer until it's
    // dropped or leaves again.

    private func reorderGesture(for tab: WorkspaceWindowGroup.Tab) -> some Gesture {
        // Only the press matters; the monitor tracks the rest.
        DragGesture(minimumDistance: 0).onChanged { _ in beginDrag(tab) }
    }

    /// Follow the current drag until it's released or cancelled.
    private static var monitor: Any?
    private static var resignObserver: NSObjectProtocol?

    private func beginDrag(_ tab: WorkspaceWindowGroup.Tab) {
        // The gesture also reports every move; only the press begins a drag.
        guard let press = NSApp.currentEvent,
              press.type == .leftMouseDown,
              group.tabDrag == nil || group.tabDrag?.phase == .following,
              let window = tab.window,
              let from = index(of: tab.id) else { return }

        if window.tabGroup?.selectedWindow != window { group.selectTab(window) }
        group.tabDrag = Drag(id: tab.id)

        // The tabs can't change width during the drag, so capture the layout.
        let count = group.tabs.count
        let stride = stride(count: count)
        let start = Self.screenPoint(of: press)
        let host = Self.stripHost(at: press)

        // The monitor only sees events after this press.
        Self.stopTracking()
        Self.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak group, weak window, weak host] event in
            guard let group, let window else {
                Self.stopTracking()
                return event
            }

            // Keep the tab within the strip.
            let point = Self.screenPoint(of: event)
            let offset = min(
                max(point.x - start.x, -CGFloat(from) * stride),
                CGFloat(count - 1 - from) * stride)

            switch event.type {
            case .leftMouseDragged:
                // Pulled out of the strip: drag it on as a system drag.
                if let host, let strip = host.window?.convertToScreen(host.convert(host.bounds, to: nil)),
                   !strip.insetBy(dx: 0, dy: -Self.detachDistance).contains(point) {
                    Self.stopTracking()
                    withAnimation(Self.slide) { group.tabDrag = Drag(id: tab.id, phase: .draggingOut) }
                    WorkspaceTabDragOut.begin(window, in: group, from: host, with: event)
                    return nil
                }

                group.tabDrag = Drag(id: tab.id, offset: offset)

            case .leftMouseUp:
                Self.stopTracking()
                let to = Self.dropIndex(from: from, offset: offset, stride: stride, count: count)
                Self.settle(tab.id, window: window, from: from, to: to, stride: stride, in: group)

            default:
                // Another press means the release was never seen, e.g.
                // consumed by a nested tracking loop. Drop the stale drag.
                Self.cancel(in: group)
            }
            return event
        }

        // Releasing in another app never reaches us.
        Self.resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak group] _ in
            MainActor.assumeIsolated { if let group { Self.cancel(in: group) } }
        }
    }

    private static func stopTracking() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
    }

    /// Ends the drag without moving the tab, so it slides back.
    private static func cancel(in group: WorkspaceWindowGroup) {
        stopTracking()
        group.tabDrag = nil
    }

    /// Settles the dragged tab into its slot, then moves the native tab.
    /// Moving it re-inserts its window in the tab group, which would disrupt
    /// an animation in flight, but by then the strip already looks like the
    /// new order and nothing needs to animate.
    private static func settle(
        _ id: ObjectIdentifier,
        window: NSWindow,
        from: Int,
        to: Int,
        stride: CGFloat,
        in group: WorkspaceWindowGroup
    ) {
        group.tabDrag = Drag(id: id, offset: CGFloat(to - from) * stride, phase: .settling)
        DispatchQueue.main.asyncAfter(deadline: .now() + slideDuration) { [weak group, weak window] in
            guard let group else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let window { group.moveTab(window, to: to) }
                group.tabDrag = nil
            }
        }
    }

    /// How far above or below the strip the pointer can stray before the
    /// tab is dragged out of it.
    private static let detachDistance: CGFloat = 16

    /// The event's position on screen, comparable across the tab windows
    /// the drag may be delivered to.
    private static func screenPoint(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// The hosting view of the strip that was pressed.
    private static func stripHost(at event: NSEvent) -> NSView? {
        guard let frameView = event.window?.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { return nil }
        return sequence(first: hit, next: \.superview).first { $0 is NSHostingView<WorkspaceTabStripView> }
    }

    private func index(of id: ObjectIdentifier) -> Int? {
        group.tabs.firstIndex { $0.id == id }
    }

    /// Where a tab dragged by `offset` from index `from` would land.
    private static func dropIndex(from: Int, offset: CGFloat, stride: CGFloat, count: Int) -> Int {
        guard stride > 0 else { return from }
        return min(max(from + Int((offset / stride).rounded()), 0), count - 1)
    }

    /// How far the tab is drawn from its slot: the dragged tab by the drag,
    /// and the tabs it has passed by one slot toward where it came from.
    private func offset(of tab: WorkspaceWindowGroup.Tab) -> CGFloat {
        guard let drag,
              drag.phase != .draggingOut,
              let from = index(of: drag.id),
              let index = index(of: tab.id) else { return 0 }
        if index == from { return drag.offset }

        let stride = stride(count: group.tabs.count)
        let to = Self.dropIndex(from: from, offset: drag.offset, stride: stride, count: group.tabs.count)
        if from < to, (from + 1...to).contains(index) { return -stride }
        if to < from, (to..<from).contains(index) { return stride }
        return 0
    }

    /// The drag phase of the tab, if it's the one being dragged.
    private func phase(of tab: WorkspaceWindowGroup.Tab) -> Drag.Phase? {
        drag?.id == tab.id ? drag?.phase : nil
    }
}

// MARK: Dragging back in

// Drops only come from a tab dragged out of this group's strip; other
// groups' strips have no drag.
extension TabStrip: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool {
        drag.map { $0.phase != .settling } ?? false
    }

    func dropEntered(info: DropInfo) {
        follow(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        follow(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard let drag, drag.phase == .following else { return }
        withAnimation(Self.slide) { group.tabDrag = Drag(id: drag.id, phase: .draggingOut) }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let drag,
              let from = index(of: drag.id),
              let window = group.tabs[from].window else { return false }
        let count = group.tabs.count
        let stride = stride(count: count)
        let to = Self.dropIndex(from: from, offset: drag.offset, stride: stride, count: count)
        Self.settle(drag.id, window: window, from: from, to: to, stride: stride, in: group)
        return true
    }

    /// Shows the dragged tab in the strip, centered under the pointer.
    private func follow(_ info: DropInfo) {
        guard let drag,
              drag.phase != .settling,
              let from = index(of: drag.id) else { return }
        let count = group.tabs.count
        let stride = stride(count: count)
        let center = Self.inset + CGFloat(from) * stride + (stride - Self.spacing) / 2
        let offset = min(
            max(info.location.x - center, -CGFloat(from) * stride),
            CGFloat(count - 1 - from) * stride)

        // Rejoining the strip makes room for it; following it doesn't animate.
        let following = Drag(id: drag.id, offset: offset)
        if drag.phase == .draggingOut {
            withAnimation(Self.slide) { group.tabDrag = following }
        } else {
            group.tabDrag = following
        }
    }
}

private struct TabButton: View {
    let tab: WorkspaceWindowGroup.Tab
    let select: () -> Void

    @State private var title: String
    @State private var hovering = false
    @ObservedObject private var commandKey = CommandKeyState.shared

    init(tab: WorkspaceWindowGroup.Tab, select: @escaping () -> Void) {
        self.tab = tab
        self.select = select
        _title = State(initialValue: tab.window?.title ?? "")
    }

    var body: some View {
        // The shortcut and close button get equal fixed-width slots, shown
        // or hidden in place, so the title stays centered and never shifts.
        // Each sits flush with its outer edge so both are inset equally.
        HStack(spacing: Self.spacing) {
            Text(tab.shortcut ?? "")
                .foregroundStyle(.secondary)
                .frame(width: Self.sideWidth, alignment: .leading)
                .opacity(commandKey.showsShortcuts ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: commandKey.showsShortcuts)

            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Button {
                (tab.window?.windowController as? TerminalController)?.closeTab(nil)
            } label: {
                // Sized to the glyph so it sits flush with the edge, with a
                // larger hit area around it.
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(4)
                    .contentShape(Rectangle())
                    .padding(-4)
            }
            .buttonStyle(.borderless)
            .frame(width: Self.sideWidth, alignment: .trailing)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Close Tab")
        }
        .font(.system(size: 12))
        .foregroundStyle(tab.isSelected ? .primary : .secondary)
        .padding(.horizontal, Self.inset)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(backgroundOpacity))
        )
        .animation(.easeOut(duration: 0.12), value: backgroundOpacity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onReceive(titlePublisher) { title = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
        // Pointer selection happens in the strip's drag gesture, on press.
        .accessibilityAction { select() }
    }

    private static let sideWidth: CGFloat = 24
    private static let spacing: CGFloat = 4
    private static let inset: CGFloat = 6

    /// The narrowest a tab gets, with its title truncated away.
    static let minWidth = 2 * sideWidth + 2 * spacing + 2 * inset

    /// The tint over the glass for each state: resting, hovered, and
    /// selected (unchanged by hover).
    private var backgroundOpacity: Double {
        if tab.isSelected { return 0.16 }
        return hovering ? 0.09 : 0.05
    }

    private var titlePublisher: AnyPublisher<String, Never> {
        guard let window = tab.window else { return Empty().eraseToAnyPublisher() }
        return window.publisher(for: \.title).eraseToAnyPublisher()
    }
}

/// Whether tabs show their ⌘-number shortcuts: once ⌘ has been held for a
/// moment, so they don't flash while pressing a shortcut, and until it's
/// released. One app-wide modifier monitor shared by every tab.
@MainActor
private final class CommandKeyState: ObservableObject {
    static let shared = CommandKeyState()

    @Published private(set) var showsShortcuts = false

    private static let delay: Duration = .milliseconds(500)
    private var pendingShow: Task<Void, Never>?

    private init() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }

        // Releasing ⌘ in another app never reaches us.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        guard flags.contains(.command) else {
            hide()
            return
        }

        guard !showsShortcuts, pendingShow == nil else { return }
        pendingShow = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard let self, !Task.isCancelled else { return }
            pendingShow = nil
            showsShortcuts = true
        }
    }

    private func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        if showsShortcuts { showsShortcuts = false }
    }
}
