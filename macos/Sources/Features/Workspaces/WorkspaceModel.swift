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

/// A named, ordered group of tabs in a window.
struct Workspace: Identifiable {
    let id: UUID
    var name: String
    var tabs: [TerminalTab]

    /// The tab shown when the workspace is selected.
    var selectedTabID: UUID?

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
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

    @Published var isSidebarCollapsed = false

    /// The tab whose title is being edited in the tab strip, which shows
    /// while it is, even for a single tab.
    @Published var renamingTabID: UUID?

    /// The `goto_tab` shortcut of each tab position, e.g. "⌘1".
    @Published var tabShortcuts: [String?] = []

    /// A tab being dragged in the tab strip, and how far it's been dragged.
    struct TabDrag: Equatable {
        enum Phase {
            /// Following the pointer within the strip.
            case following

            /// Released and animating into its slot, before the tab moves.
            case settling

            /// Dragged out of the strip as a system drag, to be dropped on a
            /// workspace in the sidebar.
            case draggingOut
        }

        let id: UUID
        var offset: CGFloat = 0
        var phase = Phase.following
    }

    @Published var tabDrag: TabDrag?

    /// A workspace being dragged in the sidebar, and how far it's been
    /// dragged.
    struct WorkspaceDrag: Equatable {
        let id: UUID
        var offset: CGFloat = 0
    }

    @Published var workspaceDrag: WorkspaceDrag?

    /// Used for default names. Never reused within a window.
    private var nextNumber = 1

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

    func workspace(of tab: TerminalTab) -> Workspace? {
        location(of: tab).map { workspaces[$0.workspace] }
    }

    func contains(_ tab: TerminalTab) -> Bool {
        location(of: tab) != nil
    }

    func tab(id: UUID) -> TerminalTab? {
        allTabs.first { $0.id == id }
    }

    /// The tab whose split tree holds the surface.
    func tab(owning surface: Ghostty.SurfaceView) -> TerminalTab? {
        allTabs.first { $0.surfaceTree.contains(surface) }
    }

    // MARK: Changes

    /// Appends a new workspace with a default name, or inserts it at
    /// `index`, and returns its ID. It has no tabs until one is inserted.
    @discardableResult
    func addWorkspace(id: UUID = UUID(), name: String? = nil, at index: Int? = nil) -> UUID {
        let workspace = Workspace(id: id, name: name ?? "Workspace \(nextNumber)", tabs: [])
        if name == nil { nextNumber += 1 }
        workspaces.insert(workspace, at: min(index ?? workspaces.endIndex, workspaces.endIndex))
        return id
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
        if renamingTabID == tab.id { renamingTabID = nil }
    }

    /// Makes the tab the selected one, and its workspace the selected
    /// workspace.
    func select(_ tab: TerminalTab) {
        guard let location = location(of: tab) else { return }
        workspaces[location.workspace].selectedTabID = tab.id
        selectedWorkspaceID = workspaces[location.workspace].id
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

    func moveWorkspace(_ id: UUID, to index: Int) {
        guard let from = workspaceIndex(of: id), workspaces.indices.contains(index) else { return }
        workspaces.insert(workspaces.remove(at: from), at: index)
    }

    /// Replaces every workspace, e.g. when restoring a window.
    func replaceWorkspaces(_ workspaces: [Workspace], selectedWorkspaceID: UUID?) {
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID ?? workspaces.first?.id

        // Continue default names after the restored ones.
        let numbers = workspaces.compactMap { Int($0.name.trimmingPrefix("Workspace ")) }
        nextNumber = max(nextNumber, (numbers.max() ?? 0) + 1)
    }
}
