import SwiftUI

/// The workspace sidebar shown in every tab window. All of a group's tab
/// windows render the same shared `WorkspaceWindowGroup`. The sidebar is
/// empty until the tab has been assigned to a group.
struct WorkspaceSidebarView: View {
    @ObservedObject var membership: WorkspaceMembership

    var body: some View {
        if let group = membership.group {
            WorkspaceListView(group: group)
        } else {
            Color.clear
        }
    }
}

/// The workspace list, laid out by hand rather than with `List` so rows can
/// be dragged to reorder them, sliding aside like the tab strip's tabs.
///
/// The selection is drawn by the rows from `group.selectedID`: every tab
/// window has its own copy of this list, and a list's own selection state
/// would go stale as the selection changes in code or in hidden tab windows.
private struct WorkspaceListView: View {
    @ObservedObject var group: WorkspaceWindowGroup

    /// The workspace a tab dragged out of the tab strip would be dropped on.
    @State private var dropTarget: UUID?

    private var drag: WorkspaceWindowGroup.WorkspaceDrag? { group.workspaceDrag }

    private static let rowHeight: CGFloat = 32
    private static let slide = Animation.easeOut(duration: 0.15)

    // The metrics match the native sidebar list this replaced.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Workspaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 2.5)
                    .padding(.bottom, 2)

                ForEach(Array(group.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    WorkspaceRow(
                        name: workspace.name,
                        isSelected: workspace.id == group.selectedID,
                        isDropTarget: workspace.id == dropTarget,
                        select: { group.select(workspace.id) })
                        .frame(height: Self.rowHeight)
                        .offset(y: offset(at: index))
                        // The dragged row tracks the pointer; the others slide.
                        .animation(drag?.id == workspace.id ? nil : Self.slide, value: offset(at: index))
                        .zIndex(drag?.id == workspace.id ? 1 : 0)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in beginDrag(workspace.id) })
                        .onDrop(
                            of: [.ghosttyWorkspaceTab],
                            delegate: TabDropDelegate(workspace: workspace.id, group: group, target: $dropTarget))
                }
            }
            .padding(.horizontal, 10)
        }
    }

    // MARK: Reordering

    // Pressing a row selects its workspace right away, like a tab, so a
    // click is just a drag that doesn't go anywhere. Dragging moves the row
    // with the pointer while the rows it passes slide into its place, and
    // the workspaces reorder on release.
    //
    // Selecting shows another tab window, so the rest of the drag is
    // followed by `PressDragTracker` and drawn from the group's shared
    // `workspaceDrag`. The row is found by ID each time, since workspaces
    // can come and go during the drag (e.g. when a last terminal exits).

    private func beginDrag(_ id: UUID) {
        // The gesture also reports every move; only the press begins a drag.
        guard let press = NSApp.currentEvent, press.type == .leftMouseDown else { return }

        group.select(id)
        group.workspaceDrag = .init(id: id)

        let group = group
        PressDragTracker.begin(from: press) { [weak group] _, translation in
            guard let group else { return false }
            guard let from = Self.index(of: id, in: group) else {
                // The workspace is gone.
                group.workspaceDrag = nil
                return false
            }
            group.workspaceDrag = .init(id: id, offset: Self.slots(of: group).clamped(translation.height, from: from))
            return true
        } released: { [weak group] translation in
            guard let group else { return }
            withAnimation(Self.slide) {
                if let from = Self.index(of: id, in: group) {
                    let slots = Self.slots(of: group)
                    let offset = slots.clamped(translation.height, from: from)
                    group.moveWorkspace(id, to: slots.destination(from: from, offset: offset))
                }
                group.workspaceDrag = nil
            }
        } cancelled: { [weak group] in
            withAnimation(Self.slide) { group?.workspaceDrag = nil }
        }
    }

    private static func index(of id: UUID, in group: WorkspaceWindowGroup) -> Int? {
        group.workspaces.firstIndex { $0.id == id }
    }

    private static func slots(of group: WorkspaceWindowGroup) -> ReorderSlots {
        ReorderSlots(count: group.workspaces.count, stride: rowHeight)
    }

    /// How far the row is drawn from its slot during a drag.
    private func offset(at index: Int) -> CGFloat {
        guard let drag, let from = Self.index(of: drag.id, in: group) else { return 0 }
        return Self.slots(of: group).offset(of: index, draggingFrom: from, by: drag.offset)
    }
}

/// Accepts a tab dragged out of the tab strip, moving it to the row's
/// workspace. Dropped on its own workspace, it goes back where it was.
private struct TabDropDelegate: DropDelegate {
    let workspace: UUID
    let group: WorkspaceWindowGroup
    @Binding var target: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        draggedTab != nil
    }

    func dropEntered(info: DropInfo) {
        target = workspace
    }

    func dropExited(info: DropInfo) {
        if target == workspace { target = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let window = draggedTab else { return false }
        group.moveTab(window, toWorkspace: workspace)
        return true
    }

    /// The tab being dragged out of this group's tab strip.
    private var draggedTab: NSWindow? {
        guard let drag = group.tabDrag, drag.phase == .draggingOut else { return nil }
        return group.tabs.first { $0.id == drag.id }?.window
    }
}

/// A workspace row, styled like a sidebar list's own selection: highlighted
/// edge to edge within the sidebar's 10pt inset, with the name in bold.
private struct WorkspaceRow: View {
    let name: String
    let isSelected: Bool
    let isDropTarget: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 6.5) {
            Image(systemName: "rectangle.stack")
                .imageScale(.large)
                .foregroundStyle(isDropTarget ? Color.white : Color.accentColor)
            Text(name).fontWeight(isSelected ? .bold : .regular)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // Pointer selection happens in the list's drag gesture, on press.
        .accessibilityAction { select() }
    }
}
