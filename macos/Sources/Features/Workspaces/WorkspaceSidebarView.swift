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
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Workspaces") {
                    ForEach(group.workspaces) { workspace in
                        Label(workspace.name, systemImage: "rectangle.stack")
                            .tag(workspace.id)
                    }
                }
            }
            .listStyle(.sidebar)

            HStack {
                Button {
                    NSApp.sendAction(#selector(TerminalController.newWorkspace(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Workspace")

                Spacer()
            }
            .padding(8)
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { group.selectedID },
            set: { id in
                guard let id else { return }
                group.select(id)
            }
        )
    }
}
