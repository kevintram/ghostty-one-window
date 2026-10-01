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
