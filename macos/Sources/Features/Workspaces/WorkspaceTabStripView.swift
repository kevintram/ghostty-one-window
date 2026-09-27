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

    /// The distance between the leading edges of adjacent tabs. Tabs are
    /// all the same width.
    @State private var tabStride: CGFloat = 0

    private static let spacing: CGFloat = 4
    private static let slideDuration = 0.15
    private static let slide = Animation.easeOut(duration: slideDuration)

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(group.tabs) { tab in
                TabButton(tab: tab) {
                    if let window = tab.window { group.selectTab(window) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    tabStride = $0 + Self.spacing
                }
                .offset(x: offset(of: tab))
                // The dragged tab tracks the pointer; the others slide.
                .animation(isFollowingPointer(tab) ? nil : Self.slide, value: offset(of: tab))
                .zIndex(drag?.id == tab.id ? 1 : 0)
                .gesture(reorderGesture(for: tab))
            }

            Button {
                NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("New Tab")
        }
        // Match the vertical inset: 24pt tabs centered in the strip's height.
        .padding(.horizontal, (WorkspaceWindowGroup.tabStripHeight - 24) / 2)
        .frame(height: WorkspaceWindowGroup.tabStripHeight)
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

    private func reorderGesture(for tab: WorkspaceWindowGroup.Tab) -> some Gesture {
        // Only the press matters; the monitor tracks the rest.
        DragGesture(minimumDistance: 0).onChanged { _ in beginDrag(tab) }
    }

    /// Follow the current drag until it's released or cancelled.
    private static var monitor: Any?
    private static var resignObserver: NSObjectProtocol?

    private func beginDrag(_ tab: WorkspaceWindowGroup.Tab) {
        // The gesture also reports every move; only the press begins a drag.
        guard NSApp.currentEvent?.type == .leftMouseDown,
              group.tabDrag?.isSettling != true,
              let window = tab.window,
              let from = index(of: tab.id) else { return }

        if window.tabGroup?.selectedWindow != window { group.selectTab(window) }
        group.tabDrag = Drag(id: tab.id, offset: 0)

        // The tabs can't change width during the drag, so capture the layout.
        let stride = tabStride
        let count = group.tabs.count
        let start = NSApp.currentEvent.map(Self.screenX) ?? NSEvent.mouseLocation.x

        // The monitor only sees events after this press.
        Self.stopTracking()
        Self.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak group, weak window] event in
            guard let group, let window else {
                Self.stopTracking()
                return event
            }

            // Keep the tab within the strip.
            let offset = min(
                max(Self.screenX(of: event) - start, -CGFloat(from) * stride),
                CGFloat(count - 1 - from) * stride)

            switch event.type {
            case .leftMouseDragged:
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
        group.tabDrag = Drag(id: id, offset: CGFloat(to - from) * stride, isSettling: true)
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

    /// The event's horizontal position on screen, comparable across the
    /// tab windows the drag may be delivered to.
    private static func screenX(of event: NSEvent) -> CGFloat {
        guard let window = event.window else { return event.locationInWindow.x }
        return window.convertPoint(toScreen: event.locationInWindow).x
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
              let from = index(of: drag.id),
              let index = index(of: tab.id) else { return 0 }
        if index == from { return drag.offset }

        let to = Self.dropIndex(from: from, offset: drag.offset, stride: tabStride, count: group.tabs.count)
        if from < to, (from + 1...to).contains(index) { return -tabStride }
        if to < from, (to..<from).contains(index) { return tabStride }
        return 0
    }

    private func isFollowingPointer(_ tab: WorkspaceWindowGroup.Tab) -> Bool {
        drag?.id == tab.id && drag?.isSettling == false
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
        HStack(spacing: 4) {
            Text(tab.shortcut ?? "")
                .foregroundStyle(.secondary)
                .frame(width: Self.sideWidth, alignment: .leading)
                .opacity(commandKey.isPressed ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: commandKey.isPressed)

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
        .padding(.horizontal, 6)
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

/// Whether ⌘ is held, so tabs show their ⌘-number shortcuts only then. One
/// app-wide modifier monitor shared by every tab.
@MainActor
private final class CommandKeyState: ObservableObject {
    static let shared = CommandKeyState()

    @Published private(set) var isPressed = false

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
            MainActor.assumeIsolated { self?.isPressed = false }
        }
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        let pressed = flags.contains(.command)
        if pressed != isPressed { isPressed = pressed }
    }
}
