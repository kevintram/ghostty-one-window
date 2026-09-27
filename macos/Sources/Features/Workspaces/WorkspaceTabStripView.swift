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

    /// The tabs' slots with all of them in the strip. Computed from the
    /// strip's width rather than measured, since while a tab is dragged out
    /// the strip holds one fewer.
    private var slots: ReorderSlots {
        let count = group.tabs.count
        guard count > 0 else { return ReorderSlots(count: 0, stride: 0) }
        let tabs = width - 2 * Self.inset - Self.newTabWidth - CGFloat(count) * Self.spacing
        return ReorderSlots(count: count, stride: max(tabs / CGFloat(count), TabButton.minWidth) + Self.spacing)
    }

    // MARK: Reordering

    // Pressing a tab selects it right away, like a native tab, so a click
    // is just a drag that doesn't go anywhere. Dragging moves the tab with
    // the pointer while the tabs it passes slide into its place. The native
    // tab only moves on release.
    //
    // Selecting shows another tab window, so the rest of the drag is
    // followed by `PressDragTracker` and drawn from the group's shared
    // `tabDrag`.
    //
    // Dragging a tab out of the strip hands off to a system drag, which the
    // sidebar's workspace rows accept (see `WorkspaceTabDragOut`). Dragged
    // back over the strip, the tab rejoins it under the pointer until it's
    // dropped or leaves again.

    private func reorderGesture(for tab: WorkspaceWindowGroup.Tab) -> some Gesture {
        // Only the press matters; the tracker follows the rest.
        DragGesture(minimumDistance: 0).onChanged { _ in beginDrag(tab) }
    }

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
        let group = group
        let slots = slots
        let host = Self.stripHost(at: press)

        PressDragTracker.begin(from: press) { [weak group, weak window, weak host] event, translation in
            guard let group else { return false }
            guard let window else {
                // The tab is gone.
                group.tabDrag = nil
                return false
            }

            // Pulled out of the strip: drag it on as a system drag.
            if let host, let strip = host.window?.convertToScreen(host.convert(host.bounds, to: nil)),
               !strip.insetBy(dx: 0, dy: -Self.detachDistance).contains(PressDragTracker.screenPoint(of: event)) {
                withAnimation(Self.slide) { group.tabDrag = Drag(id: tab.id, phase: .draggingOut) }
                WorkspaceTabDragOut.begin(window, in: group, from: host, with: event)
                return false
            }

            group.tabDrag = Drag(id: tab.id, offset: slots.clamped(translation.width, from: from))
            return true
        } released: { [weak group, weak window] translation in
            guard let group else { return }
            guard let window else {
                // The tab is gone.
                group.tabDrag = nil
                return
            }
            let to = slots.destination(from: from, offset: slots.clamped(translation.width, from: from))
            Self.settle(tab.id, window: window, from: from, to: to, stride: slots.stride, in: group)
        } cancelled: { [weak group] in
            // Ends the drag without moving the tab, so it slides back.
            group?.tabDrag = nil
        }
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

    /// The hosting view of the strip that was pressed.
    private static func stripHost(at event: NSEvent) -> NSView? {
        guard let frameView = event.window?.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { return nil }
        return sequence(first: hit, next: \.superview).first { $0 is NSHostingView<WorkspaceTabStripView> }
    }

    private func index(of id: ObjectIdentifier) -> Int? {
        group.tabs.firstIndex { $0.id == id }
    }

    /// How far the tab is drawn from its slot during a drag.
    private func offset(of tab: WorkspaceWindowGroup.Tab) -> CGFloat {
        guard let drag,
              drag.phase != .draggingOut,
              let from = index(of: drag.id),
              let index = index(of: tab.id) else { return 0 }
        return slots.offset(of: index, draggingFrom: from, by: drag.offset)
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
        let to = slots.destination(from: from, offset: drag.offset)
        Self.settle(drag.id, window: window, from: from, to: to, stride: slots.stride, in: group)
        return true
    }

    /// Shows the dragged tab in the strip, centered under the pointer.
    private func follow(_ info: DropInfo) {
        guard let drag,
              drag.phase != .settling,
              let from = index(of: drag.id) else { return }
        let slots = slots
        let center = Self.inset + CGFloat(from) * slots.stride + (slots.stride - Self.spacing) / 2
        let offset = slots.clamped(info.location.x - center, from: from)

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
