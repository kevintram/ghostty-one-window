import SwiftUI

/// A minimal heads-up display for cycling through a window's workspaces in
/// most-recently-used order. It doesn't take focus or accept pointer input;
/// the keyboard-driven switcher coordinator owns the interaction.
struct WorkspaceSwitcherView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        GeometryReader { geometry in
            if let switcher = model.workspaceSwitcher {
                WorkspaceSwitcherPanel(model: model, switcher: switcher)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct WorkspaceSwitcherPanel: View {
    @ObservedObject var model: WorkspaceModel
    let switcher: WorkspaceModel.WorkspaceSwitcher

    private var workspaces: [Workspace] {
        switcher.workspaceIDs.compactMap { id in
            model.workspaces.first { $0.id == id }
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(workspaces) { workspace in
                if let tab = workspace.selectedTab {
                    WorkspaceSwitcherRow(
                        workspace: workspace,
                        tab: tab,
                        isSelected: workspace.id == switcher.selectedWorkspaceID)
                }
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7))
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace switcher")
    }
}

private struct WorkspaceSwitcherRow: View {
    let workspace: Workspace
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool

    private var name: String { workspace.name }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .imageScale(.large)
                .foregroundStyle(Color.accentColor)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.13))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
