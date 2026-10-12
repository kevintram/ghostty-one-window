import Testing
@testable import Ghostty

@MainActor
struct WorkspaceModelTests {
    @Test func workspaceSwitcherCyclesThroughFrozenRecency() {
        let (model, workspaces, tabs) = makeModel()

        // Visit the third workspace, then the second. The MRU order is now
        // second, third, first even though sidebar order never changed.
        model.select(tabs[2])
        model.select(tabs[1])

        #expect(model.cycleWorkspaceSwitcher(offset: 1))
        #expect(model.workspaceSwitcher?.selectedWorkspaceID == workspaces[2].id)
        #expect(model.cycleWorkspaceSwitcher(offset: 1))
        #expect(model.workspaceSwitcher?.selectedWorkspaceID == workspaces[0].id)
        #expect(model.cycleWorkspaceSwitcher(offset: 1))
        #expect(model.workspaceSwitcher?.selectedWorkspaceID == workspaces[1].id)
        #expect(model.cycleWorkspaceSwitcher(offset: -1))
        #expect(model.workspaceSwitcher?.selectedWorkspaceID == workspaces[0].id)
    }

    @Test func workspaceSwitcherCommitsOrCancelsItsHighlight() {
        let (model, workspaces, _) = makeModel()

        #expect(model.cycleWorkspaceSwitcher(offset: 1))
        #expect(model.finishWorkspaceSwitcher(commit: true) == workspaces[1].id)
        #expect(model.workspaceSwitcher == nil)

        #expect(model.cycleWorkspaceSwitcher(offset: -1))
        #expect(model.workspaceSwitcher?.selectedWorkspaceID == workspaces[2].id)
        #expect(model.finishWorkspaceSwitcher(commit: false) == nil)
        #expect(model.workspaceSwitcher == nil)
    }

    @Test func workspaceSwitcherDoesNothingWithOneWorkspace() {
        let model = WorkspaceModel()
        let tab = TerminalTab(surfaceTree: .init())
        let workspace = Workspace(id: .init(), customName: nil, tabs: [tab], selectedTabID: tab.id)
        model.replaceWorkspaces([workspace], selectedWorkspaceID: workspace.id)

        #expect(!model.cycleWorkspaceSwitcher(offset: 1))
        #expect(model.workspaceSwitcher == nil)
    }

    @Test func removingAWorkspaceEndsAnOpenSwitcher() {
        let (model, workspaces, tabs) = makeModel()

        #expect(model.cycleWorkspaceSwitcher(offset: 1))
        model.transfer(tabs[1], toWorkspace: workspaces[0].id)

        #expect(model.workspaceSwitcher == nil)
        #expect(model.workspaces.map(\.id) == [workspaces[0].id, workspaces[2].id])
    }

    @Test func replacingWorkspacesFallsBackFromAnUnknownSelection() {
        let (model, workspaces, _) = makeModel()

        model.replaceWorkspaces(workspaces, selectedWorkspaceID: UUID())

        #expect(model.selectedWorkspaceID == workspaces[0].id)
        #expect(model.cycleWorkspaceSwitcher(offset: 1))
        #expect(model.workspaceSwitcher?.selectedWorkspaceID == workspaces[1].id)
    }

    @Test func workspacesStartCollapsedAndToggle() {
        let (model, workspaces, _) = makeModel()

        #expect(model.workspaces.map(\.isExpanded) == [false, false, false])
        model.toggleExpanded(ofWorkspace: workspaces[1].id)
        #expect(model.workspaces.map(\.isExpanded) == [false, true, false])
        model.toggleExpanded(ofWorkspace: workspaces[1].id)
        #expect(model.workspaces.map(\.isExpanded) == [false, false, false])

        let added = model.addWorkspace()
        #expect(model.workspaces.last?.id == added)
        #expect(model.workspaces.last?.isExpanded == false)
    }

    @Test func expandedWorkspaceStaysExpandedWhenTabsMoveIn() {
        let (model, workspaces, tabs) = makeModel()

        model.toggleExpanded(ofWorkspace: workspaces[0].id)
        model.transfer(tabs[1], toWorkspace: workspaces[0].id)

        #expect(model.workspaces[0].isExpanded == true)
        #expect(model.workspaces[0].tabs.map(\.id) == [tabs[0].id, tabs[1].id])
    }

    @Test func removingATabEndsRenamingItInTheSidebar() {
        let (model, workspaces, tabs) = makeModel()
        let extra = TerminalTab(surfaceTree: .init())
        model.insert(extra, inWorkspace: workspaces[0].id)

        model.renaming = .sidebarTab(extra.id)
        model.remove(extra)
        #expect(model.renaming == nil)

        model.renaming = .sidebarTab(tabs[2].id)
        model.select(tabs[0])
        model.removeWorkspace(workspaces[2].id)
        #expect(model.renaming == nil)
    }

    @Test func expandsAndCollapsesEveryWorkspaceAtOnce() {
        let (model, workspaces, _) = makeModel()
        model.toggleExpanded(ofWorkspace: workspaces[1].id)

        #expect(model.canSetAllExpanded(true))
        #expect(model.canSetAllExpanded(false))

        model.setAllExpanded(true)
        #expect(model.workspaces.map(\.isExpanded) == [true, true, true])
        #expect(!model.canSetAllExpanded(true))

        model.setAllExpanded(false)
        #expect(model.workspaces.map(\.isExpanded) == [false, false, false])
        #expect(!model.canSetAllExpanded(false))
    }

    @Test func tabListsRenameInPlaceAndWordTheTabsAfter() {
        let id = UUID()

        #expect(WorkspaceModel.TabList.strip.renaming(id) == .tab(id))
        #expect(WorkspaceModel.TabList.sidebar.renaming(id) == .sidebarTab(id))
        #expect(WorkspaceModel.TabList.strip.afterTitle == "to the Right")
        #expect(WorkspaceModel.TabList.sidebar.afterPhrase == "below")
    }

    private func makeModel() -> (WorkspaceModel, [Workspace], [TerminalTab]) {
        let model = WorkspaceModel()
        let tabs = (0..<3).map { _ in TerminalTab(surfaceTree: .init()) }
        let workspaces = tabs.map { tab in
            Workspace(id: .init(), customName: nil, tabs: [tab], selectedTabID: tab.id)
        }
        model.replaceWorkspaces(workspaces, selectedWorkspaceID: workspaces[0].id)
        return (model, workspaces, tabs)
    }
}
