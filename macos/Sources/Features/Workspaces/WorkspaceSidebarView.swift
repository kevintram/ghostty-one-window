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

private struct WorkspaceListView: View {
    @ObservedObject var group: WorkspaceWindowGroup

    /// The workspace a tab dragged out of the tab strip would be dropped on.
    @State private var dropTarget: UUID?

    var body: some View {
        // The selection is drawn by the rows from `group.selectedID` rather
        // than by `List(selection:)`: every tab window has its own copy of
        // this list, and the underlying tables' own row selection state went
        // stale (e.g. several rows bold) as the selection changed in code or
        // in hidden tab windows.
        List {
            Section("Workspaces") {
                ForEach(group.workspaces) { workspace in
                    Button {
                        group.select(workspace.id)
                    } label: {
                        WorkspaceRow(
                            name: workspace.name,
                            isSelected: workspace.id == group.selectedID,
                            isDropTarget: workspace.id == dropTarget)
                    }
                    .buttonStyle(.plain)
                    .onDrop(
                        of: [.ghosttyWorkspaceTab],
                        delegate: TabDropDelegate(workspace: workspace.id, group: group, target: $dropTarget))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Accepts a tab dragged out of the tab strip, moving it to the row's
/// workspace. Its own workspace doesn't accept it.
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

    /// The tab being dragged out of this group's tab strip, unless it's
    /// already in this workspace.
    private var draggedTab: NSWindow? {
        guard let drag = group.tabDrag,
              drag.phase == .draggingOut,
              let window = group.tabs.first(where: { $0.id == drag.id })?.window,
              (window.windowController as? TerminalController)?.workspaceID != workspace else { return nil }
        return window
    }
}

/// A workspace row, styled like the sidebar list's own selection.
private struct WorkspaceRow: View {
    let name: String
    let isSelected: Bool
    let isDropTarget: Bool

    var body: some View {
        Label {
            Text(name).fontWeight(isSelected ? .bold : .regular)
        } icon: {
            Image(systemName: "rectangle.stack")
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        // The highlight reaches into the list's own row insets, like the
        // native selection: 32pt tall, inset 10pt from the sidebar's sides.
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.3))
            } else if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.13))
            }
        }
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
