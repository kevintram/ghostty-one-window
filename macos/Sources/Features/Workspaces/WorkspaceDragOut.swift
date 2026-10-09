import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Drags a tab out of the tab strip, or a workspace out of the sidebar, as a
/// system drag, to drop it in another place that takes it, in its own window
/// or another, or outside every window to give it a window of its own.
///
/// The tab strip and the sidebar reorder their items themselves. An item
/// pulled out of them continues as a system drag, with a preview of it under
/// the pointer. While the drag lasts, every window shows the place that
/// takes it (see `dragging`): its tab strip for a tab, its sidebar for a
/// workspace. Over a strip or a sidebar, its own or another window's, that
/// shows the item itself instead, so the preview is hidden. The pasteboard
/// only marks what kind of item is dragged: the item and its window are
/// `draggedTab` or `draggedWorkspace`.
///
/// The preview is drawn in a window of our own that follows the pointer,
/// and the system drag has an empty image. AppKit draws drag images
/// slightly translucent, with no way to change that, which lets text under
/// the preview show through it.
@MainActor
final class WorkspaceDragOut: NSObject, NSDraggingSource {
    /// What's dragged.
    enum Item {
        case tab(TerminalTab)
        case workspace(UUID)
    }

    enum Kind {
        case tab
        case workspace
    }

    /// The drag in progress, kept alive until it ends.
    private static var current: WorkspaceDragOut?

    /// The kind of item being dragged out, in any window.
    static let dragging = CurrentValueSubject<Kind?, Never>(nil)

    /// The tab being dragged out of a strip, and the window it's in.
    static var draggedTab: (tab: TerminalTab, source: TerminalController)? {
        guard let current, case .tab(let tab) = current.item, let source = current.source,
              source.workspaceModel.contains(tab) else { return nil }
        return (tab, source)
    }

    /// The workspace being dragged out of a sidebar, and the window it's in.
    static var draggedWorkspace: (id: UUID, source: TerminalController)? {
        guard let current, case .workspace(let id) = current.item, let source = current.source,
              source.workspaceModel.workspaceIndex(of: id) != nil else { return nil }
        return (id, source)
    }

    private let item: Item
    private weak var source: TerminalController?
    private let preview: DragPreviewWindow

    /// Where the item left its strip or sidebar, on screen. A cancelled
    /// drag's preview returns toward it.
    private let origin: NSPoint

    /// Watches for Escape, which cancels the drag rather than dropping the
    /// item outside every window.
    private var escapeMonitor: Any?
    private var cancelledByEscape = false

    private init(item: Item, source: TerminalController, preview: DragPreviewWindow, origin: NSPoint) {
        self.item = item
        self.source = source
        self.preview = preview
        self.origin = origin
    }

    /// Begins dragging an item of `source` from `view`, the strip or sidebar
    /// it was pressed in, with the drag event that pulled it out.
    static func begin(
        _ item: Item,
        of source: TerminalController,
        from view: NSView,
        with event: NSEvent
    ) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(Data(), forType: item.kind.pasteboardType)

        let preview = DragPreviewWindow(
            preview: DragPreview(item: item, in: source.workspaceModel),
            appearance: view.effectiveAppearance)
        let origin = PressDragTracker.screenPoint(of: event)
        preview.center(at: origin)
        preview.orderFront(nil)

        // The system drag needs an image, but ours is drawn by the preview.
        let size = preview.frame.size
        let point = view.convert(event.locationInWindow, from: nil)
        let dragging = NSDraggingItem(pasteboardWriter: pasteboardItem)
        dragging.setDraggingFrame(
            NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: NSImage(size: size))

        let drag = WorkspaceDragOut(item: item, source: source, preview: preview, origin: origin)
        current = drag
        drag.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak drag] event in
            if event.keyCode == 53 { drag?.cancelledByEscape = true }
            return event
        }
        let session = view.beginDraggingSession(with: [dragging], event: event, source: drag)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
        Self.dragging.send(item.kind)

        // The drag session consumes the release, so the press gesture would
        // never end and would swallow the next press. End it.
        if let release = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0) {
            view.mouseUp(with: release)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        preview.center(at: screenPoint)

        // A strip or sidebar shows the item while it's over it.
        preview.alphaValue = shownDrag == nil ? 1 : 0
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            Self.current = nil
            Self.dragging.send(nil)
        }

        if operation.isEmpty, !cancelledByEscape,
           !NSApp.windows.contains(where: { $0 !== preview && $0.isVisible && $0.frame.contains(screenPoint) }),
           dropOutsideWindows(at: screenPoint) {
            preview.orderOut(nil)
            return
        }

        // An item settling where it was dropped is let go once it has (see
        // `letGo`). Otherwise it's let go now, and shows where it is: where
        // it was dropped, or where it was if it wasn't.
        if shownDrag?.phase != .settling {
            withAnimation(.easeOut(duration: 0.15)) { Self.letGo(item) }
        }

        // Dropped somewhere that took it, the item is there. Otherwise it
        // returns to where it was, so the preview heads back toward it as it
        // fades.
        if operation.isEmpty, preview.alphaValue > 0 {
            preview.dismiss(toward: origin)
        } else {
            preview.orderOut(nil)
        }
    }

    /// Handles a drop outside every window: a tab gets a new window there,
    /// and so does a workspace, unless it's its window's only one, when the
    /// window moves there instead, as far as the pointer went. Returns false
    /// if nothing happened.
    private func dropOutsideWindows(at point: NSPoint) -> Bool {
        guard let source else { return false }
        switch item {
        case .tab(let tab):
            return source.workspaceModel.contains(tab) && source.moveTabToNewWindow(tab, position: point)

        case .workspace(let id):
            guard source.workspaceModel.workspaceIndex(of: id) != nil else { return false }
            if source.moveWorkspaceToNewWindow(id, position: point) { return true }
            guard let window = source.window else { return false }
            window.setFrameOrigin(NSPoint(
                x: window.frame.minX + point.x - origin.x,
                y: window.frame.minY + point.y - origin.y))
            letGoNow()
            return true
        }
    }

    /// Lets go of the item without animating, as it's somewhere else now.
    private func letGoNow() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { Self.letGo(item) }
    }

    /// Once an item dropped in a strip or sidebar has settled into its slot
    /// there (after `duration`), moves it there with `move` and ends its
    /// drag, without animating: by then it already shows where it moves. If
    /// `move` doesn't move it (e.g. its window went meanwhile), it shows
    /// where it still is.
    static func settle(_ item: Item, for duration: TimeInterval, move: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                move()
                letGo(item)
            }
        }
    }

    /// Ends an item's drag in every window: no strip or sidebar shows it
    /// dragged any more, so it shows where it is.
    static func letGo(_ item: Item) {
        for model in TerminalController.all.map(\.workspaceModel) {
            switch item {
            case .tab(let tab):
                if model.tabDrag?.id == tab.id { model.tabDrag = nil }
                if model.incomingTab === tab { model.incomingTab = nil }

            case .workspace(let id):
                if model.workspaceDrag?.id == id { model.workspaceDrag = nil }
                if model.incomingWorkspace?.id == id { model.incomingWorkspace = nil }
            }
        }
    }

    /// The drag state of the strip or sidebar showing the item, if one is:
    /// following the pointer, or settling where it was dropped.
    private var shownDrag: WorkspaceModel.ReorderDrag? {
        for model in TerminalController.all.map(\.workspaceModel) {
            let drag: WorkspaceModel.ReorderDrag?
            switch item {
            case .tab(let tab): drag = model.tabDrag.flatMap { $0.id == tab.id ? $0 : nil }
            case .workspace(let id): drag = model.workspaceDrag.flatMap { $0.id == id ? $0 : nil }
            }
            if let drag, drag.phase != .draggingOut { return drag }
        }
        return nil
    }
}

extension WorkspaceDragOut.Item {
    var kind: WorkspaceDragOut.Kind {
        switch self {
        case .tab: .tab
        case .workspace: .workspace
        }
    }
}

extension WorkspaceDragOut.Kind {
    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .tab: .ghosttyWorkspaceTab
        case .workspace: .ghosttyWorkspace
        }
    }
}

/// A borderless window showing the dragged item's preview, following the
/// pointer without taking clicks or focus.
@MainActor
private final class DragPreviewWindow: NSPanel {
    init(preview: DragPreview, appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let content = NSHostingView(rootView: preview
            .environment(\.colorScheme, isDark ? .dark : .light))
        content.frame.size = content.fittingSize

        super.init(
            contentRect: NSRect(origin: .zero, size: content.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        self.appearance = appearance
        contentView = content
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        // Shown on every Space, since the pointer can reach another one (a
        // Space switch or another display) mid-drag, and over full-screen
        // windows.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    /// Centers the preview under the pointer.
    func center(at point: NSPoint) {
        setFrameOrigin(NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2))
    }

    /// Slides toward `point` while fading out, then goes away.
    func dismiss(toward point: NSPoint) {
        var target = frame
        target.origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(target, display: true)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }
}

/// What's dragged when an item leaves its strip or sidebar: a card with its
/// icon and name, rather than an image of the item itself.
private struct DragPreview: View {
    let systemImage: String
    let title: String

    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    init(item: WorkspaceDragOut.Item, in model: WorkspaceModel) {
        switch item {
        case .tab(let tab):
            systemImage = "terminal"
            title = tab.title

        case .workspace(let id):
            systemImage = "rectangle.stack"
            title = model.workspaces.first { $0.id == id }?.name ?? ""
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? Color(white: 0.22) : Color.white)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        // Room for the shadow.
        .padding(10)
    }
}

extension UTType {
    /// A tab dragged out of a workspace tab strip.
    static let ghosttyWorkspaceTab = UTType(exportedAs: "com.mitchellh.ghosttyWorkspaceTab")

    /// A workspace dragged out of the workspace sidebar.
    static let ghosttyWorkspace = UTType(exportedAs: "com.mitchellh.ghosttyWorkspace")
}

extension NSPasteboard.PasteboardType {
    static let ghosttyWorkspaceTab = NSPasteboard.PasteboardType(UTType.ghosttyWorkspaceTab.identifier)
    static let ghosttyWorkspace = NSPasteboard.PasteboardType(UTType.ghosttyWorkspace.identifier)
}
