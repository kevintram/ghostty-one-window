import AppKit
import Combine

/// A tab of a terminal window: a tree of split terminals.
///
/// A window holds the tabs of all of its workspaces, but only the selected
/// tab's terminals are in it. The window's controller shows the selected tab
/// through its `surfaceTree` and keeps the tab's `surfaceTree` in sync with
/// it. The other tabs' terminals keep running, occluded.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()

    var surfaceTree: SplitTree<Ghostty.SurfaceView>

    /// The tab's focused terminal, focused again when the tab is selected.
    weak var focusedSurface: Ghostty.SurfaceView? {
        didSet {
            guard focusedSurface !== oldValue else { return }
            observeTitle()
        }
    }

    /// A title set by renaming the tab, shown instead of the terminal's.
    var titleOverride: String? {
        didSet { updateTitle() }
    }

    /// The title override, else the focused terminal's title.
    @Published private(set) var title = ""

    /// Whether closing the tab needs confirmation: a terminal in it has a
    /// running process.
    var needsConfirmQuit: Bool {
        surfaceTree.contains { $0.needsConfirmQuit }
    }

    private var surfaceTitle = ""
    private var titleCancellable: AnyCancellable?

    init(
        surfaceTree: SplitTree<Ghostty.SurfaceView>,
        focusedSurface: Ghostty.SurfaceView? = nil,
        titleOverride: String? = nil
    ) {
        self.surfaceTree = surfaceTree
        self.focusedSurface = focusedSurface ?? surfaceTree.root?.leftmostLeaf()
        self.titleOverride = titleOverride
        observeTitle()
    }

    private func observeTitle() {
        guard let focusedSurface else {
            titleCancellable = nil
            surfaceTitle = ""
            updateTitle()
            return
        }

        titleCancellable = focusedSurface.$title.sink { [weak self] title in
            MainActor.assumeIsolated {
                self?.surfaceTitle = title
                self?.updateTitle()
            }
        }
    }

    private func updateTitle() {
        let newTitle = titleOverride ?? (surfaceTitle.isEmpty ? "👻" : surfaceTitle)
        if title != newTitle { title = newTitle }
    }
}

/// An ordered group of tabs in a window.
struct Workspace: Identifiable {
    let id: UUID

    /// The name set by renaming the workspace. Without one, the workspace is
    /// named after its current tab's title.
    var customName: String?

    var tabs: [TerminalTab]

    /// The tab shown when the workspace is selected.
    var selectedTabID: UUID?

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// The custom name, else the current tab's title.
    @MainActor var name: String {
        customName ?? selectedTab?.title ?? ""
    }
}

/// The workspaces and tabs of one terminal window, and the state its sidebar
/// and tab strip share.
///
/// This is only the model. `TerminalController` changes the selection, since
/// selecting a tab also swaps the terminals shown in the window.
@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var selectedWorkspaceID: UUID?

    /// Whether the workspace sidebar is hidden. New windows start with it
    /// hidden; a restored or reopened window keeps its own.
    @Published var isSidebarCollapsed = true

    /// What's being renamed in place, one thing at a time: a tab in the tab
    /// strip (which shows while it is, even for a single tab), or a
    /// workspace in the sidebar.
    enum Renaming: Equatable {
        case tab(UUID)
        case workspace(UUID)
    }

    @Published var renaming: Renaming?

    /// An item being dragged to reorder it, a tab in the tab strip or a
    /// workspace in the sidebar, and how far it's been dragged.
    struct ReorderDrag: Equatable {
        enum Phase {
            /// Following the pointer within the strip or sidebar.
            case following

            /// Dropped and animating into its slot, before it moves there.
            case settling

            /// Dragged out of the strip or sidebar as a system drag (see
            /// `WorkspaceDragOut`).
            case draggingOut
        }

        let id: UUID
        var offset: CGFloat = 0
        var phase = Phase.following
    }

    @Published var tabDrag: ReorderDrag?

    /// A tab of another window dragged over the tab strip, which shows it
    /// after its own tabs, following the pointer (as `tabDrag`), until it's
    /// dropped there or leaves.
    @Published var incomingTab: TerminalTab?

    @Published var workspaceDrag: ReorderDrag?

    /// A workspace of another window dragged over the sidebar, which shows
    /// it after its own workspaces, following the pointer (as
    /// `workspaceDrag`), until it's dropped there or leaves.
    @Published var incomingWorkspace: Workspace?

    /// The fixed width of the workspace sidebar.
    static let sidebarWidth: CGFloat = 200

    /// The fixed height of the tab strip above the terminal.
    static let tabStripHeight: CGFloat = 32

    // MARK: Queries

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// The tab shown in the window.
    var selectedTab: TerminalTab? {
        selectedWorkspace?.selectedTab
    }

    /// The selected workspace's tabs, as shown in the tab strip.
    var tabs: [TerminalTab] {
        selectedWorkspace?.tabs ?? []
    }

    /// Every tab of every workspace, in workspace order.
    var allTabs: [TerminalTab] {
        workspaces.flatMap(\.tabs)
    }

    func workspaceIndex(of id: UUID) -> Int? {
        workspaces.firstIndex { $0.id == id }
    }

    /// Where the tab is: its workspace's index and its index in that
    /// workspace.
    func location(of tab: TerminalTab) -> (workspace: Int, tab: Int)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let tabIndex = workspace.tabs.firstIndex(where: { $0 === tab }) {
                return (workspaceIndex, tabIndex)
            }
        }
        return nil
    }

    /// The workspace that takes the place of the one at `index` when it goes:
    /// the next one, else the previous one.
    func neighborOfWorkspace(at index: Int) -> Workspace? {
        let neighbor = index + 1 < workspaces.count ? index + 1 : index - 1
        return workspaces.indices.contains(neighbor) ? workspaces[neighbor] : nil
    }

    func workspace(of tab: TerminalTab) -> Workspace? {
        location(of: tab).map { workspaces[$0.workspace] }
    }

    /// The other tabs of the tab's workspace.
    func otherTabs(than tab: TerminalTab) -> [TerminalTab] {
        workspace(of: tab)?.tabs.filter { $0 !== tab } ?? []
    }

    /// The tabs to the right of the tab in its workspace.
    func tabs(rightOf tab: TerminalTab) -> [TerminalTab] {
        guard let location = location(of: tab) else { return [] }
        return Array(workspaces[location.workspace].tabs[(location.tab + 1)...])
    }

    /// Whether the tab strip takes room above the terminal: with 2+ tabs in
    /// the selected workspace, or while one is renamed in it. Otherwise it's
    /// hidden, except while a tab is dragged, when it shows over the
    /// terminal to take the drop.
    var reservesTabStrip: Bool {
        Self.reservesTabStrip(tabCount: tabs.count, renaming: renaming)
    }

    static func reservesTabStrip(tabCount: Int, renaming: Renaming?) -> Bool {
        guard case .tab = renaming else { return tabCount > 1 }
        return true
    }

    func contains(_ tab: TerminalTab) -> Bool {
        location(of: tab) != nil
    }

    /// The tab whose split tree holds the surface.
    func tab(owning surface: Ghostty.SurfaceView) -> TerminalTab? {
        allTabs.first { $0.surfaceTree.contains(surface) }
    }

    // MARK: Changes

    /// Appends a new workspace, or inserts it at `index`, and returns its
    /// ID. It has no tabs until one is inserted.
    @discardableResult
    func addWorkspace(id: UUID = UUID(), customName: String? = nil, at index: Int? = nil) -> UUID {
        let workspace = Workspace(id: id, customName: customName, tabs: [])
        workspaces.insert(workspace, at: min(index ?? workspaces.endIndex, workspaces.endIndex))
        return id
    }

    /// Inserts a workspace, with its tabs, at `index`.
    func insert(_ workspace: Workspace, at index: Int) {
        workspaces.insert(workspace, at: min(max(index, 0), workspaces.endIndex))
    }

    /// Removes a workspace with its tabs. It mustn't be the selected one;
    /// select another first.
    func removeWorkspace(_ id: UUID) {
        guard let index = workspaceIndex(of: id) else { return }
        let workspace = workspaces.remove(at: index)
        switch renaming {
        case .workspace(id): renaming = nil
        case .tab(let tab) where workspace.tabs.contains(where: { $0.id == tab }): renaming = nil
        default: break
        }
        if workspaceDrag?.id == id { workspaceDrag = nil }
    }

    /// Inserts a tab in a workspace, at the end unless `index` is given.
    func insert(_ tab: TerminalTab, inWorkspace id: UUID, at index: Int? = nil) {
        guard let workspaceIndex = workspaceIndex(of: id) else { return }
        let tabs = workspaces[workspaceIndex].tabs
        workspaces[workspaceIndex].tabs.insert(tab, at: min(index ?? tabs.endIndex, tabs.endIndex))
    }

    /// Removes a tab, and its workspace if it was the workspace's last tab.
    /// The tab mustn't be the selected one; select another first.
    func remove(_ tab: TerminalTab) {
        guard let location = location(of: tab) else { return }
        workspaces[location.workspace].tabs.remove(at: location.tab)
        if workspaces[location.workspace].tabs.isEmpty {
            workspaces.remove(at: location.workspace)
        }
        if renaming == .tab(tab.id) { renaming = nil }
        if tabDrag?.id == tab.id { tabDrag = nil }
    }

    /// Makes the tab the selected one, and its workspace the selected
    /// workspace.
    func select(_ tab: TerminalTab) {
        guard let location = location(of: tab) else { return }
        workspaces[location.workspace].selectedTabID = tab.id
        selectedWorkspaceID = workspaces[location.workspace].id
    }

    /// Makes the tab its workspace's current tab, the one shown when the
    /// workspace is selected, without selecting the workspace.
    func makeCurrent(_ tab: TerminalTab) {
        guard let location = location(of: tab) else { return }
        workspaces[location.workspace].selectedTabID = tab.id
    }

    /// Replaces the split tree of a tab that isn't shown. The shown tab's
    /// tree follows its controller's instead.
    func setSurfaceTree(_ tree: SplitTree<Ghostty.SurfaceView>, of tab: TerminalTab) {
        tab.surfaceTree = tree

        // Tabs aren't published themselves, so republish the workspaces for
        // anything following every tab's surfaces (e.g. bells).
        let workspaces = workspaces
        self.workspaces = workspaces
    }

    /// Moves a tab within its workspace.
    func moveTab(_ tab: TerminalTab, to index: Int) {
        guard let location = location(of: tab),
              workspaces[location.workspace].tabs.indices.contains(index) else { return }
        workspaces[location.workspace].tabs.remove(at: location.tab)
        workspaces[location.workspace].tabs.insert(tab, at: index)
    }

    /// Moves a tab to the end of another workspace, where it becomes the
    /// selected tab. The workspace it left selects its neighbor instead, or
    /// is removed if it was its only tab. If it was the selected tab, its new
    /// workspace becomes the selected workspace.
    func transfer(_ tab: TerminalTab, toWorkspace id: UUID) {
        guard let location = location(of: tab), workspaces[location.workspace].id != id,
              workspaceIndex(of: id) != nil else { return }

        var source = workspaces[location.workspace]
        source.tabs.remove(at: location.tab)
        if source.selectedTabID == tab.id, !source.tabs.isEmpty {
            source.selectedTabID = source.tabs[min(location.tab, source.tabs.count - 1)].id
        }
        if source.tabs.isEmpty {
            workspaces.remove(at: location.workspace)
        } else {
            workspaces[location.workspace] = source
        }

        guard let target = workspaceIndex(of: id) else { return }
        workspaces[target].tabs.append(tab)
        workspaces[target].selectedTabID = tab.id
        if selectedWorkspaceID == source.id { selectedWorkspaceID = id }
    }

    /// Sets a workspace's custom name, or with nil, names it after its
    /// current tab again.
    func renameWorkspace(_ id: UUID, to name: String?) {
        guard let index = workspaceIndex(of: id) else { return }
        workspaces[index].customName = name
    }

    func moveWorkspace(_ id: UUID, to index: Int) {
        guard let from = workspaceIndex(of: id), workspaces.indices.contains(index) else { return }
        workspaces.insert(workspaces.remove(at: from), at: index)
    }

    /// Replaces every workspace, e.g. when restoring a window.
    func replaceWorkspaces(_ workspaces: [Workspace], selectedWorkspaceID: UUID?) {
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID ?? workspaces.first?.id
    }
}
