import AppKit
import GhosttyKit

// A window holds the tabs of all of its workspaces in its `workspaceModel`.
// Only the selected tab's split tree is in the window: it's the controller's
// `surfaceTree`, which the base class and the terminal view work on. The
// other tabs' terminals keep running outside the window, occluded and
// unfocused. Selecting a tab swaps its tree into `surfaceTree`.

extension TerminalController {
    /// Whether this window has tabs, i.e. it got the workspace layout when
    /// it loaded (see `canHostWorkspaces`). Windows without it open new tabs
    /// as new windows.
    var supportsTabs: Bool {
        window?.contentViewController is WorkspaceSplitViewController
    }

    /// Whether a just-loaded window can host workspaces. The sidebar sits
    /// under the titlebar beside the window buttons, so windows without a
    /// titlebar (hidden titlebar, `window-decoration = false`) can't.
    var canHostWorkspaces: Bool {
        guard let window = window as? TerminalWindow,
              !(window is HiddenTitlebarTerminalWindow) else { return false }
        return window.styleMask.contains(.titled)
    }

    /// The tab shown in the window.
    var selectedTab: TerminalTab? {
        workspaceModel.selectedTab
    }

    // MARK: Selecting

    /// Shows the given tab in the window, selecting its workspace too.
    func selectTab(_ tab: TerminalTab) {
        guard tab !== selectedTab, workspaceModel.contains(tab) else { return }

        let previous = selectedTab
        workspaceModel.renaming = nil
        workspaceModel.select(tab)
        if let previous { hideSurfaces(of: previous) }

        titleOverride = tab.titleOverride
        surfaceTree = tab.surfaceTree

        // Focus what was focused in the tab. The terminal view only reports
        // focus once the surface is in the window and first responder, so
        // update the title and appearance for it now.
        let focus = tab.focusedSurface.flatMap { tab.surfaceTree.contains($0) ? $0 : nil }
            ?? tab.surfaceTree.root?.leftmostLeaf()
        focusedSurfaceDidChange(to: focus)
        pwdDidChange(to: focus?.pwd.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
        if let focus {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focus)
            }
        }
    }

    /// Selects the workspace's last selected tab.
    func selectWorkspace(_ id: UUID) {
        guard let tab = workspaceModel.workspaces.first(where: { $0.id == id })?.selectedTab else { return }
        selectTab(tab)
    }

    /// Selects the workspace `offset` positions away, wrapping around.
    private func selectAdjacentWorkspace(offset: Int) {
        let workspaces = workspaceModel.workspaces
        guard workspaces.count > 1,
              let id = workspaceModel.selectedWorkspaceID,
              let index = workspaceModel.workspaceIndex(of: id) else { return }
        let count = workspaces.count
        selectWorkspace(workspaces[((index + offset) % count + count) % count].id)
    }

    /// Unfocuses and occludes a tab's terminals as it leaves the window, so
    /// they stop rendering until it's shown again.
    func hideSurfaces(of tab: TerminalTab) {
        for view in tab.surfaceTree {
            view.focusDidChange(false)
            if let surface = view.surface {
                ghostty_surface_set_occlusion(surface, false)
                view.isWindowVisible = false
            }
        }
    }

    // MARK: Adding

    /// Adds a tab with a new terminal to a workspace, the selected one by
    /// default, and selects it. It goes after the selected tab or at the
    /// end, following `window-new-tab-position`.
    @discardableResult
    func addTab(
        withBaseConfig config: Ghostty.SurfaceConfiguration? = nil,
        inWorkspace id: UUID? = nil
    ) -> TerminalTab? {
        guard let app = ghostty.app,
              let id = id ?? workspaceModel.selectedWorkspaceID else { return nil }

        let tab = TerminalTab(surfaceTree: .init(view: Ghostty.SurfaceView(app, baseConfig: config)))
        var index: Int?
        if ghostty.config.windowNewTabPosition != "end",
           id == workspaceModel.selectedWorkspaceID,
           let current = workspaceModel.tabs.firstIndex(where: { $0 === selectedTab }) {
            index = current + 1
        }

        workspaceModel.insert(tab, inWorkspace: id, at: index)
        selectTab(tab)
        return tab
    }

    // MARK: Closing

    /// Closes a tab, asking for confirmation if any of its terminals has a
    /// running process. The window's last tab closes the window.
    func close(tab: TerminalTab) {
        guard workspaceModel.contains(tab) else { return }

        guard workspaceModel.allTabs.count > 1 else {
            closeWindow(nil)
            return
        }

        guard tab.surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately(tab)
            return
        }

        // Show the tab being asked about.
        selectTab(tab)
        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately(tab)
        }
    }

    /// Closes a tab, the selected one by default, without confirmation (see
    /// `detach` for what's selected instead). The window's last tab closes
    /// the window. Undoing it puts the tab back.
    func closeTabImmediately(_ tab: TerminalTab? = nil, registerRedo: Bool = true) {
        guard let tab = tab ?? selectedTab,
              let location = workspaceModel.location(of: tab) else { return }
        guard workspaceModel.allTabs.count > 1 else {
            closeWindowImmediately()
            return
        }

        let workspace = workspaceModel.workspaces[location.workspace]
        let wasSelected = tab === selectedTab

        // The undo keeps the tab, and so its terminals, alive until it expires.
        if let undoManager {
            let order = workspaceModel.workspaces.map(\.id)
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                target.reinsert(
                    tab,
                    at: location.tab,
                    inWorkspace: workspace.id,
                    customName: workspace.customName,
                    workspaceOrder: order,
                    select: wasSelected)

                if registerRedo {
                    undoManager.registerUndo(
                        withTarget: target,
                        expiresAfter: target.undoExpiration
                    ) { target in
                        target.closeTabImmediately(tab)
                    }
                }
            }
        }

        detach(tab)

        // Like closing a window, this ends requests its terminals can no
        // longer present.
        for surface in tab.surfaceTree {
            cancelPendingClipboardConfirmation(for: surface)
        }
    }

    /// Takes a tab out of the window. If it's the shown tab, the tab to its
    /// right in its workspace is selected, else the one to its left; if it
    /// was the workspace's last tab, the workspace goes and the next
    /// workspace (else the previous one) is selected.
    private func detach(_ tab: TerminalTab) {
        if tab === selectedTab, let next = tabToSelect(afterDetaching: tab) {
            selectTab(next)
        }
        workspaceModel.remove(tab)
    }

    private func tabToSelect(afterDetaching tab: TerminalTab) -> TerminalTab? {
        guard let location = workspaceModel.location(of: tab) else { return nil }
        let workspaces = workspaceModel.workspaces
        let tabs = workspaces[location.workspace].tabs
        if location.tab + 1 < tabs.count { return tabs[location.tab + 1] }
        if location.tab > 0 { return tabs[location.tab - 1] }

        let neighbor = location.workspace + 1 < workspaces.count ? location.workspace + 1 : location.workspace - 1
        return workspaces.indices.contains(neighbor) ? workspaces[neighbor].selectedTab : nil
    }

    /// Puts a closed tab back, recreating its workspace if that was its
    /// last tab, in its place in `workspaceOrder`.
    private func reinsert(
        _ tab: TerminalTab,
        at index: Int,
        inWorkspace id: UUID,
        customName: String?,
        workspaceOrder: [UUID],
        select: Bool
    ) {
        guard !workspaceModel.contains(tab) else { return }

        if workspaceModel.workspaceIndex(of: id) == nil {
            // After the nearest workspace that preceded it and still exists.
            let preceding = workspaceOrder.prefix { $0 != id }.reversed()
            let position = preceding.lazy
                .compactMap { self.workspaceModel.workspaceIndex(of: $0) }
                .first.map { $0 + 1 } ?? 0
            workspaceModel.addWorkspace(id: id, customName: customName, at: position)
        }

        workspaceModel.insert(tab, inWorkspace: id, at: index)
        if select { selectTab(tab) }
    }

    /// Closes a terminal of a tab that isn't shown, e.g. when its process
    /// exits. If it needs confirmation, its tab is shown first. Like closing
    /// a shown terminal, it can be undone.
    func closeSurfaceInHiddenTab(_ surface: Ghostty.SurfaceView, withConfirmation: Bool) {
        guard let tab = workspaceModel.tab(owning: surface),
              tab !== selectedTab,
              let node = tab.surfaceTree.root?.node(view: surface) else { return }

        if withConfirmation {
            selectTab(tab)
            closeSurface(surface, withConfirmation: true)
            return
        }

        let tree = tab.surfaceTree.removing(node)
        guard !tree.isEmpty else {
            closeTabImmediately(tab)
            return
        }

        // The undo keeps the surface alive, but its requests end now, as
        // when closing a shown terminal.
        cancelPendingClipboardConfirmation(for: surface)

        let oldTree = tab.surfaceTree
        workspaceModel.setSurfaceTree(tree, of: tab)
        if tab.focusedSurface.map({ !tree.contains($0) }) ?? true {
            tab.focusedSurface = tree.root?.leftmostLeaf()
        }
        registerSurfaceTreeUndo(from: oldTree, to: tree, undoAction: "Close Terminal")
    }

    // MARK: Moving

    /// Moves a tab to the end of another workspace and follows it there,
    /// selecting the tab and its new workspace. The workspace it left shows
    /// its neighbor when switched back to, or is removed if it was its only
    /// tab.
    func moveTab(_ tab: TerminalTab, toWorkspace id: UUID) {
        guard let source = workspaceModel.workspace(of: tab),
              source.id != id,
              workspaceModel.workspaceIndex(of: id) != nil else { return }
        selectTab(tab)
        workspaceModel.transfer(tab, toWorkspace: id)
    }

    /// Moves a tab into a new window of its own, in a workspace named after
    /// the one it left. It stays the same tab, with its terminals, focus and
    /// title. Returns false if it's the window's only tab.
    ///
    /// This window's undo history is cleared: its entries for the tab (its
    /// creation, its split changes) would act on this window rather than
    /// the tab's new one. Entries expire after a few seconds anyway.
    @discardableResult
    func moveTabToNewWindow(_ tab: TerminalTab) -> Bool {
        guard workspaceModel.allTabs.count > 1,
              let workspace = workspaceModel.workspace(of: tab) else { return false }

        detach(tab)

        // Like the native action this replaces, this can't be undone: undoing
        // the new window would close the tab rather than move it back.
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        let newController = TerminalController.newWindow(
            ghostty,
            tree: tab.surfaceTree,
            inheritBackgroundOpacity: isBackgroundOpaque)
        let newWorkspace = Workspace(id: UUID(), customName: workspace.customName, tabs: [tab], selectedTabID: tab.id)
        newController.adoptWorkspaces([newWorkspace], selectedWorkspaceID: newWorkspace.id)
        undoManager?.removeAllActions(withTarget: self)
        return true
    }

    /// Takes over workspaces from elsewhere (a closed window being restored
    /// by undo, a tab moved from another window), with the selected tab's
    /// title and focus. The controller must have been created with the
    /// selected tab's split tree, which replaces the tab it was created with.
    func adoptWorkspaces(_ workspaces: [Workspace], selectedWorkspaceID: UUID?) {
        workspaceModel.replaceWorkspaces(workspaces, selectedWorkspaceID: selectedWorkspaceID)
        titleOverride = selectedTab?.titleOverride

        guard let focus = selectedTab?.focusedSurface ?? surfaceTree.first else { return }
        focusedSurface = focus
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: focus)
        }
    }

    // MARK: Renaming

    /// Sets a tab's title override. The shown tab's goes through the
    /// controller, which also titles the window.
    func setTitleOverride(_ title: String?, of tab: TerminalTab) {
        if tab === selectedTab {
            titleOverride = title
        } else {
            tab.titleOverride = title
        }
    }

    /// Ends renaming a tab in the tab strip, setting its title to `title`,
    /// or leaving it if nil (cancelled). An empty title restores the
    /// terminal's own. Keyboard focus goes back to the terminal.
    func endRenamingTab(_ tab: TerminalTab, title: String?) {
        endRenaming(.tab(tab.id))
        if let title { setTitleOverride(title.isEmpty ? nil : title, of: tab) }
    }

    /// Starts renaming a workspace in the sidebar, showing the sidebar if
    /// it's collapsed.
    func beginRenamingWorkspace(_ id: UUID) {
        guard workspaceModel.workspaceIndex(of: id) != nil else { return }
        workspaceModel.isSidebarCollapsed = false
        workspaceModel.renaming = .workspace(id)
    }

    /// Ends renaming a workspace, naming it `name`, or leaving it if nil
    /// (cancelled). An empty name names it after its current tab again.
    /// Keyboard focus goes back to the terminal.
    func endRenamingWorkspace(_ id: UUID, name: String?) {
        endRenaming(.workspace(id))
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            workspaceModel.renameWorkspace(id, to: trimmed.isEmpty ? nil : trimmed)
        }
    }

    /// Stops renaming `renaming` and gives keyboard focus back to the
    /// terminal, also when the rename was already stopped (e.g. by switching
    /// apps) so the terminal has it when the window is key again. If another
    /// rename took over, the focus is that rename's.
    private func endRenaming(_ renaming: WorkspaceModel.Renaming) {
        switch workspaceModel.renaming {
        case renaming: workspaceModel.renaming = nil
        case nil: break
        default: return
        }
        if let focusedSurface { window?.makeFirstResponder(focusedSurface) }
    }

    // MARK: First Responder

    /// Renames the selected workspace.
    @IBAction func renameWorkspace(_ sender: Any?) {
        guard let id = workspaceModel.selectedWorkspaceID else { return }
        beginRenamingWorkspace(id)
    }

    @IBAction func newWorkspace(_ sender: Any?) {
        // ⌘N used to be New Window. In a window that can't have tabs
        // (hidden titlebar), it still is. Our `newWindow` needs a focused
        // surface to inherit from; without one, open a plain window.
        guard supportsTabs, ghostty.app != nil else {
            if focusedSurface?.surface != nil {
                newWindow(sender)
            } else {
                (NSApp.delegate as? AppDelegate)?.newWindow(sender)
            }
            return
        }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = focusedSurface?.pwd
        addTab(withBaseConfig: config, inWorkspace: workspaceModel.addWorkspace())
    }

    /// Selects workspace `sender.tag` (1-based), or the last one for 9.
    @IBAction func selectWorkspaceByNumber(_ sender: NSMenuItem) {
        guard let workspace = workspaceNumbered(sender.tag) else { return }
        selectWorkspace(workspace.id)
    }

    /// Whether the workspace for a numbered menu item exists. When it
    /// doesn't, the item is disabled so its key goes to the terminal.
    func canSelectWorkspace(numbered number: Int) -> Bool {
        workspaceNumbered(number) != nil
    }

    private func workspaceNumbered(_ number: Int) -> Workspace? {
        let workspaces = workspaceModel.workspaces
        if number == 9 { return workspaces.last }
        return workspaces.indices.contains(number - 1) ? workspaces[number - 1] : nil
    }

    @IBAction func selectNextWorkspace(_ sender: Any?) {
        selectAdjacentWorkspace(offset: 1)
    }

    @IBAction func selectPreviousWorkspace(_ sender: Any?) {
        selectAdjacentWorkspace(offset: -1)
    }
}
