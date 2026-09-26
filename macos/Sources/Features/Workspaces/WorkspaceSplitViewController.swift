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
        sidebar.canCollapse = false
        sidebar.allowsFullHeightLayout = true
        sidebar.minimumThickness = WorkspaceWindowGroup.sidebarWidth
        sidebar.maximumThickness = WorkspaceWindowGroup.sidebarWidth
        addSplitViewItem(sidebar)

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
}

/// Reports the terminal's intrinsic size plus the sidebar, titlebar and tab
/// strip so that `window-width`/`window-height` still size the terminal area.
private final class WorkspaceSplitView: NSSplitView {
    weak var terminalContainer: TerminalViewContainer?
    weak var tabStripHeight: NSLayoutConstraint?

    override var intrinsicContentSize: NSSize {
        guard let size = terminalContainer?.intrinsicContentSize,
              size.width > 0, size.height > 0 else {
            return super.intrinsicContentSize
        }

        return NSSize(
            width: size.width + dividerThickness + WorkspaceWindowGroup.sidebarWidth,
            height: size.height + safeAreaInsets.top + (tabStripHeight?.constant ?? 0))
    }
}
