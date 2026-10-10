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
    /// Returns false if there's no other workspace.
    @discardableResult
    func selectAdjacentWorkspace(offset: Int) -> Bool {
        guard let index = adjacentWorkspaceIndex(offset: offset) else { return false }
        selectWorkspace(workspaceModel.workspaces[index].id)
        return true
    }

    /// Selects the workspace numbered `number` from 1, or the last one if
    /// there are fewer, like `goto_tab`. Returns false if there's none.
    @discardableResult
    func selectWorkspace(number: Int) -> Bool {
        let workspaces = workspaceModel.workspaces
        guard number >= 1, !workspaces.isEmpty else { return false }
        selectWorkspace(workspaces[min(number, workspaces.count) - 1].id)
        return true
    }

    /// Selects the last workspace. Returns false if there's no workspace.
    @discardableResult
    func selectLastWorkspace() -> Bool {
        guard let last = workspaceModel.workspaces.last else { return false }
        selectWorkspace(last.id)
        return true
    }

    /// Opens or advances the window-local most-recently-used workspace
    /// switcher. Its split view owns the keyboard interaction and commit.
    @discardableResult
    func cycleWorkspaceSwitcher(offset: Int) -> Bool {
        let isStarting = workspaceModel.workspaceSwitcher == nil
        guard workspaceModel.cycleWorkspaceSwitcher(offset: offset) else { return false }

        guard let splitView = window?.contentViewController as? WorkspaceSplitViewController else {
            finishWorkspaceSwitcher(commit: true)
            return true
        }
        splitView.workspaceSwitcherDidCycle(isStarting: isStarting)
        return true
    }

    /// Dismisses the workspace switcher, optionally selecting its highlight.
    func finishWorkspaceSwitcher(commit: Bool) {
        guard let id = workspaceModel.finishWorkspaceSwitcher(commit: commit) else { return }
        selectWorkspace(id)
    }

    /// The index of the workspace `offset` positions from the selected one,
    /// wrapping around, or nil if there's no other workspace.
    private func adjacentWorkspaceIndex(offset: Int) -> Int? {
        let count = workspaceModel.workspaces.count
        guard count > 1,
              let id = workspaceModel.selectedWorkspaceID,
              let index = workspaceModel.workspaceIndex(of: id) else { return nil }
        // Reduced first, so a huge configured offset can't overflow.
        return (index + offset % count + count) % count
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

        let tab = TerminalTab(
            surfaceTree: .init(view: Ghostty.SurfaceView(app, baseConfig: config)),
            isRestorable: (config?.command ?? "") == "")
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

    /// Adds an empty workspace and returns its ID. Like a new tab, it goes
    /// right after `anchor` or at the end, following
    /// `window-new-tab-position`.
    private func addWorkspace(after anchor: UUID?) -> UUID {
        var index: Int?
        if ghostty.config.windowNewTabPosition != "end",
           let anchor, let anchorIndex = workspaceModel.workspaceIndex(of: anchor) {
            index = anchorIndex + 1
        }
        return workspaceModel.addWorkspace(at: index)
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

        recordingClose {
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
        recordingClose {
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
        recordingClose {
            registerSurfaceTreeUndo(from: oldTree, to: tree, undoAction: "Close Terminal")
        }
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

    /// Moves the selected workspace `offset` positions in the sidebar,
    /// wrapping around like `move_tab`. Returns false if there's no other
    /// workspace.
    @discardableResult
    func moveSelectedWorkspace(by offset: Int) -> Bool {
        guard let id = workspaceModel.selectedWorkspaceID,
              let index = adjacentWorkspaceIndex(offset: offset) else { return false }
        workspaceModel.moveWorkspace(id, to: index)
        return true
    }

    /// Moves the shown tab to the workspace `offset` positions away, wrapping
    /// around, and follows it there. Returns false if there's no other
    /// workspace.
    @discardableResult
    func moveSelectedTab(toWorkspaceBy offset: Int) -> Bool {
        guard let tab = selectedTab,
              let index = adjacentWorkspaceIndex(offset: offset) else { return false }
        moveTab(tab, toWorkspace: workspaceModel.workspaces[index].id)
        return true
    }

    /// Whether Merge All Windows has another window to merge.
    var canMergeAllWindows: Bool {
        supportsTabs && TerminalController.all.contains { $0 !== self && $0.supportsTabs }
    }

    /// Moves a tab into a new workspace, placed after its own (see
    /// `addWorkspace(after:)`), and follows it there.
    func moveTabToNewWorkspace(_ tab: TerminalTab) {
        guard let source = workspaceModel.workspace(of: tab) else { return }
        moveTab(tab, toWorkspace: addWorkspace(after: source.id))
    }

    /// Moves a tab into a new window of its own, in a workspace named after
    /// the one it left, with its top left corner at `position` if given. It
    /// stays the same tab, with its terminals, focus and title. Returns false
    /// if it's the window's only tab.
    ///
    /// Like the native action this replaces, this can't be undone: undoing
    /// the new window would close the tab rather than move it back.
    @discardableResult
    func moveTabToNewWindow(_ tab: TerminalTab, position: NSPoint? = nil) -> Bool {
        guard workspaceModel.allTabs.count > 1,
              let workspace = workspaceModel.workspace(of: tab) else { return false }

        release(tab)
        openWindow(
            with: Workspace(id: UUID(), customName: workspace.customName, tabs: [tab], selectedTabID: tab.id),
            position: position)
        return true
    }

    /// Moves a tab here from another window, into a workspace (the selected
    /// one by default) at `index` (the end by default), and shows it. It
    /// stays the same tab, with its terminals, focus and title. If it was the
    /// other window's last tab, that window closes. Like moving a tab into a
    /// new window, this can't be undone.
    func receive(
        _ tab: TerminalTab,
        from source: TerminalController,
        inWorkspace id: UUID? = nil,
        at index: Int? = nil
    ) {
        guard source !== self, source.workspaceModel.contains(tab),
              let id = id ?? workspaceModel.selectedWorkspaceID,
              workspaceModel.workspaceIndex(of: id) != nil else { return }

        source.release(tab)
        workspaceModel.insert(tab, inWorkspace: id, at: index)
        selectTab(tab)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Takes a tab out of the window to move it to another (see `detach`).
    /// The window's last tab closes the window, without closing the tab's
    /// terminals or registering an undo.
    ///
    /// The window's undo history is cleared: its entries for the tab (its
    /// creation, its split changes) would act on this window rather than
    /// the tab's new one. Entries expire after a few seconds anyway.
    private func release(_ tab: TerminalTab) {
        undoManager?.removeAllActions(withTarget: self)
        guard workspaceModel.allTabs.count > 1 else {
            workspaceModel.remove(tab)
            // An empty tree closes the window.
            surfaceTree = .init()
            return
        }
        detach(tab)
    }

    /// Moves a workspace, with its tabs, into a new window of its own, with
    /// its top left corner at `position`. Its tabs stay the same, with their
    /// terminals, focus and titles. Returns false if it's the window's only
    /// workspace. Like moving a tab into a new window, this can't be undone.
    @discardableResult
    func moveWorkspaceToNewWindow(_ id: UUID, position: NSPoint? = nil) -> Bool {
        guard workspaceModel.workspaces.count > 1,
              let workspace = workspaceModel.workspaces.first(where: { $0.id == id }) else { return false }

        release(workspace: id)
        openWindow(with: workspace, position: position)
        return true
    }

    /// Opens a new window with a workspace released from this one, showing
    /// its current tab, with its top left corner at `position` if given.
    private func openWindow(with workspace: Workspace, position: NSPoint?) {
        guard let tab = workspace.selectedTab else { return }
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        let newController = TerminalController.newWindow(
            ghostty,
            tree: tab.surfaceTree,
            position: position,
            inheritBackgroundOpacity: isBackgroundOpaque)
        newController.adoptWorkspaces([workspace], selectedWorkspaceID: workspace.id)
    }

    /// Moves a workspace, with its tabs, here from another window, to
    /// `index`, and shows it. Its tabs stay the same, with their terminals,
    /// focus and titles. If it was the other window's last workspace, that
    /// window closes. Like moving a tab between windows, this can't be
    /// undone.
    func receive(workspace id: UUID, from source: TerminalController, at index: Int) {
        guard source !== self,
              let workspace = source.workspaceModel.workspaces.first(where: { $0.id == id }) else { return }

        source.release(workspace: id)
        workspaceModel.insert(workspace, at: index)
        selectWorkspace(id)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Takes a workspace out of the window to move it to another. If it's
    /// the shown workspace, the next workspace (else the previous one) is
    /// shown. The window's last workspace closes the window, without closing
    /// its terminals or registering an undo. The window's undo history is
    /// cleared, as when releasing a tab.
    private func release(workspace id: UUID) {
        guard let index = workspaceModel.workspaceIndex(of: id) else { return }
        undoManager?.removeAllActions(withTarget: self)
        guard let neighbor = workspaceModel.neighborOfWorkspace(at: index) else {
            workspaceModel.removeWorkspace(id)
            // An empty tree closes the window.
            surfaceTree = .init()
            return
        }

        if workspaceModel.selectedWorkspaceID == id { selectWorkspace(neighbor.id) }
        workspaceModel.removeWorkspace(id)
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
        addTab(withBaseConfig: config, inWorkspace: addWorkspace(after: workspaceModel.selectedWorkspaceID))
    }

    /// Selects workspace `sender.tag` (from 1), or the last one for 9, like
    /// the tabs' Cmd+1-9.
    @IBAction func selectWorkspaceByNumber(_ sender: NSMenuItem) {
        if sender.tag == 9 {
            selectLastWorkspace()
        } else {
            selectWorkspace(number: sender.tag)
        }
    }

    @IBAction func selectNextWorkspace(_ sender: Any?) {
        selectAdjacentWorkspace(offset: 1)
    }

    @IBAction func selectPreviousWorkspace(_ sender: Any?) {
        selectAdjacentWorkspace(offset: -1)
    }

    @IBAction func moveWorkspaceUp(_ sender: Any?) {
        moveSelectedWorkspace(by: -1)
    }

    @IBAction func moveWorkspaceDown(_ sender: Any?) {
        moveSelectedWorkspace(by: 1)
    }

    @IBAction func moveTabToPreviousWorkspace(_ sender: Any?) {
        moveSelectedTab(toWorkspaceBy: -1)
    }

    @IBAction func moveTabToNextWorkspace(_ sender: Any?) {
        moveSelectedTab(toWorkspaceBy: 1)
    }

    /// Moves every other window's workspaces into this window, after its
    /// own, closing those windows. The shown workspace stays shown. Like
    /// other moves between windows, this can't be undone.
    @IBAction func mergeAllWindows(_ sender: Any?) {
        guard supportsTabs, let shown = workspaceModel.selectedWorkspaceID else { return }
        for other in TerminalController.all where other !== self && other.supportsTabs {
            for workspace in other.workspaceModel.workspaces {
                receive(workspace: workspace.id, from: other, at: workspaceModel.workspaces.count)
            }
        }
        selectWorkspace(shown)
    }
}
