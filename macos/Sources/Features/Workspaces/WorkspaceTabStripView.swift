import SwiftUI

/// The tab strip above the terminal, showing the selected workspace's tabs.
struct WorkspaceTabStripView: View {
    @ObservedObject var model: WorkspaceModel

    /// Performs the strip's actions. Weak, since the controller owns the
    /// window this is in.
    let controller: Weak<TerminalController>

    var body: some View {
        TabStrip(model: model, controller: controller)
    }
}

private struct TabStrip: View {
    @ObservedObject var model: WorkspaceModel
    let controller: Weak<TerminalController>

    private typealias Drag = WorkspaceModel.ReorderDrag

    private var drag: Drag? { model.tabDrag }

    /// The strip's width, which the tabs share (see `tabWidths`).
    @State private var width: CGFloat = 0

    /// While tabs are closed one after another with the mouse, the number of
    /// tabs the strip keeps sizing its tabs for, as in Safari and Chrome, so
    /// the next tab's close button stays under the pointer (see `releaseHold`).
    @State private var hold: Hold?

    private struct Hold: Equatable {
        let count: Int

        /// New with every close, restarting the wait before it's let go.
        let close = UUID()
    }

    private static let spacing: CGFloat = 2
    private static let inset = (WorkspaceModel.tabStripHeight - 24) / 2
    private static let newTabWidth: CGFloat = 24
    /// The new tab button's gap from the last tab, matching its gap from
    /// the strip's edge so it sits evenly between them.
    private static let newTabGap = inset
    private static let holdDuration: Duration = .seconds(1)
    private static let slideDuration = 0.15
    private static let slide = Animation.easeOut(duration: slideDuration)

    var body: some View {
        // A tab dragged out of the strip leaves it until the drag ends. One
        // dragged in from another window shows as selected, as it will be.
        let selected = model.incomingTab ?? model.selectedTab
        let tabs = displayedTabs.filter { phase(of: $0) != .draggingOut }
        let widths = tabWidths(count: sizingCount(tabs.count), includingSelected: tabs.contains { $0 === selected })

        HStack(spacing: Self.spacing) {
            ForEach(tabs) { tab in
                TabButton(
                    tab: tab,
                    isSelected: tab === selected,
                    width: tab === selected ? widths.selected : widths.other,
                    isRenaming: isRenaming(tab)
                ) { title in
                    controller.value?.endRenamingTab(tab, title: title)
                } select: {
                    controller.value?.selectTab(tab)
                } close: { byMouse in
                    // A confirmation interrupts the clicking anyway.
                    if byMouse, !tab.needsConfirmQuit { hold = Hold(count: sizingCount(tabs.count)) }
                    controller.value?.close(tab: tab)
                }
                .offset(x: offset(of: tab))
                // The dragged tab tracks the pointer; the others slide.
                .animation(phase(of: tab) == .following ? nil : Self.slide, value: offset(of: tab))
                .zIndex(phase(of: tab) == nil ? 0 : 1)
                // Clicks in the title field while renaming position the cursor.
                .gesture(reorderGesture(for: tab), including: isRenaming(tab) ? .subviews : .all)
                .contextMenu { menu(for: tab) }
                // A tab from another window isn't this strip's until dropped.
                .allowsHitTesting(tab !== model.incomingTab)
            }

            Button {
                controller.value?.newTab(nil)
            } label: {
                Image(systemName: "plus")
                    .frame(width: Self.newTabWidth, height: 24)
            }
            .buttonStyle(HoverCircleButtonStyle())
            .help("New Tab")
            .padding(.leading, Self.newTabGap - Self.spacing)
        }
        // Match the vertical inset: 24pt tabs centered in the strip's height.
        .padding(.horizontal, Self.inset)
        // Measure the strip's width, not its content's: the tabs are sized
        // from it, so letting them feed back into it would keep the tabs
        // from ever shrinking. Without the zero minimum, the frame takes its
        // content's width whenever that's wider.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: WorkspaceModel.tabStripHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: hold) {
            guard hold != nil else { return }
            try? await Task.sleep(for: Self.holdDuration)
            if !Task.isCancelled { releaseHold() }
        }
        .onChange(of: model.selectedWorkspaceID) { _ in hold = nil }
        .onChange(of: drag == nil) { idle in
            if idle { releaseHold() }
        }
        // Shown over the terminal only to take a dragged tab.
        .background { if !model.reservesTabStrip { Rectangle().fill(.bar) } }
        .contentShape(Rectangle())
        .onHover { inside in
            if !inside { releaseHold() }
        }
        .onDrop(of: [.ghosttyWorkspaceTab], delegate: self)
    }

    /// How many tabs to size the tabs for when the strip shows `count`: at
    /// least as many as are held (see `hold`).
    private func sizingCount(_ count: Int) -> Int {
        max(count, hold?.count ?? 0)
    }

    /// Lets go of the held tab count, once the pointer leaves the strip, a
    /// moment after the last close, or after a drag, so the tabs grow into
    /// the room. Not during a drag, whose slots were measured when it began.
    private func releaseHold() {
        guard hold != nil, drag == nil else { return }
        withAnimation(Self.slide) { hold = nil }
    }

    /// The widths of the selected tab and the others when the strip holds
    /// `count` tabs: an equal share of the strip, except that the selected
    /// tab doesn't go below `TabButton.selectedMinWidth` while the others
    /// keep shrinking. Computed rather than measured, since while a tab is
    /// dragged out the strip holds one fewer.
    private func tabWidths(count: Int, includingSelected: Bool) -> (selected: CGFloat, other: CGFloat) {
        guard count > 0 else { return (0, 0) }
        let available = max(width - 2 * Self.inset - Self.newTabGap - Self.newTabWidth - CGFloat(count - 1) * Self.spacing, 0)
        let share = available / CGFloat(count)
        guard includingSelected, count > 1, share < TabButton.selectedMinWidth else { return (share, share) }

        let selected = min(TabButton.selectedMinWidth, available)
        return (selected, (available - selected) / CGFloat(count - 1))
    }

    /// The selected workspace's tabs, then a tab being dragged in from
    /// another window.
    private var displayedTabs: [TerminalTab] {
        model.tabs + (model.incomingTab.map { [$0] } ?? [])
    }

    /// The tabs' slots with all of them in the strip. The dragged tab is the
    /// selected one, since pressing a tab selects it, or one dragged in from
    /// another window, which shows as selected.
    private var slots: ReorderSlots {
        let count = displayedTabs.count
        let widths = tabWidths(count: sizingCount(count), includingSelected: true)
        return ReorderSlots(
            count: count,
            stride: widths.other + Self.spacing,
            draggedStride: widths.selected + Self.spacing)
    }

    /// The tab's context menu. It acts on the tab, which it doesn't select.
    @ViewBuilder
    private func menu(for tab: TerminalTab) -> some View {
        let otherWorkspaces = model.workspaces.filter { !$0.tabs.contains { $0 === tab } }

        Button("New Tab to the Right") {
            controller.value?.newTab(after: tab)
        }
        Divider()
        Button("Rename Tab…") {
            controller.value?.beginRenamingTab(tab)
        }
        Menu("Move to Workspace") {
            ForEach(otherWorkspaces) { workspace in
                Button(workspace.name) {
                    controller.value?.moveTab(tab, toWorkspace: workspace.id)
                }
            }
            if !otherWorkspaces.isEmpty { Divider() }
            Button("New Workspace") {
                controller.value?.moveTabToNewWorkspace(tab)
            }
        }
        Button("Move to New Window") {
            controller.value?.moveTabToNewWindow(tab)
        }
        .disabled(model.allTabs.count < 2)
        Divider()
        Button("Close Tab") {
            controller.value?.close(tab: tab)
        }
        Button("Close Other Tabs") {
            controller.value?.closeOtherTabs(than: tab)
        }
        .disabled(model.otherTabs(than: tab).isEmpty)
        Button("Close Tabs to the Right") {
            controller.value?.closeTabs(rightOf: tab)
        }
        .disabled(model.tabs(rightOf: tab).isEmpty)
    }

    // MARK: Reordering

    // Pressing a tab selects it right away, like a native tab, so a click
    // is just a drag that doesn't go anywhere. Dragging moves the tab with
    // the pointer while the tabs it passes slide into its place. The tab
    // only moves in the model on release.
    //
    // The rest of the drag is followed by `PressDragTracker` and drawn from
    // the model's `tabDrag`.
    //
    // Dragging a tab out of the strip hands off to a system drag, which the
    // sidebar's workspace rows and every window's strip accept (see
    // `WorkspaceDragOut`). Dragged back over the strip, the tab rejoins it
    // under the pointer until it's dropped or leaves again. Over another
    // window's strip, it joins that strip the same way, after its tabs.

    private func reorderGesture(for tab: TerminalTab) -> some Gesture {
        // Only the press matters; the tracker follows the rest.
        DragGesture(minimumDistance: 0).onChanged { _ in beginDrag(tab) }
    }

    private func beginDrag(_ tab: TerminalTab) {
        // The gesture also reports every move; only the press begins a drag.
        guard let press = NSApp.currentEvent,
              press.type == .leftMouseDown,
              model.tabDrag == nil || model.tabDrag?.phase == .following,
              let from = index(of: tab.id) else { return }

        controller.value?.selectTab(tab)
        model.tabDrag = Drag(id: tab.id)

        // The tabs can't change width during the drag, so capture the layout.
        let model = model
        let slots = slots
        let host = Self.stripHost(at: press)
        let controller = controller

        PressDragTracker.begin(from: press) { [weak model, weak tab, weak host] event, translation in
            guard let model, let source = controller.value else { return false }
            guard let tab, model.contains(tab) else {
                // The tab is gone.
                model.tabDrag = nil
                return false
            }

            // Pulled out of the strip: drag it on as a system drag.
            if let host, let strip = host.window?.convertToScreen(host.convert(host.bounds, to: nil)),
               !strip.insetBy(dx: 0, dy: -Self.detachDistance).contains(PressDragTracker.screenPoint(of: event)) {
                withAnimation(Self.slide) { model.tabDrag = Drag(id: tab.id, phase: .draggingOut) }
                WorkspaceDragOut.begin(.tab(tab), of: source, from: host, with: event)
                return false
            }

            model.tabDrag = Drag(id: tab.id, offset: slots.clamped(translation.width, from: from))
            return true
        } released: { [weak model, weak tab] translation in
            guard let model else { return }
            guard let tab, model.contains(tab) else {
                // The tab is gone.
                model.tabDrag = nil
                return
            }
            let to = slots.destination(from: from, offset: slots.clamped(translation.width, from: from))
            Self.settle(tab, from: from, to: to, stride: slots.stride, in: model) { model.moveTab(tab, to: to) }
        } cancelled: { [weak model] in
            // Ends the drag without moving the tab, so it slides back.
            model?.tabDrag = nil
        }
    }

    /// Settles the dragged tab into slot `to`, then moves it there with
    /// `move` (see `WorkspaceDragOut.settle`).
    private static func settle(
        _ tab: TerminalTab,
        from: Int,
        to: Int,
        stride: CGFloat,
        in model: WorkspaceModel,
        move: @escaping () -> Void
    ) {
        model.tabDrag = Drag(id: tab.id, offset: CGFloat(to - from) * stride, phase: .settling)
        WorkspaceDragOut.settle(.tab(tab), for: slideDuration, move: move)
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

    private func index(of id: UUID) -> Int? {
        displayedTabs.firstIndex { $0.id == id }
    }

    /// How far the tab is drawn from its slot during a drag.
    private func offset(of tab: TerminalTab) -> CGFloat {
        guard let drag,
              drag.phase != .draggingOut,
              let from = index(of: drag.id),
              let index = index(of: tab.id) else { return 0 }
        return slots.offset(of: index, draggingFrom: from, by: drag.offset)
    }

    /// Whether the tab's title is being edited in the strip.
    private func isRenaming(_ tab: TerminalTab) -> Bool {
        model.renaming == .tab(tab.id)
    }

    /// The drag phase of the tab, if it's the one being dragged.
    private func phase(of tab: TerminalTab) -> Drag.Phase? {
        drag?.id == tab.id ? drag?.phase : nil
    }
}

// MARK: Dragging in

// Drops come from a tab dragged out of a strip: this one's, rejoining it, or
// another window's, joining it after its tabs. Either way the tab follows
// the pointer until it's dropped or leaves.
extension TabStrip: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool {
        WorkspaceDragOut.draggedTab != nil && drag?.phase != .settling
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
        withAnimation(Self.slide) {
            if model.incomingTab?.id == drag.id {
                model.incomingTab = nil
                model.tabDrag = nil
            } else {
                model.tabDrag = Drag(id: drag.id, phase: .draggingOut)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let drag, let from = index(of: drag.id) else { return false }
        let tab = displayedTabs[from]
        let to = slots.destination(from: from, offset: drag.offset)
        let model = model
        guard tab === model.incomingTab else {
            Self.settle(tab, from: from, to: to, stride: slots.stride, in: model) { model.moveTab(tab, to: to) }
            return true
        }

        // The tab moves here once it has settled, into the workspace it was
        // dropped on, unless this window, that workspace, or the tab's window
        // went meanwhile.
        let destination = controller
        let source = WorkspaceDragOut.draggedTab?.source
        let workspace = model.selectedWorkspaceID
        Self.settle(tab, from: from, to: to, stride: slots.stride, in: model) { [weak source] in
            guard let source, let workspace else { return }
            destination.value?.receive(tab, from: source, inWorkspace: workspace, at: to)
        }
        return true
    }

    /// Shows the dragged tab in the strip, centered under the pointer. It
    /// joins the strip, making room for itself, if it isn't in it already.
    private func follow(_ info: DropInfo) {
        guard let tab = WorkspaceDragOut.draggedTab?.tab, drag?.phase != .settling else { return }
        withAnimation(drag?.phase == .following ? nil : Self.slide) {
            if !model.contains(tab) { model.incomingTab = tab }
            guard let from = index(of: tab.id) else { return }
            let slots = slots
            let center = Self.inset + CGFloat(from) * slots.stride + (slots.draggedStride - Self.spacing) / 2
            model.tabDrag = Drag(id: tab.id, offset: slots.clamped(info.location.x - center, from: from))
        }
    }
}

private struct TabButton: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let width: CGFloat
    let isRenaming: Bool
    let endRenaming: (_ title: String?) -> Void
    let select: () -> Void
    let close: (_ byMouse: Bool) -> Void

    @State private var hovering = false

    private var title: String { tab.title }

    var body: some View {
        content
            .font(.system(size: 12))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(width: width, height: 24)
            .clipped()
            .background { background }
            .animation(.easeOut(duration: 0.12), value: backgroundOpacity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // The full title, which narrow tabs cut short or leave out.
            .help(title)
            // One button for VoiceOver, except while renaming, when the title
            // field must stay reachable.
            .accessibilityElement(children: isRenaming ? .contain : .combine)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isRenaming ? [] : isSelected ? [.isButton, .isSelected] : .isButton)
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
        if isSelected && hovering {
            closeButton
        } else {
            icon
        }
    }

    private var icon: some View {
        Image(systemName: "terminal.fill")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
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
                InlineTitleField("Tab Title", title: tab.titleOverride ?? title, end: endRenaming)
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
            close(NSApp.currentEvent?.type == .leftMouseUp)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: Self.closeCircleSize, height: Self.closeCircleSize)
        }
        .buttonStyle(HoverCircleButtonStyle())
        .help("Close Tab")
        // Laid out as just the glyph, so the × sits flush with the tab's edge
        // and its circle extends past it.
        .padding(-Self.closeCircleOverhang)
    }

    /// Below these widths, a tab drops to the next layout.
    private static let narrowWidth: CGFloat = 88
    private static let tinyWidth: CGFloat = 44

    /// The narrowest the selected tab gets, so it stays findable and its
    /// close button usable while the others keep shrinking.
    static let selectedMinWidth: CGFloat = 32

    private static let closeWidth: CGFloat = 24

    /// The close button's hover circle, and how far it extends past the ×.
    private static let closeCircleSize: CGFloat = 16
    private static let closeCircleOverhang: CGFloat = 4
    private static let spacing: CGFloat = 4
    /// Keeps the icon and close button clear of the capsule's rounded ends.
    private static let inset: CGFloat = 8

    /// The tint over the window's glass for each state: none at rest, then
    /// hovered, and selected (unchanged by hover) where Liquid Glass isn't
    /// available.
    private var backgroundOpacity: Double {
        if isSelected { return 0.24 }
        return hovering ? 0.13 : 0
    }

    /// Liquid Glass when selected, where available, slightly faded so it
    /// reads as a highlight rather than a glass control. Otherwise a tint.
    @ViewBuilder
    private var background: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), isSelected {
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
}

/// The tab strip's glyph buttons (new tab, close tab). Muted at rest, the
/// glyph brightens while hovered and a circle filling the label's frame
/// appears behind it, marking its hit area, and darkens while pressed.
private struct HoverCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCircleButton(configuration: configuration)
    }

    private struct HoverCircleButton: View {
        let configuration: Configuration

        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? .primary : .secondary)
                .background(Circle().fill(Color.primary.opacity(circleOpacity)))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: circleOpacity)
        }

        private var circleOpacity: Double {
            if configuration.isPressed { return 0.2 }
            return hovering ? 0.12 : 0
        }
    }
}
