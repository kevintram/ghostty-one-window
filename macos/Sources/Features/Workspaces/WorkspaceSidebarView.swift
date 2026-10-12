import SwiftUI

/// The workspace sidebar of a terminal window.
struct WorkspaceSidebarView: View {
    @ObservedObject var model: WorkspaceModel

    /// Performs the sidebar's actions. Weak, since the controller owns the
    /// window this is in.
    let controller: Weak<TerminalController>

    @ObservedObject var insets: WorkspaceSidebarInsets
    let tooltip: HoverTooltipCoordinator

    /// How much the window's background color covers the translucent window
    /// behind the sidebar, so its text stays readable over busy content.
    private static let backgroundOpacity = 0.5

    var body: some View {
        // Keep the hosting root unmodified: drag-out lookup uses this view type.
        WorkspaceListView(model: model, controller: controller, topInset: insets.top)
            .coordinatedHoverTooltips(using: tooltip)
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(Self.backgroundOpacity)
                    .ignoresSafeArea()
            }
    }
}

/// Where the sidebar's content starts, set by its split view controller.
/// It's the window's titlebar height, since the sidebar extends under it.
@MainActor
final class WorkspaceSidebarInsets: ObservableObject {
    @Published var top: CGFloat = 0
}

/// The workspace list, laid out by hand rather than with `List` so
/// workspaces can be dragged to reorder them, sliding aside like the tab
/// strip's tabs. Each workspace is a group: a header, then its tabs while
/// it's expanded. The rows draw the selection from the model.
private struct WorkspaceListView: View {
    @ObservedObject var model: WorkspaceModel
    let controller: Weak<TerminalController>
    let topInset: CGFloat

    /// The workspace a tab dragged out of a tab strip would be dropped on.
    @State private var dropTarget: UUID?

    /// Where the groups start in the list, to find the group under a drop.
    @State private var rowsTop: CGFloat = 0

    /// The groups' heights as last laid out, which drags and drops read to
    /// find each group.
    @State private var heights = GroupHeights()

    private typealias Drag = WorkspaceModel.ReorderDrag

    private var drag: Drag? { model.workspaceDrag }

    private static let slideDuration = 0.15
    private static let slide = Animation.easeOut(duration: slideDuration)
    private static let coordinateSpace = "WorkspaceList"

    var body: some View {
        // A workspace dragged out of the sidebar leaves it until the drag
        // ends. One dragged in from another window shows as selected, as it
        // will be.
        let selected = model.incomingWorkspace?.id ?? model.selectedWorkspaceID
        let groups = Self.displayedWorkspaces(of: model).filter { phase(of: $0.id) != .draggingOut }
        let slots = Self.slots(of: model, heights: heights)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Workspaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .named(Self.coordinateSpace)).maxY
                    } action: { rowsTop = $0 }

                ForEach(Array(groups.enumerated()), id: \.element.id) { index, workspace in
                    // Every workspace in the list has a tab, which names it
                    // unless it has a custom name.
                    if let tab = workspace.selectedTab {
                        WorkspaceGroup(
                            workspace: workspace,
                            currentTab: tab,
                            shownTab: workspace.id == selected ? tab : nil,
                            isDropTarget: workspace.id == dropTarget,
                            model: model,
                            controller: controller
                        ) {
                            beginDrag(workspace.id)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[workspace.id] = $0 }
                        .offset(y: offset(at: index, in: slots))
                        // The dragged group tracks the pointer; the others slide.
                        .animation(phase(of: workspace.id) == .following ? nil : Self.slide, value: offset(at: index, in: slots))
                        .zIndex(phase(of: workspace.id) == nil ? 0 : 1)
                        // A workspace from another window isn't this
                        // sidebar's until dropped.
                        .allowsHitTesting(workspace.id != model.incomingWorkspace?.id)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, topInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: Self.coordinateSpace)
        .onDrop(of: [.ghosttyWorkspaceTab, .ghosttyWorkspace], delegate: self)
    }

    // MARK: Reordering

    // Pressing a workspace's header selects it right away, like a tab, so a
    // click is just a drag that doesn't go anywhere. Dragging moves the
    // group, with its tabs, with the pointer while the groups it passes
    // slide into its place, and the workspaces reorder on release. Clicking
    // the selected workspace's header expands or collapses it, like its
    // chevron. Every click counts, however quickly it follows the last.
    //
    // The rest of the drag is followed by `PressDragTracker` and drawn from
    // the model's `workspaceDrag`. The group is found by ID each time, since
    // workspaces can come and go during the drag (e.g. when a last terminal
    // exits).
    //
    // Dragging a group out of the sidebar sideways hands off to a system
    // drag, which every window's sidebar accepts (see `WorkspaceDragOut`).
    // Dragged back over the sidebar, the group rejoins it under the pointer
    // until it's dropped or leaves again. Over another window's sidebar, it
    // joins that sidebar the same way, after its groups.

    private func beginDrag(_ id: UUID) {
        // The gesture also reports every move; only the press begins a drag.
        guard let press = NSApp.currentEvent, press.type == .leftMouseDown else { return }

        let togglesOnClick = model.selectedWorkspaceID == id
        controller.value?.selectWorkspace(id)
        model.workspaceDrag = Drag(id: id)

        let model = model
        let controller = controller
        let heights = heights
        let host = Self.sidebarHost(at: press)
        PressDragTracker.begin(from: press) { [weak model, weak host] event, translation in
            guard let model, let source = controller.value else { return false }
            guard let from = model.workspaceIndex(of: id) else {
                // The workspace is gone.
                model.workspaceDrag = nil
                return false
            }

            // Pulled out of the sidebar sideways: drag it on as a system drag.
            if let host, let sidebar = host.window?.convertToScreen(host.convert(host.bounds, to: nil)) {
                let x = PressDragTracker.screenPoint(of: event).x
                if x < sidebar.minX - Self.detachDistance || x > sidebar.maxX + Self.detachDistance {
                    withAnimation(Self.slide) { model.workspaceDrag = Drag(id: id, phase: .draggingOut) }
                    WorkspaceDragOut.begin(.workspace(id), of: source, from: host, with: event)
                    return false
                }
            }

            let slots = Self.slots(of: model, heights: heights)
            model.workspaceDrag = Drag(id: id, offset: slots.clamped(translation.height, from: from))
            return true
        } released: { [weak model] translation in
            guard let model else { return }
            withAnimation(Self.slide) {
                if let from = model.workspaceIndex(of: id) {
                    let slots = Self.slots(of: model, heights: heights)
                    let offset = slots.clamped(translation.height, from: from)
                    model.moveWorkspace(id, to: slots.destination(from: from, offset: offset))
                }
                model.workspaceDrag = nil
            }

            if togglesOnClick, hypot(translation.width, translation.height) < Self.clickDistance {
                withAnimation(SidebarMetrics.expansion) { model.toggleExpanded(ofWorkspace: id) }
            }
        } cancelled: { [weak model] in
            withAnimation(Self.slide) { model?.workspaceDrag = nil }
        }
    }

    /// How far beside the sidebar the pointer can stray before the group is
    /// dragged out of it.
    private static let detachDistance: CGFloat = 16

    /// How far a press can move and still be a click.
    private static let clickDistance: CGFloat = 3

    /// The hosting view of the sidebar that was pressed.
    private static func sidebarHost(at event: NSEvent) -> NSView? {
        guard let frameView = event.window?.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { return nil }
        return sequence(first: hit, next: \.superview).first { $0 is NSHostingView<WorkspaceSidebarView> }
    }

    /// The workspaces, then a workspace being dragged in from another window.
    private static func displayedWorkspaces(of model: WorkspaceModel) -> [Workspace] {
        model.workspaces + (model.incomingWorkspace.map { [$0] } ?? [])
    }

    /// The displayed workspaces' slots, each as tall as its group.
    private static func slots(of model: WorkspaceModel, heights: GroupHeights) -> ReorderSlots {
        ReorderSlots(lengths: displayedWorkspaces(of: model).map {
            heights[$0.id] ?? SidebarMetrics.rowHeight + SidebarMetrics.groupGap
        })
    }

    private func index(of id: UUID) -> Int? {
        Self.displayedWorkspaces(of: model).firstIndex { $0.id == id }
    }

    /// The drag phase of the workspace, if it's the one being dragged.
    private func phase(of id: UUID) -> Drag.Phase? {
        drag?.id == id ? drag?.phase : nil
    }

    /// How far the group is drawn from its slot during a drag.
    private func offset(at index: Int, in slots: ReorderSlots) -> CGFloat {
        guard let drag, drag.phase != .draggingOut, let from = self.index(of: drag.id) else { return 0 }
        return slots.offset(of: index, draggingFrom: from, by: drag.offset)
    }
}

/// Heights of views by ID as they were last laid out. A reference, so
/// gestures read the latest, and measuring doesn't update the view.
@MainActor
private final class GroupHeights {
    private var heights: [UUID: CGFloat] = [:]

    subscript(id: UUID) -> CGFloat? {
        get { heights[id] }
        set { heights[id] = newValue }
    }
}

// MARK: Dropping

// Drops come from a tab dragged out of a tab strip, onto the workspace it
// moves to, or from a workspace dragged out of a sidebar: this one's,
// rejoining it, or another window's, joining it after its groups. A dragged
// workspace follows the pointer until it's dropped or leaves.
extension WorkspaceListView: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool {
        WorkspaceDragOut.draggedTab != nil
            || (WorkspaceDragOut.draggedWorkspace != nil && drag?.phase != .settling)
    }

    func dropEntered(info: DropInfo) {
        follow(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        follow(info)
        let tabWithoutTarget = WorkspaceDragOut.draggedTab != nil && workspace(at: info.location) == nil
        return DropProposal(operation: tabWithoutTarget ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        dropTarget = nil
        guard let drag, drag.phase == .following else { return }
        withAnimation(Self.slide) {
            if model.incomingWorkspace?.id == drag.id {
                model.incomingWorkspace = nil
                model.workspaceDrag = nil
            } else {
                model.workspaceDrag = Drag(id: drag.id, phase: .draggingOut)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let controller = controller.value else { return false }

        // A tab moves to the workspace it was dropped on. Dropped on its own
        // workspace, it goes back where it was.
        if let (tab, source) = WorkspaceDragOut.draggedTab {
            guard let workspace = workspace(at: info.location) else { return false }
            if source === controller {
                controller.moveTab(tab, toWorkspace: workspace)
            } else {
                controller.receive(tab, from: source, inWorkspace: workspace)
            }
            return true
        }

        // A workspace settles into its slot, then moves there, unless this
        // window, or the workspace's, went meanwhile.
        guard let (id, source) = WorkspaceDragOut.draggedWorkspace,
              let drag, drag.id == id,
              let from = index(of: id) else { return false }
        let slots = Self.slots(of: model, heights: heights)
        let to = slots.destination(from: from, offset: drag.offset)
        model.workspaceDrag = Drag(id: id, offset: slots.distance(from: from, to: to), phase: .settling)

        let model = model
        let destination = self.controller
        WorkspaceDragOut.settle(.workspace(id), for: Self.slideDuration) { [weak source] in
            guard let source else { return }
            if source === destination.value {
                model.moveWorkspace(id, to: to)
            } else {
                destination.value?.receive(workspace: id, from: source, at: to)
            }
        }
        return true
    }

    /// Follows the drag: highlights the workspace a tab would be dropped on,
    /// or shows a dragged workspace with its header centered under the
    /// pointer. It joins the sidebar, making room for itself, if it isn't in
    /// it already.
    private func follow(_ info: DropInfo) {
        if WorkspaceDragOut.draggedTab != nil {
            dropTarget = workspace(at: info.location)
            return
        }

        guard let (id, source) = WorkspaceDragOut.draggedWorkspace,
              drag?.phase != .settling,
              let controller = controller.value else { return }
        withAnimation(drag?.phase == .following ? nil : Self.slide) {
            if source !== controller, model.incomingWorkspace?.id != id {
                model.incomingWorkspace = source.workspaceModel.workspaces.first { $0.id == id }
            }
            guard let from = index(of: id) else { return }
            let slots = Self.slots(of: model, heights: heights)
            let header = rowsTop + slots.start(of: from) + SidebarMetrics.rowHeight / 2
            model.workspaceDrag = Drag(id: id, offset: slots.clamped(info.location.y - header, from: from))
        }
    }

    /// The workspace whose group is at `point`.
    private func workspace(at point: CGPoint) -> UUID? {
        guard let index = Self.slots(of: model, heights: heights).slot(at: point.y - rowsTop),
              model.workspaces.indices.contains(index) else { return nil }
        return model.workspaces[index].id
    }
}

/// A workspace in the sidebar: a header with its name, then its tabs while
/// it's expanded. The selected workspace highlights the tab shown in the
/// window, or while collapsed, its header in that tab's place. Hovering the
/// group highlights all of it.
private struct WorkspaceGroup: View {
    let workspace: Workspace

    /// The workspace's current tab, observed since its title names the
    /// workspace without a custom name.
    @ObservedObject var currentTab: TerminalTab

    /// The tab shown in the window, if it's this workspace's.
    let shownTab: TerminalTab?

    let isDropTarget: Bool

    /// The window's model, which the list observes, for renaming and menus.
    let model: WorkspaceModel
    let controller: Weak<TerminalController>

    /// Handles a press on the header, which selects the workspace, or
    /// expands or collapses it if it's selected, and can begin dragging it.
    let pressHeader: () -> Void

    @State private var hovering = false
    @State private var hoveringHeader = false

    private var name: String { workspace.name }

    private var isRenaming: Bool {
        model.renaming == .workspace(workspace.id)
    }

    /// Whether the header is highlighted as selected: the workspace is
    /// selected, but collapsed, so the tab shown isn't listed.
    private var isHeaderSelected: Bool {
        shownTab != nil && !workspace.isExpanded && !isDropTarget
    }

    /// The tabs listed under the header. A tab dragged out of the tab strip
    /// leaves the sidebar too until the drag ends.
    private var listedTabs: [TerminalTab] {
        let tabs = workspace.isExpanded ? workspace.tabs : []
        guard let drag = model.tabDrag, drag.phase == .draggingOut else { return tabs }
        return tabs.filter { $0.id != drag.id }
    }

    var body: some View {
        let tabs = listedTabs

        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(tabs) { tab in
                tabRow(tab)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, tabs.isEmpty ? 0 : SidebarMetrics.tabsBottomInset)
        // A drop target is filled with the accent color, like Finder's.
        .foregroundStyle(isDropTarget ? Color.white : Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTarget ? Color.accentColor : Color.primary.opacity(hovering ? SidebarMetrics.groupHoverOpacity : 0))
                .animation(SidebarMetrics.hoverFade, value: hovering)
        }
        .onHover { hovering = $0 }
        .padding(.bottom, SidebarMetrics.groupGap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            Image(systemName: "rectangle.stack")
                .imageScale(.large)
                .foregroundStyle(isDropTarget ? Color.white : Color.accentColor)
                .frame(width: SidebarMetrics.iconWidth)
            if isRenaming {
                InlineTitleField("Workspace Name", title: name) {
                    controller.value?.endRenamingWorkspace(workspace.id, name: $0)
                }
                .fontWeight(.bold)
            } else {
                Text(name)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                chevron
            }
            Spacer(minLength: 0)
            // Closing the last workspace closes the window.
            SidebarCloseButton(isShown: hoveringHeader && !isRenaming && !isDropTarget, action: close)
        }
        .padding(.horizontal, SidebarMetrics.rowInset)
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            SidebarRowBackground(isSelected: isHeaderSelected, isHovered: hoveringHeader && !isDropTarget)
        }
        .animation(SidebarMetrics.hoverFade, value: hoveringHeader)
        .contentShape(Rectangle())
        // Clicks in the name field while renaming position the cursor.
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { _ in pressHeader() },
            including: isRenaming ? .subviews : .all)
        .contextMenu { menu }
        .onMiddleClick { close() }
        .onHover { hoveringHeader = $0 }
        .hoverTooltip(name, minWidth: 60)
        // One button for VoiceOver, except while renaming, when the name
        // field must stay reachable.
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityValue(workspace.isExpanded ? "Expanded" : "Collapsed")
        // Selected, like the highlight, only while the shown tab isn't listed.
        .accessibilityAddTraits(isRenaming ? [] : isHeaderSelected ? [.isButton, .isSelected] : .isButton)
        // Pointer selection happens in the list's drag gesture, on press.
        .accessibilityAction { controller.value?.selectWorkspace(workspace.id) }
        .accessibilityAction(named: workspace.isExpanded ? "Collapse" : "Expand", toggleExpanded)
        .accessibilityAction(named: "Close Workspace", close)
    }

    /// Expands or collapses the workspace, pointing down while it's
    /// expanded and to the side while it's collapsed.
    private var chevron: some View {
        Button(action: toggleExpanded) {
            Image(systemName: "chevron.down")
                .font(.system(size: SidebarMetrics.glyphSize, weight: .bold))
                .rotationEffect(.degrees(workspace.isExpanded ? 0 : -90))
                .frame(width: SidebarMetrics.glyphButtonSize, height: SidebarMetrics.glyphButtonSize)
        }
        .buttonStyle(HoverCircleButtonStyle())
        // VoiceOver expands and collapses with the header's actions.
        .accessibilityHidden(true)
    }

    /// The workspace's context menu. It acts on the workspace, which it
    /// doesn't select.
    @ViewBuilder
    private var menu: some View {
        Button("New Tab") {
            controller.value?.newTab(inWorkspace: workspace.id)
        }
        Button("Rename Workspace…") {
            controller.value?.beginRenamingWorkspace(workspace.id)
        }
        Divider()
        Button("Close Workspace") {
            controller.value?.close(workspace: workspace.id)
        }
        Button("Close Other Workspaces") {
            controller.value?.closeOtherWorkspaces(than: workspace.id)
        }
        .disabled(model.workspaces.count < 2)
    }

    private func toggleExpanded() {
        withAnimation(SidebarMetrics.expansion) { model.toggleExpanded(ofWorkspace: workspace.id) }
    }

    private func close() {
        controller.value?.close(workspace: workspace.id)
    }

    // MARK: Tabs

    private func tabRow(_ tab: TerminalTab) -> some View {
        let isRenaming = model.renaming == .sidebarTab(tab.id)
        return WorkspaceTabRow(
            tab: tab,
            isSelected: tab === shownTab,
            isRenaming: isRenaming
        ) { title in
            controller.value?.endRenamingTab(tab, title: title, inSidebar: true)
        } select: {
            controller.value?.selectTab(tab)
        } close: {
            controller.value?.close(tab: tab)
        }
        // Clicks in the title field while renaming position the cursor.
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { _ in press(tab) },
            including: isRenaming ? .subviews : .all)
        .contextMenu { TabContextMenu(tab: tab, model: model, controller: controller, inSidebar: true) }
    }

    /// Pressing a tab selects it right away, as in the tab strip.
    /// Double-clicking it renames it in place.
    private func press(_ tab: TerminalTab) {
        // The gesture also reports every move; only the press counts.
        guard let press = NSApp.currentEvent, press.type == .leftMouseDown else { return }
        controller.value?.selectTab(tab)
        if press.clickCount == 2 {
            controller.value?.beginRenamingTab(tab, inSidebar: true)
        }
    }
}

/// A tab listed in the sidebar: its icon, its title, and a close button on
/// hover. The tab shown in the window is highlighted (see
/// `SidebarRowBackground`).
private struct WorkspaceTabRow: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let isRenaming: Bool
    let endRenaming: (_ title: String?) -> Void
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    private var title: String { tab.title }

    var body: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.secondary)
                .frame(width: SidebarMetrics.iconWidth)
                .accessibilityHidden(true)
            if isRenaming {
                // Starts from the title set by renaming, if any, rather than
                // the terminal's.
                InlineTitleField("Tab Title", title: tab.titleOverride ?? title, end: endRenaming)
            } else {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            SidebarCloseButton(isShown: hovering && !isRenaming, action: close)
        }
        .padding(.horizontal, SidebarMetrics.rowInset)
        .frame(height: SidebarMetrics.rowHeight)
        .background { SidebarRowBackground(isSelected: isSelected, isHovered: hovering) }
        .animation(SidebarMetrics.hoverFade, value: hovering)
        .contentShape(Rectangle())
        .onMiddleClick { close() }
        .onHover { hovering = $0 }
        .hoverTooltip(title, minWidth: 60)
        // One button for VoiceOver, except while renaming, when the title
        // field must stay reachable.
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isRenaming ? [] : isSelected ? [.isButton, .isSelected] : .isButton)
        // Pointer selection happens in the group's gesture, on press.
        .accessibilityAction { select() }
        .accessibilityAction(named: "Close Tab", close)
    }
}

/// A sidebar row's close button, shown on hover. It's shown or hidden in
/// place, so the row's title never shifts for it. VoiceOver closes with the
/// row's action instead.
private struct SidebarCloseButton: View {
    let isShown: Bool
    let action: () -> Void

    var body: some View {
        HoverCloseButton(
            glyphSize: SidebarMetrics.glyphSize,
            circleSize: SidebarMetrics.glyphButtonSize,
            action: action)
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(true)
    }
}

/// The background of a sidebar row: Liquid Glass when selected, where
/// available, slightly faded so it reads as a highlight rather than a glass
/// control, as in the tab strip. Otherwise a tint, also when hovered.
private struct SidebarRowBackground: View {
    let isSelected: Bool
    var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
#if compiler(>=6.2)
        if #available(macOS 26.0, *), isSelected {
            Color.clear
                .glassEffect(.regular.interactive(), in: shape)
                .opacity(0.8)
        } else {
            shape.fill(Color.primary.opacity(tintOpacity))
        }
#else
        shape.fill(Color.primary.opacity(tintOpacity))
#endif
    }

    /// None at rest, then hovered, and selected where Liquid Glass isn't
    /// available.
    private var tintOpacity: Double {
        if isSelected { return 0.13 }
        return isHovered ? 0.08 : 0
    }
}

/// The sidebar's metrics, shared by its headers and tab rows. The row height
/// and insets match the native sidebar list the workspace list replaced.
private enum SidebarMetrics {
    /// The height of a header or tab row.
    static let rowHeight: CGFloat = 32

    /// The space after a group, which sets each workspace's tabs apart from
    /// the next workspace now that they aren't indented.
    static let groupGap: CGFloat = 8

    /// The space below a group's last tab, inside its hover tint.
    static let tabsBottomInset: CGFloat = 2

    /// A row's content inset, its icon's width, and the space between its
    /// items. Tab rows aren't indented; headers and tabs give their icons
    /// the same width, so the icons line up, and so do names and titles.
    static let rowInset: CGFloat = 8.5
    static let iconWidth: CGFloat = 20
    static let spacing: CGFloat = 6.5

    /// The chevron's and close buttons' glyph size and hover circle:
    /// larger than the tab strip's, for the taller rows.
    static let glyphSize: CGFloat = 11
    static let glyphButtonSize: CGFloat = 20

    /// The tint over a hovered group.
    static let groupHoverOpacity = 0.05

    static let hoverFade = Animation.easeOut(duration: 0.12)
    static let expansion = Animation.easeOut(duration: 0.15)
}
