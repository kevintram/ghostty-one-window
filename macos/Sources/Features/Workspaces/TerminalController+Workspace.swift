import AppKit

extension TerminalController {
    var workspaceGroup: WorkspaceWindowGroup? { workspaceMembership.group }
    var workspaceID: UUID? { workspaceMembership.workspaceID }

    /// Whether this tab uses workspaces, i.e. its window got the workspace
    /// layout when it loaded (see `canHostWorkspaces`). Fixed for the
    /// window's lifetime, unlike its style, which e.g. non-native fullscreen
    /// changes.
    var supportsWorkspaces: Bool {
        window?.contentViewController is WorkspaceSplitViewController
    }

    /// Whether this tab may join `other`'s native tab group. Workspace tabs
    /// only share a group with workspace tabs, since tabs without the
    /// workspace layout would be stranded in it (e.g. an undone tab whose
    /// window follows a config changed since it closed).
    func canShareTabGroup(with other: NSWindow) -> Bool {
        supportsWorkspaces == ((other.windowController as? TerminalController)?.supportsWorkspaces ?? false)
    }

    /// Whether a just-loaded window can host workspaces. Workspaces are tabs
    /// of one native tab group with their controls in the titlebar, so
    /// windows that never tab (hidden titlebar) or have no titlebar
    /// (`window-decoration = false`) can't. Decided by window class rather
    /// than `tabbingMode`, which is briefly `.automatic` for hidden titlebar
    /// windows after they load.
    var canHostWorkspaces: Bool {
        guard let window = window as? TerminalWindow,
              !(window is HiddenTitlebarTerminalWindow) else { return false }
        return window.styleMask.contains(.titled)
    }

    /// The tabs of this tab's workspace in native tab order. The native tab
    /// group holds the tabs of every workspace, so tab navigation and
    /// "close other tabs" style operations must use this instead of the
    /// tab group's windows. Without a workspace this is the whole group.
    var workspaceTabs: [NSWindow] {
        guard let window else { return [] }
        guard let workspaceGroup, let workspaceID else {
            return window.tabGroup?.windows ?? [window]
        }

        return workspaceGroup.windows(in: workspaceID)
    }

    /// Reconciles workspace membership with this tab's native tab group on
    /// the next event loop tick. Deferred because callers such as undo show
    /// a window before inserting it into its tab group.
    func scheduleWorkspaceReconcile() {
        DispatchQueue.main.async { [weak self] in
            self?.reconcileWorkspaces()
        }
    }

    /// Makes every tab in this tab's native tab group belong to one
    /// workspace group. See `WorkspaceWindowGroup.reconcile`.
    func reconcileWorkspaces() {
        // Skip windows that closed since this was scheduled; reconciling
        // would give a closed tab its membership back.
        guard let window, window.isVisible || window.tabGroup?.windows.count ?? 0 > 1 else { return }

        let tabGroup = window.tabGroup
        let allTabs = (tabGroup?.windows ?? [window])
            .compactMap { $0.windowController as? TerminalController }
        let tabs = allTabs.filter(\.supportsWorkspaces)
        guard !tabs.isEmpty else { return }

        // A window that can't hold workspaces (hidden titlebar) has no
        // sidebar or tab strip, so it must not share a tab group with
        // workspace tabs. AppKit can still put it there, e.g. with Merge All
        // Windows; give it back its own window.
        for tab in allTabs where !tab.supportsWorkspaces {
            if let tabWindow = tab.window { tabGroup?.removeWindow(tabWindow) }
        }

        let selected = tabGroup?.selectedWindow?.windowController as? TerminalController
        WorkspaceWindowGroup.reconcile(
            tabs,
            selected: selected?.supportsWorkspaces == true ? selected : tabs.first)
    }

    // MARK: Undo

    /// Where a closed tab belonged, so undoing the close puts it back. Holds
    /// the group strongly so it survives until the undo expires even if all
    /// of its tabs closed.
    struct WorkspaceUndoState {
        let group: WorkspaceWindowGroup
        let id: UUID
        let name: String

        /// The group's workspace order when the tab closed, used to put a
        /// recreated workspace back in its place.
        let order: [UUID]
    }

    var workspaceUndoState: WorkspaceUndoState? {
        guard let workspaceGroup, let workspaceID,
              let workspace = workspaceGroup.workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        return .init(
            group: workspaceGroup,
            id: workspaceID,
            name: workspace.name,
            order: workspaceGroup.workspaces.map(\.id))
    }

    /// Ends renaming the tab in its tab strip, setting its title to
    /// `title`, or leaving it if nil (cancelled). An empty title restores
    /// the terminal's own. Keyboard focus goes back to the terminal, also
    /// when the rename ended because the window stopped being key, so it's
    /// there when it's key again.
    func endRenamingTab(title: String?) {
        workspaceMembership.isRenamingTab = false
        if let title { titleOverride = title.isEmpty ? nil : title }
        if let focusedSurface { window?.makeFirstResponder(focusedSurface) }
    }

    /// Returns a restored tab to the workspace it was closed from,
    /// recreating the workspace if that was its last tab. Does nothing if
    /// the restored window can't be a tab under the current config.
    func restoreWorkspace(_ state: WorkspaceUndoState?) {
        guard supportsWorkspaces, let state else { return }
        state.group.restoreWorkspace(id: state.id, name: state.name, order: state.order)
        workspaceMembership.assign(to: state.group, workspace: state.id)
    }

    // MARK: First Responder

    @IBAction func newWorkspace(_ sender: Any?) {
        // ⌘N used to be New Window. In a window that can't have workspaces
        // (hidden titlebar), it still is. Our `newWindow` needs a focused
        // surface to inherit from; without one, open a plain window.
        guard supportsWorkspaces, let window else {
            if focusedSurface?.surface != nil {
                newWindow(sender)
            } else {
                (NSApp.delegate as? AppDelegate)?.newWindow(sender)
            }
            return
        }

        // A window joins its workspace group a tick after it's shown, so a
        // quick second ⌘N can arrive before that. Join it now.
        if workspaceGroup == nil { reconcileWorkspaces() }
        guard let group = workspaceGroup else {
            NSSound.beep()
            return
        }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = focusedSurface?.pwd

        let controller = TerminalController(ghostty, withBaseConfig: config)
        guard let newWindow = controller.window else { return }

        // The new window's style follows the current config, which may have
        // changed to one without tabs (hidden titlebar) since this window
        // opened. Like Ghostty's new tab, open it as its own window then.
        guard controller.supportsWorkspaces else {
            controller.showWindowSafely(self)
            return
        }

        // The new workspace's first tab joins our tab group at the end.
        let last = window.tabGroup?.windows.last ?? window
        guard last.addTabbedWindowSafely(newWindow, ordered: .above) else {
            // The tab was never shown and its terminal is already running.
            // Emptying the tree is how Ghostty closes a terminal window.
            controller.surfaceTree = .init()
            NSSound.beep()
            return
        }

        let id = group.addWorkspace()
        controller.workspaceMembership.assign(to: group, workspace: id)
        group.select(id)
    }

    /// Selects workspace `sender.tag` (1-based), or the last one for 9.
    @IBAction func selectWorkspaceByNumber(_ sender: NSMenuItem) {
        guard let workspaceGroup,
              let workspace = workspaceNumbered(sender.tag, in: workspaceGroup) else { return }
        workspaceGroup.select(workspace.id)
    }

    /// Whether the workspace for a numbered menu item exists. When it
    /// doesn't, the item is disabled so its key goes to the terminal.
    func canSelectWorkspace(numbered number: Int) -> Bool {
        guard let workspaceGroup else { return false }
        return workspaceNumbered(number, in: workspaceGroup) != nil
    }

    private func workspaceNumbered(_ number: Int, in group: WorkspaceWindowGroup) -> WorkspaceWindowGroup.Workspace? {
        if number == 9 { return group.workspaces.last }
        return group.workspaces.indices.contains(number - 1) ? group.workspaces[number - 1] : nil
    }

    @IBAction func selectNextWorkspace(_ sender: Any?) {
        workspaceGroup?.selectAdjacent(offset: 1)
    }

    @IBAction func selectPreviousWorkspace(_ sender: Any?) {
        workspaceGroup?.selectAdjacent(offset: -1)
    }
}
