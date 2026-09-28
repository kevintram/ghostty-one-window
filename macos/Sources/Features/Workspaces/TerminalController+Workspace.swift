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
    /// default, and selects it. It goes right after `anchor` if given, else
    /// after the selected tab or at the end, following
    /// `window-new-tab-position`.
    @discardableResult
    func addTab(
        withBaseConfig config: Ghostty.SurfaceConfiguration? = nil,
        inWorkspace id: UUID? = nil,
        after anchor: TerminalTab? = nil
    ) -> TerminalTab? {
        // Checked before the terminal starts: a tab left out of the model
        // would keep it running unseen.
        guard let app = ghostty.app,
              let id = id ?? workspaceModel.selectedWorkspaceID,
              workspaceModel.workspaceIndex(of: id) != nil else { return nil }

        let tab = TerminalTab(surfaceTree: .init(view: Ghostty.SurfaceView(app, baseConfig: config)))
        var index: Int?
        if let anchor, let location = workspaceModel.location(of: anchor) {
            index = location.tab + 1
        } else if ghostty.config.windowNewTabPosition != "end",
                  id == workspaceModel.selectedWorkspaceID,
                  let current = workspaceModel.tabs.firstIndex(where: { $0 === selectedTab }) {
            index = current + 1
        }

        workspaceModel.insert(tab, inWorkspace: id, at: index)
        selectTab(tab)
        return tab
    }

    /// Adds a tab to a workspace, right after `anchor` if given, starting in
    /// the working directory of `anchor` (else the workspace's current tab).
    /// Undoing it closes the tab.
    @discardableResult
    func newTab(inWorkspace id: UUID, after anchor: TerminalTab? = nil) -> TerminalTab? {
        let source = anchor ?? workspaceModel.workspaces.first { $0.id == id }?.selectedTab
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = source?.focusedSurface?.pwd
        let previous = selectedTab
        guard let tab = addTab(withBaseConfig: config, inWorkspace: id, after: anchor) else { return nil }
        registerUndoAddingTab(tab, previous: previous) { target in
            target.newTab(inWorkspace: id, after: anchor)
        }
        return tab
    }

    /// Adds a tab right after the given one, in its workspace.
    func newTab(after tab: TerminalTab) {
        guard let workspace = workspaceModel.workspace(of: tab) else { return }
        newTab(inWorkspace: workspace.id, after: tab)
    }

    /// Registers undo for adding a tab: closing it and showing `previous`,
    /// the tab shown before it (see `undoAddingTab`), with `redo` adding it
    /// again.
    ///
    /// If the user keeps the tab when asked, the undo is registered again
    /// once this one is over (registered during it, it would be a redo), so
    /// it can be retried.
    func registerUndoAddingTab(
        _ tab: TerminalTab,
        previous: TerminalTab?,
        redo: @escaping (TerminalController) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.setActionName("New Tab")
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            guard target.undoAddingTab(tab, previous: previous) else {
                guard target.workspaceModel.contains(tab) else { return }
                DispatchQueue.main.async {
                    target.registerUndoAddingTab(tab, previous: previous, redo: redo)
                }
                return
            }

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration,
                handler: redo)
        }
    }

    /// Undoes adding a tab: shows the tab that was shown before it, then
    /// closes it. Returns false if the tab stays: gone already, or kept by
    /// the user.
    ///
    /// It runs inside the undo, so it must finish there: a running process
    /// is confirmed with a modal alert rather than the usual sheet, and the
    /// close registers no undo of its own.
    private func undoAddingTab(_ tab: TerminalTab, previous: TerminalTab?) -> Bool {
        guard workspaceModel.contains(tab) else { return false }

        if tab.needsConfirmQuit {
            let alert = NSAlert()
            alert.messageText = "Close Tab?"
            alert.informativeText = Self.closeTabWarning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        if let previous { selectTab(previous) }
        undoManager?.disableUndoRegistration {
            closeTabImmediately(tab)
        }
        return true
    }

    // MARK: Closing

    /// Why closing a tab with a running process is confirmed.
    private static let closeTabWarning =
        "The terminal still has a running process. If you close the tab the process will be killed."

    /// Closes a tab, asking for confirmation if any of its terminals has a
    /// running process. The window's last tab closes the window. It doesn't
    /// select the tab.
    func close(tab: TerminalTab) {
        guard workspaceModel.contains(tab) else { return }

        guard workspaceModel.allTabs.count > 1 else {
            closeWindow(nil)
            return
        }

        guard tab.needsConfirmQuit else {
            closeTabImmediately(tab)
            return
        }

        // Asked without selecting the tab, e.g. closing a background tab from
        // its context menu, so the prompt names a tab that isn't shown.
        confirmClose(
            messageText: tab === selectedTab ? "Close Tab?" : "Close Tab “\(tab.title)”?",
            informativeText: Self.closeTabWarning
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

        // The undo keeps the tab, and so its terminals, alive until it expires.
        if let undoManager {
            let placement = TabPlacement(
                index: location.tab,
                workspace: workspace.id,
                customName: workspace.customName,
                workspaceOrder: workspaceModel.workspaces.map(\.id),
                wasShown: tab === selectedTab,
                wasCurrent: workspace.selectedTab === tab)
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                target.reinsert(tab, at: placement)

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

    /// Closes a workspace with all of its tabs, asking once if any of their
    /// terminals has a running process. If it's the shown workspace, the
    /// next workspace (else the previous one) is shown. The window's last
    /// workspace closes the window.
    func close(workspace id: UUID) {
        guard let index = workspaceModel.workspaceIndex(of: id) else { return }
        guard let neighbor = workspaceModel.neighborOfWorkspace(at: index) else {
            closeWindow(nil)
            return
        }

        close(
            workspaceModel.workspaces[index].tabs,
            showing: neighbor.selectedTab,
            actionName: "Close Workspace",
            informativeText: "A terminal in this workspace still has a running process. If you close it, the process will be killed.")
    }

    /// Closes every workspace but one, with all of their tabs.
    func closeOtherWorkspaces(than id: UUID) {
        guard let kept = workspaceModel.workspaces.first(where: { $0.id == id }) else { return }
        close(
            workspaceModel.workspaces.filter { $0.id != id }.flatMap(\.tabs),
            showing: kept.selectedTab,
            actionName: "Close Other Workspaces",
            informativeText: "A terminal in another workspace still has a running process. If you close it, the process will be killed.")
    }

    /// Closes the other tabs of the tab's workspace.
    func closeOtherTabs(than tab: TerminalTab) {
        close(
            workspaceModel.otherTabs(than: tab),
            showing: tab,
            actionName: "Close Other Tabs",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed.")
    }

    /// Closes the tabs to the right of the tab in its workspace.
    func closeTabs(rightOf tab: TerminalTab) {
        close(
            workspaceModel.tabs(rightOf: tab),
            showing: tab,
            actionName: "Close Tabs to the Right",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed.")
    }

    /// Closes several tabs as one action, asking once, titled after the
    /// action, if any of their terminals has a running process.
    private func close(
        _ tabs: [TerminalTab],
        showing replacement: TerminalTab?,
        actionName: String,
        informativeText: String
    ) {
        guard !tabs.isEmpty else { return }
        guard tabs.contains(where: \.needsConfirmQuit) else {
            closeImmediately(tabs, showing: replacement, actionName: actionName)
            return
        }

        confirmClose(messageText: "\(actionName)?", informativeText: informativeText) {
            self.closeImmediately(tabs, showing: replacement, actionName: actionName)
        }
    }

    /// Closes several tabs as one action, without confirmation. If the shown
    /// tab is among them, `replacement` is shown first, so the closing tabs
    /// aren't shown in turn. Workspaces left without tabs go. Undoing it puts
    /// the tabs back where they were, recreating their workspaces, and shows
    /// the tab that was shown.
    private func closeImmediately(_ tabs: [TerminalTab], showing replacement: TerminalTab?, actionName: String) {
        // Redone, some may already be gone.
        let tabs = tabs.filter(workspaceModel.contains)
        guard !tabs.isEmpty else { return }
        guard tabs.count < workspaceModel.allTabs.count else {
            closeWindowImmediately()
            return
        }

        let shown = selectedTab
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        // Registered before the tabs close so that, undone in reverse, it runs
        // once they're back: it shows the tab that was shown, and makes the
        // redo for the whole action (the tabs register none).
        if let undoManager {
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                if let shown { target.selectTab(shown) }

                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeImmediately(tabs, showing: replacement, actionName: actionName)
                }
            }
        }

        if let shown, let replacement, tabs.contains(where: { $0 === shown }) {
            selectTab(replacement)
        }

        // Each tab's undo puts it back, recreating its workspace if it was
        // gone; undone in reverse, they return in order.
        for tab in tabs {
            closeTabImmediately(tab, registerRedo: false)
        }
        undoManager?.setActionName(actionName)
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
        let tabs = workspaceModel.workspaces[location.workspace].tabs
        if location.tab + 1 < tabs.count { return tabs[location.tab + 1] }
        if location.tab > 0 { return tabs[location.tab - 1] }
        return workspaceModel.neighborOfWorkspace(at: location.workspace)?.selectedTab
    }

    /// Where a closed tab was, to put it back when the close is undone.
    private struct TabPlacement {
        let index: Int
        let workspace: UUID

        /// The workspace's custom name and the workspace order, to recreate
        /// the workspace if the tab was its last.
        let customName: String?
        let workspaceOrder: [UUID]

        /// Whether the tab was shown, or its workspace's current tab.
        let wasShown: Bool
        let wasCurrent: Bool
    }

    /// Puts a closed tab back where it was, recreating its workspace if that
    /// was its last tab, after the nearest workspace that preceded it and
    /// still exists. It's shown again, or its workspace's current tab again,
    /// if it was.
    private func reinsert(_ tab: TerminalTab, at placement: TabPlacement) {
        guard !workspaceModel.contains(tab) else { return }

        let id = placement.workspace
        if workspaceModel.workspaceIndex(of: id) == nil {
            let preceding = placement.workspaceOrder.prefix { $0 != id }.reversed()
            let position = preceding.lazy
                .compactMap { self.workspaceModel.workspaceIndex(of: $0) }
                .first.map { $0 + 1 } ?? 0
            workspaceModel.addWorkspace(id: id, customName: placement.customName, at: position)
        }

        workspaceModel.insert(tab, inWorkspace: id, at: placement.index)
        if placement.wasShown {
            selectTab(tab)
        } else if placement.wasCurrent {
            workspaceModel.makeCurrent(tab)
        }
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

    /// Moves a tab into a new workspace, at the end, and follows it there.
    func moveTabToNewWorkspace(_ tab: TerminalTab) {
        guard workspaceModel.contains(tab) else { return }
        moveTab(tab, toWorkspace: workspaceModel.addWorkspace())
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

    /// Starts renaming a tab in the tab strip, which shows while it is.
    func beginRenamingTab(_ tab: TerminalTab) {
        guard workspaceModel.contains(tab) else { return }
        workspaceModel.renaming = .tab(tab.id)
    }

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

    /// Closes the selected workspace.
    @IBAction func closeWorkspace(_ sender: Any?) {
        guard let id = workspaceModel.selectedWorkspaceID else { return }
        close(workspace: id)
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
