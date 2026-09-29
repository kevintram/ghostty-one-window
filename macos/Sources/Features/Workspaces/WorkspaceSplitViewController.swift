import AppKit
import Combine
import SwiftUI

/// The content of a terminal window: a full-height workspace sidebar beside
/// a column with the workspace tab strip above the terminal.
///
/// The sidebar is a native split view sidebar item in a full-size content
/// window, so it extends under the titlebar and the window buttons sit on
/// top of it.
final class WorkspaceSplitViewController: NSSplitViewController {
    let terminalContainer: TerminalViewContainer
    private weak var controller: TerminalController?
    private let model: WorkspaceModel
    private var tabStripVisibility: AnyCancellable?
    private var sidebarCollapse: AnyCancellable?
    private let sidebarInsets = WorkspaceSidebarInsets()

    /// Whether the sidebar's collapsed state has been applied yet. The first
    /// time isn't animated.
    private var appliedSidebarState = false

    private var sidebarItem: NSSplitViewItem? { splitViewItems.first }

    init(controller: TerminalController, terminalContainer: TerminalViewContainer) {
        self.controller = controller
        self.model = controller.workspaceModel
        self.terminalContainer = terminalContainer
        super.init(nibName: nil, bundle: nil)

        // The terminal only fills the detail column; keep its glass background
        // covering the whole window, behind the sidebar too.
        terminalContainer.extendsGlassBeyondWindow = true

        self.splitView = WorkspaceSplitView()
        setupItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Items are added before the view loads; NSSplitViewController's own
    /// viewDidLoad raises if it has no items to lay out.
    private func setupItems() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarController = NSHostingController(
            rootView: WorkspaceSidebarView(model: model, controller: .init(controller), insets: sidebarInsets))
        // Don't let SwiftUI's ideal size drive the window size.
        sidebarController.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.canCollapse = true
        // Only collapse when asked, not when the window gets narrow. Must come
        // after `canCollapse`, which resets it for sidebars.
        sidebar.canCollapseFromWindowResize = false
        sidebar.allowsFullHeightLayout = true
        sidebar.minimumThickness = WorkspaceModel.sidebarWidth
        sidebar.maximumThickness = WorkspaceModel.sidebarWidth
        addSplitViewItem(sidebar)

        sidebarCollapse = model.$isSidebarCollapsed
            .removeDuplicates()
            .sink { [weak self] collapsed in
                MainActor.assumeIsolated { self?.applySidebarState(collapsed: collapsed) }
            }

        // The terminal column extends under the titlebar, so pin our tab
        // strip below its safe area and the terminal below the strip.
        let detail = NSViewController()
        detail.view = NSView()

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        terminalContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        detail.view.addSubview(terminalContainer)

        // Added after the terminal so it draws above the terminal's glass
        // background, which extends up under the titlebar.
        let tabStrip = NSHostingView(rootView: WorkspaceTabStripView(model: model, controller: .init(controller)))
        tabStrip.sizingOptions = []
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(tabStrip)

        // Like the native tab bar, the strip is only shown with 2+ tabs, or
        // while a tab is being renamed in it.
        let tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        tabStripVisibility = model.$workspaces
            .combineLatest(model.$selectedWorkspaceID, model.$renaming)
            .map { workspaces, selectedID, renaming in
                let tabs = workspaces.first { $0.id == selectedID }?.tabs.count ?? 0
                guard case .tab = renaming else { return tabs > 1 }
                return true
            }
            .removeDuplicates()
            .sink { [weak tabStrip] visible in
                MainActor.assumeIsolated {
                    tabStripHeight.constant = visible ? WorkspaceModel.tabStripHeight : 0
                    tabStrip?.isHidden = !visible
                }
            }

        if let splitView = splitView as? WorkspaceSplitView {
            splitView.terminalContainer = terminalContainer
            splitView.tabStripHeight = tabStripHeight
            splitView.sidebarItem = sidebar
        }

        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            tabStripHeight,
            terminalContainer.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
        ])
        addSplitViewItem(NSSplitViewItem(viewController: detail))
    }

    // MARK: Sidebar

    override func viewDidLayout() {
        super.viewDidLayout()

        // The sidebar extends under the titlebar, so its content starts
        // below it. That's measured from the window rather than taken from
        // SwiftUI's safe area, which has been seen stale by 10pt (likely
        // after moving between displays).
        if let window = view.window {
            let titlebarHeight = window.frame.height - window.contentLayoutRect.maxY
            if sidebarInsets.top != titlebarHeight { sidebarInsets.top = titlebarHeight }
        }
    }

    /// The window content size that gives the terminal `size`, with the
    /// sidebar, titlebar and tab strip around it as they're laid out now.
    func contentSize(forTerminalSize size: CGSize) -> CGSize {
        view.layoutSubtreeIfNeeded()
        let terminal = terminalContainer.frame.size
        return CGSize(
            width: size.width + view.bounds.width - terminal.width,
            height: size.height + view.bounds.height - terminal.height)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installSidebarControls()
    }

    /// The standard action (View menu, ⌘B, the titlebar button) toggles the
    /// model's state, which the sidebar follows.
    override func toggleSidebar(_ sender: Any?) {
        model.isSidebarCollapsed.toggle()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)), let menuItem = item as? NSMenuItem {
            menuItem.title = sidebarItem?.isCollapsed ?? false ? "Show Sidebar" : "Hide Sidebar"
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Animates, except for the window's first state.
    private func applySidebarState(collapsed: Bool) {
        defer { appliedSidebarState = true }
        guard let sidebarItem, sidebarItem.isCollapsed != collapsed else { return }

        if appliedSidebarState, view.window?.isVisible == true {
            sidebarItem.animator().isCollapsed = collapsed
        } else {
            sidebarItem.isCollapsed = collapsed
        }
    }

    /// Liquid Glass sidebar controls beside the window buttons, like Finder's.
    /// They're a titlebar accessory, so they stay put while the sidebar
    /// collapses.
    private func installSidebarControls() {
        // Accessing titlebar accessories without a titlebar crashes, e.g.
        // while non-native fullscreen has removed it.
        guard let window = view.window, window.styleMask.contains(.titled),
              !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == Self.sidebarControlsIdentifier })
        else { return }

        let controls = NSHostingView(rootView: SidebarControls(
            model: model,
            newWorkspace: { [weak self] in
                // Show the sidebar so the new workspace appears in it.
                self?.model.isSidebarCollapsed = false
                self?.controller?.newWorkspace(nil)
            },
            toggleSidebar: { [weak self] in
                self?.toggleSidebar(nil)
            }))
        controls.frame = NSRect(x: 0, y: 0, width: 72, height: 28)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = Self.sidebarControlsIdentifier
        accessory.layoutAttribute = .left
        accessory.view = controls
        window.addTitlebarAccessoryViewController(accessory)
    }

    private static let sidebarControlsIdentifier = NSUserInterfaceItemIdentifier("workspaceSidebarControls")
}

/// New Workspace and the sidebar toggle as one Liquid Glass control in the
/// titlebar.
private struct SidebarControls: View {
    let model: WorkspaceModel
    let newWorkspace: () -> Void
    let toggleSidebar: () -> Void

    var body: some View {
        glass(HStack(spacing: 0) {
            button("rectangle.stack.badge.plus", action: newWorkspace)
                .help("New workspace")
            SidebarToggle(model: model, button: button("sidebar.left", action: toggleSidebar))
        })
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Interactive Liquid Glass around the buttons, or none before macOS 26.
    @ViewBuilder
    private func glass(_ content: some View) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
        }
#else
        content
#endif
    }
}

/// The sidebar toggle, with a tooltip that follows the collapsed state.
private struct SidebarToggle<Button: View>: View {
    @ObservedObject var model: WorkspaceModel
    let button: Button

    var body: some View {
        button.help(model.isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")
    }
}

/// Reports the terminal's intrinsic size plus the sidebar, titlebar and tab
/// strip so that `window-width`/`window-height` still size the terminal area.
private final class WorkspaceSplitView: NSSplitView {
    weak var terminalContainer: TerminalViewContainer?
    weak var tabStripHeight: NSLayoutConstraint?
    weak var sidebarItem: NSSplitViewItem?

    // AppKit gives each split view column its own titlebar background, with
    // macOS 26's scroll edge effect, drawn as an opaque band (and separator)
    // across the title row. Make them transparent so the title row shows the
    // window's glass. Ghostty's own titlebar transparency only reaches the
    // titlebar container, not these. AppKit adds them after the first layout
    // and manages their `isHidden` itself, so use their alpha instead.

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        hideIfTitlebarBackground(subview)
    }

    override func layout() {
        super.layout()
        subviews.forEach(hideIfTitlebarBackground)
    }

    private func hideIfTitlebarBackground(_ view: NSView) {
        if view.className == "NSTitlebarBackgroundView" { view.alphaValue = 0 }
    }

    override var intrinsicContentSize: NSSize {
        guard let size = terminalContainer?.intrinsicContentSize,
              size.width > 0, size.height > 0 else {
            return super.intrinsicContentSize
        }

        return NSSize(
            width: size.width + (sidebarItem?.isCollapsed ?? false ? 0 : dividerThickness + WorkspaceModel.sidebarWidth),
            height: size.height + safeAreaInsets.top + (tabStripHeight?.constant ?? 0))
    }
}
