import AppKit
import Combine

/// Coordinates the workspaces of one logical terminal window.
///
/// The logical window is a single native tab group that holds the tabs of
/// every workspace. The native tab bar is hidden and the tab strip only
/// shows the selected workspace's tabs, so switching workspaces is just
/// selecting a tab in another workspace. Tabs never leave the group, which
/// keeps switching as cheap as switching tabs.
///
/// Tabs are not stored here. A tab's membership lives on its
/// `TerminalController` and the tabs of a workspace are derived from the
/// live controllers on demand.
@MainActor
final class WorkspaceWindowGroup: ObservableObject {
    struct Workspace: Identifiable, Equatable {
        let id: UUID
        var name: String
    }

    /// A tab of the selected workspace, as shown in the tab strip. The
    /// title is observed from the window directly.
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        weak var window: NSWindow?
        let shortcut: String?
        let isSelected: Bool

        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.id == rhs.id && lhs.shortcut == rhs.shortcut && lhs.isSelected == rhs.isSelected
        }
    }

    /// The fixed width of the workspace sidebar in every tab window.
    static let sidebarWidth: CGFloat = 200

    /// The fixed height of the tab strip above the terminal.
    static let tabStripHeight: CGFloat = 32

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var selectedID: UUID?

    /// The selected workspace's tabs in native tab group order.
    @Published private(set) var tabs: [Tab] = []

    /// A tab being dragged in the tab strip to reorder it, and how far it's
    /// been dragged. Shared by every tab window's strip, since pressing a tab
    /// selects it and shows another tab window mid-drag.
    struct TabDrag: Equatable {
        enum Phase {
            /// Following the pointer within the strip.
            case following

            /// Released and animating into its slot, before the native tab
            /// moves.
            case settling

            /// Dragged out of the strip as a system drag, to be dropped on a
            /// workspace in the sidebar.
            case draggingOut
        }

        let id: ObjectIdentifier
        var offset: CGFloat = 0
        var phase = Phase.following
    }

    @Published var tabDrag: TabDrag?

    /// A workspace being dragged in the sidebar to reorder it, and how far
    /// it's been dragged. Shared by every tab window's sidebar, since
    /// pressing a workspace selects it and shows another tab window mid-drag.
    struct WorkspaceDrag: Equatable {
        let id: UUID
        var offset: CGFloat = 0
    }

    @Published var workspaceDrag: WorkspaceDrag?

    /// Whether the workspace sidebar is collapsed. Shared by every tab window
    /// of the group so switching tabs doesn't bring it back.
    @Published private(set) var isSidebarCollapsed = false

    /// The last selected tab of each workspace, reselected when switching
    /// back to it.
    private var lastSelectedTab: [UUID: Weak<NSWindow>] = [:]

    /// Used for default names. Never reused within a group.
    private var nextNumber = 1

    /// Set while `reinsert` re-inserts a tab. AppKit briefly selects a
    /// neighboring tab, which may be in another workspace, and that must not
    /// count as a selection.
    private var isMovingTab = false

    /// Appends a new workspace and returns its ID. This does not select it.
    func addWorkspace() -> UUID {
        let workspace = Workspace(id: UUID(), name: "Workspace \(nextNumber)")
        nextNumber += 1
        workspaces.append(workspace)
        if selectedID == nil { selectedID = workspace.id }
        return workspace.id
    }

    /// Re-adds a workspace that was removed when its last tab closed, e.g.
    /// when undoing that close. Does nothing if it still exists.
    ///
    /// With `order`, the workspace order it was removed from, it goes back
    /// right after the nearest workspace that preceded it and still exists
    /// (or first). Without it, it's appended.
    func restoreWorkspace(id: UUID, name: String, order: [UUID]? = nil) {
        guard !workspaces.contains(where: { $0.id == id }) else { return }

        var index = workspaces.endIndex
        if let order {
            let preceding = order.prefix { $0 != id }.reversed()
            index = preceding.lazy
                .compactMap { previous in self.workspaces.firstIndex { $0.id == previous } }
                .first.map { $0 + 1 } ?? 0
        }

        workspaces.insert(Workspace(id: id, name: name), at: index)
    }

    /// The live tab controllers assigned to this group.
    var controllers: [TerminalController] {
        TerminalController.all.filter { $0.workspaceGroup === self }
    }

    /// The live tab controllers assigned to the given workspace.
    func controllers(in id: UUID) -> [TerminalController] {
        controllers.filter { $0.workspaceID == id }
    }

    /// The tab windows of the given workspace in native tab order.
    func windows(in id: UUID) -> [NSWindow] {
        let windows = controllers(in: id).compactMap(\.window)
        let order = windows.first?.tabGroup?.windows ?? []
        return order.filter { windows.contains($0) } + windows.filter { !order.contains($0) }
    }

    /// Selects the given workspace by selecting its last selected tab.
    func select(_ id: UUID) {
        guard id != selectedID,
              workspaces.contains(where: { $0.id == id }) else { return }

        let windows = windows(in: id)
        let last = lastSelectedTab[id]?.value.flatMap { windows.contains($0) ? $0 : nil }
        guard let target = last ?? windows.first else { return }

        selectedID = id
        selectTab(target)
        refreshTabs()
    }

    /// Moves a workspace to `index` in the workspace order. This changes
    /// display and workspace navigation order only; tabs stay where they are
    /// in the tab group.
    func moveWorkspace(_ id: UUID, to index: Int) {
        guard let from = workspaces.firstIndex(where: { $0.id == id }),
              workspaces.indices.contains(index) else { return }
        workspaces.insert(workspaces.remove(at: from), at: index)
    }

    func toggleSidebar() {
        isSidebarCollapsed.toggle()
    }

    func showSidebar() {
        isSidebarCollapsed = false
    }

    /// Selects the workspace `offset` positions away, wrapping around.
    func selectAdjacent(offset: Int) {
        guard workspaces.count > 1,
              let selectedID,
              let index = workspaces.firstIndex(where: { $0.id == selectedID }) else { return }
        let count = workspaces.count
        select(workspaces[((index + offset) % count + count) % count].id)
    }

    /// Must be called when one of this group's tabs becomes key. The key
    /// tab decides the selected workspace.
    func tabDidBecomeKey(_ controller: TerminalController) {
        guard !isMovingTab,
              let window = controller.window,
              let id = controller.workspaceID else { return }

        lastSelectedTab[id] = Weak(window)
        if selectedID != id { selectedID = id }
        refreshTabs()
    }

    /// Must be called just before one of this group's tabs closes, while
    /// it's still in the tab group. If it's the visible tab, select the
    /// next tab ourselves: the tab to its right in the same workspace, or,
    /// if it's the workspace's last tab, the neighboring workspace.
    /// Otherwise AppKit picks a neighbor that may be in another workspace.
    func tabWillClose(_ controller: TerminalController) {
        guard let window = controller.window,
              let id = controller.workspaceID,
              window.tabGroup?.selectedWindow == window else { return }

        if let neighbor = neighbor(of: window, in: id) {
            selectTab(neighbor)
            return
        }

        guard workspaces.count > 1,
              let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        select(workspaces[index + 1 < workspaces.count ? index + 1 : index - 1].id)
    }

    /// Must be called when a tab of this group closes. Removes its workspace
    /// if this was the workspace's last tab.
    func controllerWillClose(_ controller: TerminalController) {
        // Closed windows can linger in NSApp.windows (e.g. held for undo),
        // so the closing tab must stop counting as a workspace member.
        defer {
            controller.workspaceMembership.leave()
            DispatchQueue.main.async { [weak self] in self?.refreshTabs() }
        }

        guard let window = controller.window,
              let id = controller.workspaceID,
              windows(in: id).allSatisfy({ $0 == window }),
              let index = workspaces.firstIndex(where: { $0.id == id }) else { return }

        workspaces.remove(at: index)
        lastSelectedTab[id] = nil

        // Normally `tabWillClose` already selected another workspace.
        if selectedID == id {
            selectedID = workspaces.isEmpty ? nil : workspaces[min(index, workspaces.count - 1)].id
        }
    }

    /// Rebuilds `tabs` from the selected workspace's native tab group.
    /// Called whenever tab order, selection, or shortcut labels may change.
    func refreshTabs() {
        guard let selectedID else {
            tabs = []
            return
        }

        let windows = windows(in: selectedID)
        let selected = windows.first?.tabGroup?.selectedWindow
        tabs = windows.map {
            Tab(
                id: ObjectIdentifier($0),
                window: $0,
                shortcut: ($0 as? TerminalWindow)?.keyEquivalent,
                isSelected: $0 == selected)
        }
    }

    /// Moves a tab of the selected workspace to `index` in that workspace's
    /// tab order. The selected tab stays selected.
    func moveTab(_ window: NSWindow, to index: Int) {
        guard let selectedID,
              let selected = window.tabGroup?.selectedWindow else { return }
        let windows = windows(in: selectedID)
        guard let from = windows.firstIndex(of: window),
              windows.indices.contains(index),
              index != from else { return }

        reinsert(window, next: windows[index], ordered: index < from ? .below : .above, selecting: selected)

        // Renumbers the tabs and refreshes `tabs`.
        (window.windowController as? TerminalController)?.relabelTabs()
    }

    /// Moves a tab to the end of another workspace and follows it there,
    /// selecting the tab and its new workspace. The workspace it left shows
    /// its neighbor when switched back to, or is removed if it was its only
    /// tab.
    func moveTab(_ window: NSWindow, toWorkspace target: UUID) {
        guard let controller = window.windowController as? TerminalController,
              controller.workspaceGroup === self,
              let source = controller.workspaceID,
              source != target,
              let anchor = windows(in: target).last else { return }

        let neighbor = neighbor(of: window, in: source)
        guard reinsert(window, next: anchor, ordered: .above, selecting: window) else { return }

        controller.workspaceMembership.assign(to: self, workspace: target)
        lastSelectedTab[target] = Weak(window)
        if let neighbor {
            lastSelectedTab[source] = Weak(neighbor)
        } else {
            workspaces.removeAll { $0.id == source }
            lastSelectedTab[source] = nil
        }
        selectedID = target

        // Renumbers both workspaces' tabs and refreshes `tabs`.
        controller.relabelTabs()
    }

    /// The tab to show in place of the given one in its workspace: the tab
    /// to its right, or its left if it's the last. Nil if it's the only one.
    private func neighbor(of window: NSWindow, in workspace: UUID) -> NSWindow? {
        let windows = windows(in: workspace)
        guard windows.count > 1, let position = windows.firstIndex(of: window) else { return nil }
        return position + 1 < windows.count ? windows[position + 1] : windows[position - 1]
    }

    /// Re-inserts a tab in the tab group next to `anchor`, then selects
    /// `selected`. Returns whether it moved: if AppKit refuses, the tab goes
    /// back where it was, since left out of the tab group it would split off
    /// into a window of its own.
    ///
    /// AppKit briefly selects a neighboring tab, which may be in another
    /// workspace, so key changes are ignored meanwhile.
    @discardableResult
    private func reinsert(
        _ window: NSWindow,
        next anchor: NSWindow,
        ordered: NSWindow.OrderingMode,
        selecting selected: NSWindow
    ) -> Bool {
        guard let tabGroup = window.tabGroup else { return false }
        let all = tabGroup.windows
        guard let position = all.firstIndex(of: window), all.count > 1 else { return false }
        let restore: (NSWindow, NSWindow.OrderingMode) = position + 1 < all.count
            ? (all[position + 1], .below)
            : (all[position - 1], .above)

        isMovingTab = true
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(window)
        let moved = anchor.addTabbedWindowSafely(window, ordered: ordered)
        if !moved {
            restore.0.addTabbedWindowSafely(window, ordered: restore.1)
        }
        selectTab(selected)
        NSAnimationContext.endGrouping()
        isMovingTab = false
        return moved
    }

    /// Selects the given tab the same way clicking a native tab does.
    func selectTab(_ window: NSWindow) {
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: Reconciling with native tab groups

extension WorkspaceWindowGroup {
    /// Makes the given tabs of one native tab group belong to one workspace
    /// group. A native tab group and a workspace group correspond one to
    /// one, but AppKit can change tab groups under us (Merge All Windows,
    /// Move Tab to New Window, undo re-inserting tabs):
    ///
    /// - Tabs whose workspace group mostly lives in another tab group split
    ///   off into a new group, keeping their workspaces under new IDs.
    /// - Workspace groups that meet in one tab group merge into the group of
    ///   the selected tab, keeping their workspaces.
    /// - Tabs without a workspace join the selected workspace.
    static func reconcile(_ tabs: [TerminalController], selected: TerminalController?) {
        guard let tabGroup = tabs.first?.window?.tabGroup else { return }

        for group in uniqueGroups(of: tabs) {
            let here = tabs.filter { $0.workspaceGroup === group }
            let elsewhere = group.controllers.filter { $0.window?.tabGroup !== tabGroup }
            guard !elsewhere.isEmpty, here.count <= elsewhere.count else { continue }
            WorkspaceWindowGroup().adopt(here, from: group, keepingIDs: false)
        }

        let primary = selected?.workspaceGroup
            ?? tabs.lazy.compactMap(\.workspaceGroup).first
            ?? WorkspaceWindowGroup()
        for group in uniqueGroups(of: tabs) where group !== primary {
            primary.adopt(tabs.filter { $0.workspaceGroup === group }, from: group, keepingIDs: true)
        }

        for tab in tabs where tab.workspaceGroup == nil {
            let id = primary.selectedID ?? primary.addWorkspace()
            tab.workspaceMembership.assign(to: primary, workspace: id)
            if tab === selected { primary.tabDidBecomeKey(tab) }
        }

        primary.refreshTabs()
    }

    private static func uniqueGroups(of tabs: [TerminalController]) -> [WorkspaceWindowGroup] {
        var groups: [WorkspaceWindowGroup] = []
        for case let group? in tabs.map(\.workspaceGroup) where !groups.contains(where: { $0 === group }) {
            groups.append(group)
        }
        return groups
    }

    /// Moves the given tabs, and the workspaces they belong to, from
    /// `source` into this group. Tabs whose workspace is unknown to `source`
    /// are left unassigned.
    private func adopt(_ tabs: [TerminalController], from source: WorkspaceWindowGroup, keepingIDs: Bool) {
        var newIDs: [UUID: UUID] = [:]
        for tab in tabs {
            guard let oldID = tab.workspaceID,
                  let workspace = source.workspaces.first(where: { $0.id == oldID }) else {
                tab.workspaceMembership.leave()
                continue
            }

            let id = newIDs[oldID] ?? (keepingIDs ? oldID : UUID())
            newIDs[oldID] = id
            restoreWorkspace(id: id, name: workspace.name)
            tab.workspaceMembership.assign(to: self, workspace: id)
        }

        if selectedID == nil { selectedID = workspaces.first?.id }
        source.removeEmptyWorkspaces()
    }

    /// Drops workspaces that no longer have tabs, e.g. after their tabs were
    /// adopted by another group.
    private func removeEmptyWorkspaces() {
        workspaces.removeAll { controllers(in: $0.id).isEmpty }
        if let selectedID, !workspaces.contains(where: { $0.id == selectedID }) {
            self.selectedID = workspaces.first?.id
        }
        refreshTabs()
    }
}

/// A tab's membership in a workspace. Owned by each `TerminalController`
/// and observed by its sidebar and tab strip so that they appear once the
/// tab is assigned to a group.
@MainActor
final class WorkspaceMembership: ObservableObject {
    @Published private(set) var group: WorkspaceWindowGroup?
    private(set) var workspaceID: UUID?

    /// Whether the tab's title is being edited in its tab strip, which
    /// shows while it is, even for a single tab. Only the tab's own window
    /// edits it; every tab window has its own copy of the strip.
    @Published var isRenamingTab = false

    func assign(to group: WorkspaceWindowGroup, workspace: UUID) {
        workspaceID = workspace
        self.group = group
    }

    func leave() {
        workspaceID = nil
        group = nil
    }
}
