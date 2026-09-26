import AppKit
import Combine
import SwiftUI

/// The content of a terminal tab window: a full-height workspace sidebar
/// beside a column with the workspace tab strip above the terminal.
///
/// The sidebar is a native split view sidebar item in a full-size content
/// window, so it extends under the titlebar and the window buttons sit on
/// top of it.
final class WorkspaceSplitViewController: NSSplitViewController {
    let terminalContainer: TerminalViewContainer
    private let membership: WorkspaceMembership
    private var tabStripVisibility: AnyCancellable?
    private var sidebarCollapse: AnyCancellable?

    /// Whether this window has applied its group's sidebar state yet. The
    /// first time isn't animated, e.g. a new tab opening while the sidebar
    /// is collapsed.
    private var appliedSidebarState = false

    private var sidebarItem: NSSplitViewItem? { splitViewItems.first }

    init(membership: WorkspaceMembership, terminalContainer: TerminalViewContainer) {
        self.membership = membership
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

        let sidebarController = NSHostingController(rootView: WorkspaceSidebarView(membership: membership))
        // Don't let SwiftUI's ideal size drive the window size.
        sidebarController.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.canCollapse = true
        // Only collapse when asked, not when the window gets narrow. Must come
        // after `canCollapse`, which resets it for sidebars.
        sidebar.canCollapseFromWindowResize = false
        sidebar.allowsFullHeightLayout = true
        sidebar.minimumThickness = WorkspaceWindowGroup.sidebarWidth
        sidebar.maximumThickness = WorkspaceWindowGroup.sidebarWidth
        addSplitViewItem(sidebar)

        // Every tab window of the group follows the group's collapsed state.
        sidebarCollapse = membership.$group
            .compactMap { $0?.$isSidebarCollapsed }
            .switchToLatest()
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
        let tabStrip = NSHostingView(rootView: WorkspaceTabStripView(membership: membership))
        tabStrip.sizingOptions = []
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(tabStrip)

        // Like the native tab bar, the strip is only shown with 2+ tabs.
        let tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        tabStripVisibility = membership.$group
            .map { group -> AnyPublisher<Bool, Never> in
                guard let group else { return Just(false).eraseToAnyPublisher() }
                return group.$tabs.map { $0.count > 1 }.eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .sink { [weak tabStrip] visible in
                MainActor.assumeIsolated {
                    tabStripHeight.constant = visible ? WorkspaceWindowGroup.tabStripHeight : 0
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

    override func viewWillAppear() {
        super.viewWillAppear()
        installSidebarToggleButton()
    }

    /// Collapsing is shared by the group, so the standard action (View menu,
    /// ⌘B, the titlebar button) toggles the group's state rather than just
    /// this window's sidebar.
    override func toggleSidebar(_ sender: Any?) {
        guard let group = membership.group else {
            super.toggleSidebar(sender)
            return
        }
        group.toggleSidebar()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)), let menuItem = item as? NSMenuItem {
            menuItem.title = sidebarItem?.isCollapsed ?? false ? "Show Sidebar" : "Hide Sidebar"
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Animates only in the key window, the tab being toggled; other tabs
    /// (and a window's first state) change instantly so switching tabs
    /// never animates.
    private func applySidebarState(collapsed: Bool) {
        defer { appliedSidebarState = true }
        guard let sidebarItem, sidebarItem.isCollapsed != collapsed else { return }

        if appliedSidebarState, view.window?.isKeyWindow == true {
            sidebarItem.animator().isCollapsed = collapsed
        } else {
            sidebarItem.isCollapsed = collapsed
        }
    }

    /// A Liquid Glass sidebar button beside the window buttons, like Finder's.
    /// It's a titlebar accessory, so it stays put while the sidebar collapses.
    private func installSidebarToggleButton() {
        // Accessing titlebar accessories without a titlebar crashes, e.g.
        // while non-native fullscreen has removed it.
        guard let window = view.window, window.styleMask.contains(.titled),
              !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == Self.sidebarToggleIdentifier })
        else { return }

        let button = NSHostingView(rootView: SidebarToggleButton { [weak self] in
            self?.toggleSidebar(nil)
        })
        button.frame = NSRect(x: 0, y: 0, width: 44, height: 28)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = Self.sidebarToggleIdentifier
        accessory.layoutAttribute = .left
        accessory.view = button
        window.addTitlebarAccessoryViewController(accessory)
    }

    private static let sidebarToggleIdentifier = NSUserInterfaceItemIdentifier("workspaceSidebarToggle")
}

private struct SidebarToggleButton: View {
    let action: () -> Void

    var body: some View {
        glass(Button(action: action) {
            Image(systemName: "sidebar.left")
                .frame(width: 16, height: 16)
        })
        .help("Hide or Show Sidebar")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A circular Liquid Glass button, or a borderless one before macOS 26.
    @ViewBuilder
    private func glass(_ button: some View) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            button.buttonStyle(.borderless)
        }
#else
        button.buttonStyle(.borderless)
#endif
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
            width: size.width + (sidebarItem?.isCollapsed ?? false ? 0 : dividerThickness + WorkspaceWindowGroup.sidebarWidth),
            height: size.height + safeAreaInsets.top + (tabStripHeight?.constant ?? 0))
    }
}
