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
                        WorkspaceRow(name: workspace.name, isSelected: workspace.id == group.selectedID)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A workspace row, styled like the sidebar list's own selection.
private struct WorkspaceRow: View {
    let name: String
    let isSelected: Bool

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
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.13))
            }
        }
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
