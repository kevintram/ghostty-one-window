import AppKit

/// AppleScript-facing wrapper around a single tab in a scripting window.
///
/// `ScriptWindow.tabs` vends these objects so AppleScript can traverse
/// `window -> tab` without knowing anything about AppKit controllers.
@MainActor
@objc(GhosttyScriptTab)
final class ScriptTab: NSObject {
    /// Stable identifier used by AppleScript `tab id "..."` references.
    private let stableID: String

    /// Weak back-reference to the scripting window that owns this tab wrapper.
    ///
    /// We only need this for dynamic properties (`index`, `selected`) and for
    /// building an object specifier path.
    private weak var window: ScriptWindow?

    /// Live controller of the tab's window.
    ///
    /// This can become `nil` if the window closes while a script is running.
    private weak var controller: BaseTerminalController?

    /// The tab, or nil for a window without tabs (the quick terminal), whose
    /// only tab is the controller's split tree.
    private weak var tab: TerminalTab?
    private let hasTab: Bool

    /// Called by `ScriptWindow.tabs` / `ScriptWindow.selectedTab`.
    ///
    /// The ID is computed once so object specifiers built from this instance keep
    /// a consistent tab identity.
    init(window: ScriptWindow, controller: BaseTerminalController, tab: TerminalTab?) {
        self.stableID = Self.stableID(controller: controller, tab: tab)
        self.window = window
        self.controller = controller
        self.tab = tab
        self.hasTab = tab != nil
    }

    /// Exposed as the AppleScript `id` property.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled, isAlive else { return "" }
        return tab?.title ?? controller?.window?.title ?? ""
    }

    /// Exposed as the AppleScript `index` property.
    ///
    /// Cocoa scripting expects this to be 1-based for user-facing collections.
    @objc(index)
    var index: Int {
        guard NSApp.isAppleScriptEnabled, isAlive else { return 0 }
        return window?.tabIndex(for: tab) ?? 0
    }

    /// Exposed as the AppleScript `selected` property.
    ///
    /// Powers script conditions such as `if selected of tab 1 then ...`.
    @objc(selected)
    var selected: Bool {
        guard NSApp.isAppleScriptEnabled, isAlive else { return false }
        return window?.tabIsSelected(tab) ?? false
    }

    /// Exposed as the AppleScript `focused terminal` property.
    ///
    /// Uses the currently focused surface for this tab.
    @objc(focusedTerminal)
    var focusedTerminal: ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled, isAlive, let controller else { return nil }
        guard let surface = hasTab ? tab?.focusedSurface : controller.focusedSurface,
              surfaceTree.contains(surface)
        else { return nil }

        return ScriptTerminal(surfaceView: surface)
    }

    /// Best-effort native window containing this tab.
    var parentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled, isAlive else { return nil }
        return controller?.window
    }

    /// Live controller backing this tab wrapper.
    var parentController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled, isAlive else { return nil }
        return controller
    }

    /// Exposed as the AppleScript `terminals` element on a tab.
    ///
    /// Returns all terminal surfaces (split panes) within this tab.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        return (surfaceTree.root?.leaves() ?? []).map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a tab.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return (surfaceTree.root?.leaves() ?? [])
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// Handler for `select tab <tab>`.
    @objc(handleSelectTabCommand:)
    func handleSelectTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        if let tab, let controller = controller as? TerminalController {
            controller.selectTab(tab)
        }
        tabContainerWindow.makeKeyAndOrderFront(nil)
        return nil
    }

    /// Handler for `close tab <tab>`.
    @objc(handleCloseTabCommand:)
    func handleCloseTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let tabController = parentController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        if let tab, let managedTerminalController = tabController as? TerminalController {
            managedTerminalController.closeTabImmediately(tab, registerRedo: false)
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab container window is no longer available."
            return nil
        }

        tabContainerWindow.close()
        return nil
    }

    /// Whether the tab still exists.
    private var isAlive: Bool {
        controller != nil && (!hasTab || tab != nil)
    }

    /// The tab's terminals.
    private var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        guard isAlive else { return .init() }
        return hasTab ? tab?.surfaceTree ?? .init() : controller?.surfaceTree ?? .init()
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let window else { return nil }
        guard let windowClassDescription = window.classDescription as? NSScriptClassDescription else {
            return nil
        }
        guard let windowSpecifier = window.objectSpecifier else { return nil }

        // This tells Cocoa how to re-find this tab later:
        // application -> scriptWindows[id] -> tabs[id].
        return NSUniqueIDSpecifier(
            containerClassDescription: windowClassDescription,
            containerSpecifier: windowSpecifier,
            key: "tabs",
            uniqueID: stableID
        )
    }
}

extension ScriptTab {
    /// Stable ID for one tab, or for the only tab of a window without tabs.
    ///
    /// Tab identity belongs to `ScriptTab`, so both tab creation and tab ID
    /// lookups in `ScriptWindow` call this helper.
    static func stableID(controller: BaseTerminalController, tab: TerminalTab?) -> String {
        if let tab { return "tab-\(tab.id.uuidString)" }
        return "tab-\(ObjectIdentifier(controller).hexString)"
    }
}
