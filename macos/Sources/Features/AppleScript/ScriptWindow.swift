import AppKit

/// AppleScript-facing wrapper around a Ghostty window.
///
/// A terminal window holds all of its tabs (see `TerminalController`), so a
/// scripting window is one window controller, and its tabs are the tabs of
/// all of the window's workspaces, in workspace order. Other terminal
/// windows (the quick terminal) have a single tab.
@MainActor
@objc(GhosttyScriptWindow)
final class ScriptWindow: NSObject {
    /// Stable identifier used by AppleScript `window id "..."` references.
    ///
    /// We precompute this once so the object keeps a consistent ID for its whole
    /// lifetime, even if AppKit window bookkeeping changes after creation.
    let stableID: String

    private weak var controller: BaseTerminalController?

    /// `scriptWindows` in `AppDelegate+AppleScript` constructs these objects.
    ///
    /// `stableID` must match the same identity scheme used by
    /// `valueInScriptWindowsWithUniqueID:` so Cocoa can re-resolve object
    /// specifiers produced earlier in a script.
    init(controller: BaseTerminalController) {
        self.stableID = Self.stableID(controller: controller)
        self.controller = controller
    }

    /// Exposed as the AppleScript `id` property.
    ///
    /// This is what scripts read with `id of window ...`.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return controller?.window?.title ?? ""
    }

    /// Exposed as the AppleScript `tabs` element.
    ///
    /// Cocoa asks for this collection when a script evaluates `tabs of window ...`
    /// or any tab-filter expression. We build wrappers from live controller state
    /// so tab additions/removals are reflected immediately.
    @objc(tabs)
    var tabs: [ScriptTab] {
        guard NSApp.isAppleScriptEnabled, let controller else { return [] }
        return terminalTabs.map { ScriptTab(window: self, controller: controller, tab: $0) }
    }

    /// Exposed as the AppleScript `selected tab` property.
    ///
    /// This powers expressions like `selected tab of window 1`.
    @objc(selectedTab)
    var selectedTab: ScriptTab? {
        guard NSApp.isAppleScriptEnabled, let controller else { return nil }
        return ScriptTab(window: self, controller: controller, tab: (controller as? TerminalController)?.selectedTab)
    }

    /// Enables unique-ID lookup for `tabs` references.
    ///
    /// Required selector pattern for the `tabs` element key:
    /// `valueInTabsWithUniqueID:`.
    ///
    /// Cocoa uses this when a script resolves `tab id "..." of window ...`.
    @objc(valueInTabsWithUniqueID:)
    func valueInTabs(uniqueID: String) -> ScriptTab? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return tabs.first { $0.idValue == uniqueID }
    }

    /// Exposed as the AppleScript `terminals` element on a window.
    ///
    /// Returns all terminal surfaces across every tab in this window.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        return (controller?.allSurfaces ?? []).map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a window.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller?.allSurfaces
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// AppleScript tab indexes are 1-based, so we add one to Swift's 0-based
    /// array index. A nil tab is a window's only tab.
    func tabIndex(for tab: TerminalTab?) -> Int? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return terminalTabs.firstIndex(where: { $0 === tab }).map { $0 + 1 }
    }

    /// Reports whether a given tab is this window's selected tab.
    func tabIsSelected(_ tab: TerminalTab?) -> Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        return (controller as? TerminalController)?.selectedTab === tab
    }

    /// Best-effort native window to use as a tab parent for AppleScript commands.
    var preferredParentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller?.window
    }

    /// Best-effort controller to use for window-scoped AppleScript commands.
    var preferredController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller
    }

    /// The window's tabs. Windows without tabs have one, nil.
    private var terminalTabs: [TerminalTab?] {
        guard let controller = controller as? TerminalController else { return [nil] }
        return controller.workspaceModel.allTabs
    }

    /// Handler for `activate window <window>`.
    @objc(handleActivateWindowCommand:)
    func handleActivateWindow(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let windowContainer = preferredParentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Window is no longer available."
            return nil
        }

        windowContainer.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }

    /// Handler for `close window <window>`.
    @objc(handleCloseWindowCommand:)
    func handleCloseWindow(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        if let managedTerminalController = preferredController as? TerminalController {
            managedTerminalController.closeWindowImmediately()
            return nil
        }

        guard let windowContainer = preferredParentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Window is no longer available."
            return nil
        }

        windowContainer.close()
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    ///
    /// Without this, Cocoa can return data but cannot reliably build object
    /// references for later script statements. This specifier encodes:
    /// `application -> scriptWindows[id]`.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "scriptWindows",
            uniqueID: stableID
        )
    }
}

extension ScriptWindow {
    /// Produces the window-level stable ID from its controller.
    ///
    /// Windows are keyed by window identity; detached controllers fall back
    /// to controller identity.
    static func stableID(controller: BaseTerminalController) -> String {
        guard let window = controller.window else {
            return "controller-\(ObjectIdentifier(controller).hexString)"
        }

        return "window-\(ObjectIdentifier(window).hexString)"
    }
}
