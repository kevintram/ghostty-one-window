import AppKit

extension TerminalController {
    var workspaceGroup: WorkspaceWindowGroup? { workspaceMembership.group }
    var workspaceID: UUID? { workspaceMembership.workspaceID }

    /// Whether this tab can use workspaces. Workspaces are tabs of one
    /// native tab group, so windows that never tab (hidden titlebar) can't.
    /// Decided by window class rather than `tabbingMode`, which is briefly
    /// `.automatic` for those windows after they load.
    var supportsWorkspaces: Bool {
        window is TerminalWindow && !(window is HiddenTitlebarTerminalWindow)
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
        guard supportsWorkspaces, let window, let group = workspaceGroup else {
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

    @IBAction func selectNextWorkspace(_ sender: Any?) {
        workspaceGroup?.selectAdjacent(offset: 1)
    }

    @IBAction func selectPreviousWorkspace(_ sender: Any?) {
        workspaceGroup?.selectAdjacent(offset: -1)
    }
}
