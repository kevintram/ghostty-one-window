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

/// The workspace list, laid out by hand rather than with `List` so rows can
/// be dragged to reorder them, sliding aside like the tab strip's tabs. The
/// rows draw the selection from the model.
private struct WorkspaceListView: View {
    @ObservedObject var model: WorkspaceModel
    let controller: Weak<TerminalController>
    let topInset: CGFloat

    /// The workspace a tab dragged out of a tab strip would be dropped on.
    @State private var dropTarget: UUID?

    /// Where the rows start in the list, to find the row under a drop.
    @State private var rowsTop: CGFloat = 0

    private typealias Drag = WorkspaceModel.ReorderDrag

    private var drag: Drag? { model.workspaceDrag }

    private static let rowHeight: CGFloat = 32
    private static let slideDuration = 0.15
    private static let slide = Animation.easeOut(duration: slideDuration)
    private static let coordinateSpace = "WorkspaceList"

    // The metrics match the native sidebar list this replaced.

    var body: some View {
        // A workspace dragged out of the sidebar leaves it until the drag
        // ends. One dragged in from another window shows as selected, as it
        // will be.
        let selected = model.incomingWorkspace?.id ?? model.selectedWorkspaceID
        let rows = displayedWorkspaces.filter { phase(of: $0.id) != .draggingOut }

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

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, workspace in
                    let isRenaming = model.renaming == .workspace(workspace.id)
                    // Every workspace in the list has a tab, which names it
                    // unless it has a custom name.
                    if let tab = workspace.selectedTab {
                        WorkspaceRow(
                            workspace: workspace,
                            tab: tab,
                            isSelected: workspace.id == selected,
                            isDropTarget: workspace.id == dropTarget,
                            isRenaming: isRenaming,
                            select: { controller.value?.selectWorkspace(workspace.id) },
                            close: { controller.value?.close(workspace: workspace.id) },
                            endRenaming: { controller.value?.endRenamingWorkspace(workspace.id, name: $0) })
                            .frame(height: Self.rowHeight)
                            .offset(y: offset(at: index))
                            // The dragged row tracks the pointer; the others slide.
                            .animation(phase(of: workspace.id) == .following ? nil : Self.slide, value: offset(at: index))
                            .zIndex(phase(of: workspace.id) == nil ? 0 : 1)
                            // Clicks in the name field while renaming position the cursor.
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged { _ in beginDrag(workspace.id) },
                                including: isRenaming ? .subviews : .all)
                            .contextMenu { menu(for: workspace) }
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

    /// The workspace's context menu. It acts on the workspace, which it
    /// doesn't select.
    @ViewBuilder
    private func menu(for workspace: Workspace) -> some View {
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

    // MARK: Reordering

    // Pressing a row selects its workspace right away, like a tab, so a
    // click is just a drag that doesn't go anywhere. Dragging moves the row
    // with the pointer while the rows it passes slide into its place, and
    // the workspaces reorder on release. Double-clicking renames it.
    //
    // The rest of the drag is followed by `PressDragTracker` and drawn from
    // the model's `workspaceDrag`. The row is found by ID each time, since
    // workspaces can come and go during the drag (e.g. when a last terminal
    // exits).
    //
    // Dragging a row out of the sidebar sideways hands off to a system drag,
    // which every window's sidebar accepts (see `WorkspaceDragOut`). Dragged
    // back over the sidebar, the row rejoins it under the pointer until it's
    // dropped or leaves again. Over another window's sidebar, it joins that
    // sidebar the same way, after its rows.

    private func beginDrag(_ id: UUID) {
        // The gesture also reports every move; only the press begins a drag.
        guard let press = NSApp.currentEvent, press.type == .leftMouseDown else { return }

        controller.value?.selectWorkspace(id)
        if press.clickCount == 2 {
            controller.value?.beginRenamingWorkspace(id)
            return
        }

        model.workspaceDrag = Drag(id: id)

        let model = model
        let controller = controller
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

            model.workspaceDrag = Drag(id: id, offset: Self.slots(of: model).clamped(translation.height, from: from))
            return true
        } released: { [weak model] translation in
            guard let model else { return }
            withAnimation(Self.slide) {
                if let from = model.workspaceIndex(of: id) {
                    let slots = Self.slots(of: model)
                    let offset = slots.clamped(translation.height, from: from)
                    model.moveWorkspace(id, to: slots.destination(from: from, offset: offset))
                }
                model.workspaceDrag = nil
            }
        } cancelled: { [weak model] in
            withAnimation(Self.slide) { model?.workspaceDrag = nil }
        }
    }

    /// How far beside the sidebar the pointer can stray before the row is
    /// dragged out of it.
    private static let detachDistance: CGFloat = 16

    /// The hosting view of the sidebar that was pressed.
    private static func sidebarHost(at event: NSEvent) -> NSView? {
        guard let frameView = event.window?.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { return nil }
        return sequence(first: hit, next: \.superview).first { $0 is NSHostingView<WorkspaceSidebarView> }
    }

    /// The workspaces, then a workspace being dragged in from another window.
    private var displayedWorkspaces: [Workspace] {
        model.workspaces + (model.incomingWorkspace.map { [$0] } ?? [])
    }

    private static func slots(of model: WorkspaceModel) -> ReorderSlots {
        ReorderSlots(count: model.workspaces.count + (model.incomingWorkspace == nil ? 0 : 1), stride: rowHeight)
    }

    private func index(of id: UUID) -> Int? {
        displayedWorkspaces.firstIndex { $0.id == id }
    }

    /// The drag phase of the workspace, if it's the one being dragged.
    private func phase(of id: UUID) -> Drag.Phase? {
        drag?.id == id ? drag?.phase : nil
    }

    /// How far the row is drawn from its slot during a drag.
    private func offset(at index: Int) -> CGFloat {
        guard let drag, drag.phase != .draggingOut, let from = self.index(of: drag.id) else { return 0 }
        return Self.slots(of: model).offset(of: index, draggingFrom: from, by: drag.offset)
    }
}

// MARK: Dropping

// Drops come from a tab dragged out of a tab strip, onto the workspace it
// moves to, or from a workspace dragged out of a sidebar: this one's,
// rejoining it, or another window's, joining it after its rows. A dragged
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
        let to = Self.slots(of: model).destination(from: from, offset: drag.offset)
        model.workspaceDrag = Drag(id: id, offset: CGFloat(to - from) * Self.rowHeight, phase: .settling)

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
    /// or shows a dragged workspace centered under the pointer. It joins the
    /// sidebar, making room for itself, if it isn't in it already.
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
            let slots = Self.slots(of: model)
            let center = rowsTop + (CGFloat(from) + 0.5) * Self.rowHeight
            model.workspaceDrag = Drag(id: id, offset: slots.clamped(info.location.y - center, from: from))
        }
    }

    /// The workspace whose row is at `point`.
    private func workspace(at point: CGPoint) -> UUID? {
        let index = Int(((point.y - rowsTop) / Self.rowHeight).rounded(.down))
        return model.workspaces.indices.contains(index) ? model.workspaces[index].id : nil
    }
}

/// A workspace row, styled like a sidebar list's own selection: highlighted
/// edge to edge within the sidebar's 10pt inset, with the name in bold.
private struct WorkspaceRow: View {
    let workspace: Workspace

    /// The workspace's current tab, observed since its title names the
    /// workspace without a custom name.
    @ObservedObject var tab: TerminalTab

    let isSelected: Bool
    let isDropTarget: Bool
    let isRenaming: Bool
    let select: () -> Void
    let close: () -> Void
    let endRenaming: (_ name: String?) -> Void

    @State private var hovering = false

    private var name: String { workspace.name }

    var body: some View {
        HStack(spacing: 6.5) {
            Image(systemName: "rectangle.stack")
                .imageScale(.large)
                .foregroundStyle(isDropTarget ? Color.white : Color.accentColor)
            if isRenaming {
                InlineTitleField("Workspace Name", title: name, end: endRenaming)
                    .fontWeight(.bold)
            } else {
                Text(name)
                    .fontWeight(isSelected ? .bold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // In the name's trailing space, so it only cuts a long name's
            // end shorter. Closing the last workspace closes the window.
            if hovering && !isRenaming && !isDropTarget {
                Spacer(minLength: 0)
                HoverCloseButton(action: close)
                    // VoiceOver closes the workspace with the row's action.
                    .accessibilityHidden(true)
            }
        }
        // A drop target is filled with the accent color, like Finder's.
        .foregroundStyle(isDropTarget ? Color.white : Color.primary)
        .padding(.horizontal, 8.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor)
            } else if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.13))
            }
        }
        .contentShape(Rectangle())
        .onMiddleClick { close() }
        .onHover { hovering = $0 }
        .hoverTooltip(name, minWidth: 60)
        // One button for VoiceOver, except while renaming, when the name
        // field must stay reachable.
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityAddTraits(isRenaming ? [] : isSelected ? [.isButton, .isSelected] : .isButton)
        // Pointer selection happens in the list's drag gesture, on press.
        .accessibilityAction { select() }
        .accessibilityAction(named: "Close Workspace", close)
    }
}
