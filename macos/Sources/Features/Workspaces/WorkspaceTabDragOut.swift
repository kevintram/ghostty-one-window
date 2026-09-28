import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drags a tab out of the tab strip as a system drag, to drop it on a
/// workspace in the sidebar.
///
/// The tab strip reorders its tabs itself. A tab pulled out of the strip
/// continues as a system drag, which the sidebar's workspace rows accept,
/// with a preview of the tab under the pointer. Back over the strip, the
/// strip shows the tab itself instead, so the preview is hidden. The
/// pasteboard only marks the drag as a tab: the dragged tab is the model's
/// `tabDrag`.
///
/// The preview is drawn in a window of our own that follows the pointer,
/// and the system drag has an empty image. AppKit draws drag images
/// slightly translucent, with no way to change that, which lets text under
/// the preview show through it.
@MainActor
final class WorkspaceTabDragOut: NSObject, NSDraggingSource {
    /// The drag in progress, kept alive until it ends.
    private static var current: WorkspaceTabDragOut?

    private weak var model: WorkspaceModel?
    private let preview: TabDragPreviewWindow

    /// Where the tab left the strip, on screen. A cancelled drag's preview
    /// returns toward it.
    private let origin: NSPoint

    private init(model: WorkspaceModel, preview: TabDragPreviewWindow, origin: NSPoint) {
        self.model = model
        self.preview = preview
        self.origin = origin
    }

    /// Begins dragging the tab from `view`, the strip it was pressed in,
    /// with the drag event that pulled it out.
    static func begin(
        _ tab: TerminalTab,
        in model: WorkspaceModel,
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

        let source = WorkspaceTabDragOut(model: model, preview: preview, origin: origin)
        current = source
        let session = view.beginDraggingSession(with: [dragging], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none

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

        // The strip shows the tab while it's back over it.
        preview.alphaValue = model?.tabDrag?.phase == .following ? 0 : 1
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Unless it's settling into its slot after a drop on the strip, the
        // tab shows in the strip again: at the end of the workspace it was
        // dropped on, or where it was if it wasn't dropped.
        let phase = model?.tabDrag?.phase
        if let phase, phase != .settling {
            withAnimation(.easeOut(duration: 0.15)) { model?.tabDrag = nil }
        }

        // Dropped on a workspace, the tab is there; dropped on the strip, it's
        // already back in it. Otherwise it returns to the strip, so the
        // preview heads back toward it as it fades.
        if operation.isEmpty, preview.alphaValue > 0 {
            preview.dismiss(toward: origin)
        } else {
            preview.orderOut(nil)
        }
        Self.current = nil
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
