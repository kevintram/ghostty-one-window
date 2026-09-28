import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Version 8

        /// The window's workspaces. The selected tab's split tree is
        /// `surfaceTree`, so it isn't repeated here: decoding a tree creates
        /// its terminals. Its workspace is the selected one.
        var workspaces: [WorkspaceState]?

        struct WorkspaceState: Codable {
            let customName: String?
            let tabs: [TabState]
            let selectedTab: Int
        }

        struct TabState: Codable {
            /// Nil for the window's selected tab, whose tree is `surfaceTree`.
            let surfaceTree: SplitTree<ViewType>?
            let focusedSurface: String?
            let titleOverride: String?
        }
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    @MainActor init(from controller: TerminalController) {
        let model = controller.workspaceModel
        let selected = model.selectedTab
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            workspaces: model.workspaces.map { workspace in
                WorkspaceState(
                    customName: workspace.customName,
                    tabs: workspace.tabs.map { tab in
                        TabState(
                            surfaceTree: tab === selected ? nil : tab.surfaceTree,
                            focusedSurface: tab.focusedSurface?.id.uuidString,
                            titleOverride: tab.titleOverride)
                    },
                    selectedTab: workspace.tabs.firstIndex { $0 === workspace.selectedTab } ?? 0)
            },
        )
    }
}

extension TerminalController {
    /// Restores the window's workspaces and their tabs. The controller was
    /// created with the selected tab's split tree, and its workspace becomes
    /// the selected one. Invalid state restores nothing, leaving that tab
    /// alone (see `isValid`).
    func restoreWorkspaces(_ saved: [TerminalRestorableState.WorkspaceState]?) {
        guard let saved, let current = selectedTab,
              Self.isValid(saved, selectedTree: current.surfaceTree) else { return }

        var workspaces: [Workspace] = []
        var selectedWorkspaceID: UUID?
        for savedWorkspace in saved {
            var workspace = Workspace(id: UUID(), customName: savedWorkspace.customName, tabs: [])
            for savedTab in savedWorkspace.tabs {
                guard let tree = savedTab.surfaceTree else {
                    workspace.tabs.append(current)
                    selectedWorkspaceID = workspace.id
                    continue
                }

                let tab = TerminalTab(
                    surfaceTree: tree,
                    focusedSurface: tree.first { $0.id.uuidString == savedTab.focusedSurface },
                    titleOverride: savedTab.titleOverride)
                hideSurfaces(of: tab)
                workspace.tabs.append(tab)
            }

            guard !workspace.tabs.isEmpty else { continue }
            let selectedIndex = workspace.tabs.indices.contains(savedWorkspace.selectedTab)
                ? savedWorkspace.selectedTab : 0
            let selected = workspace.id == selectedWorkspaceID ? current : workspace.tabs[selectedIndex]
            workspace.selectedTabID = selected.id
            workspaces.append(workspace)
        }

        guard let selectedWorkspaceID else { return }
        workspaceModel.replaceWorkspaces(workspaces, selectedWorkspaceID: selectedWorkspaceID)
    }

    /// Whether saved workspaces can be restored around the selected tab's
    /// tree: exactly one saved tab is the selected one, every other tab has
    /// terminals, and no terminal appears twice.
    private static func isValid(
        _ saved: [TerminalRestorableState.WorkspaceState],
        selectedTree: SplitTree<Ghostty.SurfaceView>
    ) -> Bool {
        let tabs = saved.flatMap(\.tabs)
        guard tabs.count(where: { $0.surfaceTree == nil }) == 1,
              tabs.allSatisfy({ !($0.surfaceTree?.isEmpty ?? false) }) else { return false }

        let ids = (tabs.compactMap(\.surfaceTree) + [selectedTree]).flatMap { $0.map(\.id) }
        return Set(ids).count == ids.count
    }
}
