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
            TabStrip(group: group, membership: membership)
        } else {
            Color.clear
        }
    }
}

private struct TabStrip: View {
    @ObservedObject var group: WorkspaceWindowGroup

    /// The membership of the tab whose window shows this strip.
    @ObservedObject var membership: WorkspaceMembership

    private typealias Drag = WorkspaceWindowGroup.TabDrag

    private var drag: Drag? { group.tabDrag }

    /// The strip's width, which the tabs share (see `tabWidths`).
    @State private var width: CGFloat = 0

    private static let spacing: CGFloat = 4
    private static let inset = (WorkspaceWindowGroup.tabStripHeight - 24) / 2
    private static let newTabWidth: CGFloat = 24
    private static let slideDuration = 0.15
    private static let slide = Animation.easeOut(duration: slideDuration)

    var body: some View {
        // A tab dragged out of the strip leaves it until the drag ends.
        let tabs = group.tabs.filter { phase(of: $0) != .draggingOut }
        let widths = tabWidths(count: tabs.count, includingSelected: tabs.contains(where: \.isSelected))

        HStack(spacing: Self.spacing) {
            ForEach(tabs) { tab in
                TabButton(
                    tab: tab,
                    width: tab.isSelected ? widths.selected : widths.other,
                    isRenaming: isRenaming(tab)
                ) { title in
                    controller(of: tab)?.endRenamingTab(title: title)
                } select: {
                    if let window = tab.window { group.selectTab(window) }
                }
                .offset(x: offset(of: tab))
                // The dragged tab tracks the pointer; the others slide.
                .animation(phase(of: tab) == .following ? nil : Self.slide, value: offset(of: tab))
                .zIndex(phase(of: tab) == nil ? 0 : 1)
                // Clicks in the title field while renaming position the cursor.
                .gesture(reorderGesture(for: tab), including: isRenaming(tab) ? .subviews : .all)
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
        // Measure the strip's width, not its content's: the tabs are sized
        // from it, so letting them feed back into it would never settle.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: WorkspaceWindowGroup.tabStripHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .onDrop(of: [.ghosttyWorkspaceTab], delegate: self)
    }

    /// The widths of the selected tab and the others when the strip holds
    /// `count` tabs: an equal share of the strip, except that the selected
    /// tab doesn't go below `TabButton.selectedMinWidth` while the others
    /// keep shrinking. Computed rather than measured, since while a tab is
    /// dragged out the strip holds one fewer.
    private func tabWidths(count: Int, includingSelected: Bool) -> (selected: CGFloat, other: CGFloat) {
        guard count > 0 else { return (0, 0) }
        let available = max(width - 2 * Self.inset - Self.newTabWidth - CGFloat(count) * Self.spacing, 0)
        let share = available / CGFloat(count)
        guard includingSelected, count > 1, share < TabButton.selectedMinWidth else { return (share, share) }

        let selected = min(TabButton.selectedMinWidth, available)
        return (selected, (available - selected) / CGFloat(count - 1))
    }

    /// The tabs' slots with all of them in the strip. The dragged tab is the
    /// selected one, since pressing a tab selects it.
    private var slots: ReorderSlots {
        let widths = tabWidths(count: group.tabs.count, includingSelected: true)
        return ReorderSlots(
            count: group.tabs.count,
            stride: widths.other + Self.spacing,
            draggedStride: widths.selected + Self.spacing)
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

    /// Whether the tab's title is being edited in this strip, which only
    /// happens in the tab's own window.
    private func isRenaming(_ tab: WorkspaceWindowGroup.Tab) -> Bool {
        membership.isRenamingTab && controller(of: tab)?.workspaceMembership === membership
    }

    private func controller(of tab: WorkspaceWindowGroup.Tab) -> TerminalController? {
        tab.window?.windowController as? TerminalController
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
        let center = Self.inset + CGFloat(from) * slots.stride + (slots.draggedStride - Self.spacing) / 2
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
    let width: CGFloat
    let isRenaming: Bool
    let endRenaming: (_ title: String?) -> Void
    let select: () -> Void

    @State private var title: String
    @State private var hovering = false
    @ObservedObject private var commandKey = CommandKeyState.shared

    init(
        tab: WorkspaceWindowGroup.Tab,
        width: CGFloat,
        isRenaming: Bool,
        endRenaming: @escaping (_ title: String?) -> Void,
        select: @escaping () -> Void
    ) {
        self.tab = tab
        self.width = width
        self.isRenaming = isRenaming
        self.endRenaming = endRenaming
        self.select = select
        _title = State(initialValue: tab.window?.title ?? "")
    }

    var body: some View {
        content
            .font(.system(size: 12))
            .foregroundStyle(tab.isSelected ? .primary : .secondary)
            .frame(width: width, height: 24)
            .clipped()
            .background { background }
            .animation(.easeOut(duration: 0.12), value: backgroundOpacity)
            .animation(.easeOut(duration: 0.12), value: showsShortcut)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onReceive(titlePublisher) { title = $0 }
            // The full title, which narrow tabs cut short or leave out.
            .help(title)
            // One button for VoiceOver, except while renaming, when the title
            // field must stay reachable.
            .accessibilityElement(children: isRenaming ? .contain : .combine)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isRenaming ? [] : tab.isSelected ? [.isButton, .isSelected] : .isButton)
            // Pointer selection happens in the strip's drag gesture, on press.
            .accessibilityAction { select() }
    }

    // MARK: Layout

    // Like Chrome's, tabs keep shrinking to fit however many there are,
    // showing less as they do: first the title shortens, then the close
    // button's own space goes, and finally only the icon is left, shrinking
    // too. Once the close button's space is gone, the selected tab shows it
    // in place of the icon on hover, and the strip keeps it wide enough for
    // that.

    private enum Layout {
        /// Icon, title, and a close button on hover.
        case full

        /// Icon and title.
        case narrow

        /// Only the icon.
        case tiny
    }

    private var layout: Layout {
        if width >= Self.narrowWidth { return .full }
        // Renaming needs the title, however little room is left for it.
        if width >= Self.tinyWidth || isRenaming { return .narrow }
        return .tiny
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .full:
            // The close button gets a fixed-width slot, shown or hidden in
            // place, so the title never shifts for it. It and the icon each
            // sit flush with their outer edge so both are inset equally.
            HStack(spacing: Self.spacing) {
                icon
                titleView
                closeButton
                    .frame(width: Self.closeWidth, alignment: .trailing)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .padding(.horizontal, Self.inset)

        case .narrow:
            HStack(spacing: Self.spacing) {
                iconOrClose
                titleView
            }
            .padding(.horizontal, Self.inset)

        case .tiny:
            iconOrClose
                .font(.system(size: tinyIconSize))
                .frame(maxWidth: .infinity)
        }
    }

    /// The icon, or once the close button has no space of its own, the close
    /// button in its place when hovering the selected tab.
    @ViewBuilder
    private var iconOrClose: some View {
        if tab.isSelected && hovering {
            closeButton
        } else {
            icon
        }
    }

    /// A terminal icon, which the tab's ⌘-number replaces while ⌘ is held,
    /// pushing the title aside by however wider it is.
    private var icon: some View {
        Group {
            if showsShortcut, let shortcut = tab.shortcut {
                Text(shortcut)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: layout != .tiny, vertical: false)
            } else {
                Image(systemName: "terminal.fill")
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.secondary)
        .transition(.opacity)
    }

    /// The icon's size when it's all a tab shows: shrinking with the tab, down
    /// to a floor below which it's clipped.
    private var tinyIconSize: CGFloat {
        min(12, max(7, (width - 8) * 0.75))
    }

    private var titleView: some View {
        Group {
            if isRenaming {
                // Starts from the title set by renaming, if any, rather than
                // the terminal's.
                TabTitleField(
                    title: (tab.window?.windowController as? BaseTerminalController)?.titleOverride ?? title,
                    end: endRenaming)
            } else {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var closeButton: some View {
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
        .help("Close Tab")
    }

    /// Below these widths, a tab drops to the next layout.
    private static let narrowWidth: CGFloat = 88
    private static let tinyWidth: CGFloat = 44

    /// The narrowest the selected tab gets, so it stays findable and its
    /// close button usable while the others keep shrinking.
    static let selectedMinWidth: CGFloat = 32

    private static let closeWidth: CGFloat = 24
    private static let spacing: CGFloat = 4
    /// Keeps the icon and close button clear of the capsule's rounded ends.
    private static let inset: CGFloat = 8

    /// The tint over the window's glass for each state: none at rest, then
    /// hovered, and selected (unchanged by hover) where Liquid Glass isn't
    /// available.
    private var backgroundOpacity: Double {
        if tab.isSelected { return 0.24 }
        return hovering ? 0.13 : 0
    }

    /// Liquid Glass when selected, where available, slightly faded so it
    /// reads as a highlight rather than a glass control. Otherwise a tint.
    @ViewBuilder
    private var background: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), tab.isSelected {
            Color.clear
                .glassEffect(.regular.interactive(), in: Capsule())
                .opacity(0.8)
        } else {
            Capsule().fill(Color.primary.opacity(backgroundOpacity))
        }
#else
        Capsule().fill(Color.primary.opacity(backgroundOpacity))
#endif
    }

    private var showsShortcut: Bool {
        commandKey.showsShortcuts && tab.shortcut != nil
    }

    private var titlePublisher: AnyPublisher<String, Never> {
        guard let window = tab.window else { return Empty().eraseToAnyPublisher() }
        return window.publisher(for: \.title).eraseToAnyPublisher()
    }
}

/// A tab's title being edited in place. Return saves it, and so does
/// leaving it: clicking elsewhere, or the window losing key status when
/// switching tabs or apps, which ends the rename and removes the field.
/// Escape cancels.
private struct TabTitleField: View {
    let end: (_ title: String?) -> Void

    @State private var text: String
    @State private var ended = false
    @FocusState private var isFocused: Bool

    init(title: String, end: @escaping (_ title: String?) -> Void) {
        self.end = end
        _text = State(initialValue: title)
    }

    var body: some View {
        TextField("Tab Title", text: $text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onAppear { isFocused = true }
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
