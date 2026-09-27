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

    /// The row being dragged to reorder it, and how far it's been dragged.
    @GestureState(resetTransaction: Transaction(animation: Self.slide))
    private var drag: (id: UUID, offset: CGFloat)?

    private static let rowHeight: CGFloat = 32
    private static let slide = Animation.easeOut(duration: 0.15)
    private static let coordinateSpace = "WorkspaceList"

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
                        .gesture(reorderGesture(for: workspace.id))
                        .onDrop(
                            of: [.ghosttyWorkspaceTab],
                            delegate: TabDropDelegate(workspace: workspace.id, group: group, target: $dropTarget))
                }
            }
            .padding(.horizontal, 10)
            .coordinateSpace(name: Self.coordinateSpace)
        }
    }

    // MARK: Reordering

    // Unlike a tab, dragging a row doesn't select it, so the drag stays in
    // this window's sidebar and the workspaces reorder on release.

    // The row is found by ID each time, since workspaces can come and go
    // during the drag (e.g. when a workspace's last terminal exits).

    private func reorderGesture(for id: UUID) -> some Gesture {
        // Measured in the list, since the dragged row moves under the pointer.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.coordinateSpace))
            .updating($drag) { value, drag, _ in
                guard let from = index(of: id) else { return }
                drag = (id, clamped(value.translation.height, at: from))
            }
            .onEnded { value in
                guard let from = index(of: id) else { return }
                let to = dropIndex(from: from, offset: clamped(value.translation.height, at: from))
                withAnimation(Self.slide) { group.moveWorkspace(id, to: to) }
            }
    }

    private func index(of id: UUID) -> Int? {
        group.workspaces.firstIndex { $0.id == id }
    }

    /// Keeps a row dragged by `offset` within the list.
    private func clamped(_ offset: CGFloat, at index: Int) -> CGFloat {
        min(max(offset, -CGFloat(index) * Self.rowHeight),
            CGFloat(group.workspaces.count - 1 - index) * Self.rowHeight)
    }

    /// Where a row dragged by `offset` from `index` would land.
    private func dropIndex(from index: Int, offset: CGFloat) -> Int {
        min(max(index + Int((offset / Self.rowHeight).rounded()), 0), group.workspaces.count - 1)
    }

    /// How far the row is drawn from its slot: the dragged row by the drag,
    /// and the rows it has passed by one slot toward where it came from.
    private func offset(at index: Int) -> CGFloat {
        guard let drag, let from = self.index(of: drag.id) else { return 0 }
        if index == from { return drag.offset }

        let to = dropIndex(from: from, offset: drag.offset)
        if from < to, (from + 1...to).contains(index) { return -Self.rowHeight }
        if to < from, (to..<from).contains(index) { return Self.rowHeight }
        return 0
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
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }
}
