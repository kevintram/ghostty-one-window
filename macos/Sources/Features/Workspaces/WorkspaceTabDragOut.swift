import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drags a tab out of the tab strip as a system drag, to drop it on a
/// workspace in the sidebar.
///
/// The tab strip reorders its tabs itself. A tab pulled out of the strip
/// continues as a system drag, which shows a preview of the tab under the
/// pointer and which the sidebar's workspace rows accept. The pasteboard
/// only marks the drag as a tab: the dragged tab is the group's `tabDrag`.
@MainActor
final class WorkspaceTabDragOut: NSObject, NSDraggingSource {
    /// The drag in progress, kept alive until it ends.
    private static var current: WorkspaceTabDragOut?

    private weak var group: WorkspaceWindowGroup?

    private init(group: WorkspaceWindowGroup) {
        self.group = group
    }

    /// Begins dragging the tab from `view`, the strip it was pressed in,
    /// with the drag event that pulled it out.
    static func begin(_ window: NSWindow, in group: WorkspaceWindowGroup, from view: NSView, with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setData(Data(), forType: .ghosttyWorkspaceTab)

        // Centered under the pointer.
        let image = preview(title: window.title, in: view)
        let point = view.convert(event.locationInWindow, from: nil)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(
            NSRect(
                x: point.x - image.size.width / 2,
                y: point.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height),
            contents: image)

        let source = WorkspaceTabDragOut(group: group)
        current = source
        let session = view.beginDraggingSession(with: [dragging], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
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

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // A dropped tab has already left the strip; one that wasn't dropped
        // is shown again where it was.
        if group?.tabDrag?.phase == .draggingOut {
            withAnimation(.easeOut(duration: 0.15)) { group?.tabDrag = nil }
        }
        Self.current = nil
    }

    private static func preview(title: String, in view: NSView) -> NSImage {
        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = ImageRenderer(content: TabDragPreview(title: title)
            .environment(\.colorScheme, isDark ? .dark : .light))
        renderer.scale = view.window?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage()
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
