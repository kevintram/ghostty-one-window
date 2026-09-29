import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Drags a tab out of the tab strip as a system drag, to drop it on a
/// workspace in the sidebar, on another window's tab strip, or outside every
/// window to give it a window of its own.
///
/// The tab strip reorders its tabs itself. A tab pulled out of the strip
/// continues as a system drag, with a preview of the tab under the pointer.
/// While the drag lasts, every window shows its tab strip (see
/// `isDragging`). Over a strip, its own or another window's, the strip shows
/// the tab itself instead, so the preview is hidden. The pasteboard only
/// marks the drag as a tab: the dragged tab and its window are `dragged`.
///
/// The preview is drawn in a window of our own that follows the pointer,
/// and the system drag has an empty image. AppKit draws drag images
/// slightly translucent, with no way to change that, which lets text under
/// the preview show through it.
@MainActor
final class WorkspaceTabDragOut: NSObject, NSDraggingSource {
    /// The drag in progress, kept alive until it ends.
    private static var current: WorkspaceTabDragOut?

    /// Whether a tab is being dragged out of a strip, in any window.
    static let isDragging = CurrentValueSubject<Bool, Never>(false)

    /// The tab being dragged out of a strip, and the window it's in.
    static var dragged: (tab: TerminalTab, source: TerminalController)? {
        guard let current, let tab = current.tab, let source = current.source,
              source.workspaceModel.contains(tab) else { return nil }
        return (tab, source)
    }

    private weak var tab: TerminalTab?
    private weak var source: TerminalController?
    private let preview: TabDragPreviewWindow

    /// Where the tab left the strip, on screen. A cancelled drag's preview
    /// returns toward it.
    private let origin: NSPoint

    /// Watches for Escape, which cancels the drag rather than dropping the
    /// tab outside every window.
    private var escapeMonitor: Any?
    private var cancelledByEscape = false

    private init(tab: TerminalTab, source: TerminalController, preview: TabDragPreviewWindow, origin: NSPoint) {
        self.tab = tab
        self.source = source
        self.preview = preview
        self.origin = origin
    }

    /// Begins dragging the tab of `source` from `view`, the strip it was
    /// pressed in, with the drag event that pulled it out.
    static func begin(
        _ tab: TerminalTab,
        of source: TerminalController,
        from view: NSView,
        with event: NSEvent
    ) {
        let item = NSPasteboardItem()
        item.setData(Data(), forType: .ghosttyWorkspaceTab)

        let preview = TabDragPreviewWindow(title: tab.title, appearance: view.effectiveAppearance)
        let origin = PressDragTracker.screenPoint(of: event)
        preview.center(at: origin)
        preview.orderFront(nil)

        // The system drag needs an image, but ours is drawn by the preview.
        let size = preview.frame.size
        let point = view.convert(event.locationInWindow, from: nil)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(
            NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: NSImage(size: size))

        let drag = WorkspaceTabDragOut(tab: tab, source: source, preview: preview, origin: origin)
        current = drag
        drag.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak drag] event in
            if event.keyCode == 53 { drag?.cancelledByEscape = true }
            return event
        }
        let session = view.beginDraggingSession(with: [dragging], event: event, source: drag)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
        isDragging.send(true)

        // The drag session consumes the release, so the strip's press
        // gesture would never end and would swallow the next press. End it.
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

        // A strip shows the tab while it's over it.
        preview.alphaValue = modelShowingTab == nil ? 1 : 0
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            Self.current = nil
            Self.isDragging.send(false)
        }

        // Dropped outside every window, the tab gets a window of its own there.
        if operation.isEmpty, !cancelledByEscape, let tab, let source,
           !NSApp.windows.contains(where: { $0 !== preview && $0.isVisible && $0.frame.contains(screenPoint) }),
           source.moveTabToNewWindow(tab, position: screenPoint) {
            preview.orderOut(nil)
            return
        }

        // A tab settling into a strip it was dropped on is let go once it
        // has (see `letGo`). Otherwise it's let go now, and shows in its own
        // strip again: at the end of the workspace it was dropped on, or
        // where it was if it wasn't dropped.
        if let tab, modelShowingTab?.tabDrag?.phase != .settling {
            withAnimation(.easeOut(duration: 0.15)) { Self.letGo(tab) }
        }

        // Dropped on a workspace or a strip, the tab is there. Otherwise it
        // returns to its strip, so the preview heads back toward it as it
        // fades.
        if operation.isEmpty, preview.alphaValue > 0 {
            preview.dismiss(toward: origin)
        } else {
            preview.orderOut(nil)
        }
    }

    /// Ends a tab's drag in every window: no strip shows it dragged any more,
    /// so it shows where it is.
    static func letGo(_ tab: TerminalTab) {
        for model in TerminalController.all.map(\.workspaceModel) {
            if model.tabDrag?.id == tab.id { model.tabDrag = nil }
            if model.incomingTab === tab { model.incomingTab = nil }
        }
    }

    /// The model of the strip showing the dragged tab, if one is: following
    /// the pointer, or settling where it was dropped.
    private var modelShowingTab: WorkspaceModel? {
        guard let tab else { return nil }
        return TerminalController.all.lazy.map(\.workspaceModel).first {
            guard let drag = $0.tabDrag, drag.id == tab.id else { return false }
            return drag.phase != .draggingOut
        }
    }
}

/// A borderless window showing the dragged tab's preview, following the
/// pointer without taking clicks or focus.
@MainActor
private final class TabDragPreviewWindow: NSPanel {
    init(title: String, appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let content = NSHostingView(rootView: TabDragPreview(title: title)
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

/// What's dragged when a tab leaves the strip: a card with the tab's title,
/// rather than an image of the tab itself.
private struct TabDragPreview: View {
    let title: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
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
}

extension NSPasteboard.PasteboardType {
    static let ghosttyWorkspaceTab = NSPasteboard.PasteboardType(UTType.ghosttyWorkspaceTab.identifier)
}
