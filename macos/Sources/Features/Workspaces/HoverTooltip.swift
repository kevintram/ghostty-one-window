import AppKit
import SwiftUI

/// Coordinates the tooltips in one workspace window. AppKit's native help
/// tags don't expose their delay and can restart their timer when SwiftUI
/// replaces hovered content, so these tooltips use stable tracking views and
/// an explicitly shared warm state.
@MainActor
final class HoverTooltipCoordinator {
    private static let initialDelay: Duration = .milliseconds(400)
    private static let warmDelay: Duration = .milliseconds(75)
    private static let warmGrace: Duration = .milliseconds(300)

    private final class Target {
        let id: UUID
        weak var view: NSView?
        var text: String
        let order: UInt64

        init(id: UUID, view: NSView, text: String, order: UInt64) {
            self.id = id
            self.view = view
            self.text = text
            self.order = order
        }
    }

    private var targets: [UUID: Target] = [:]
    private var nextOrder: UInt64 = 0
    private var activeID: UUID?
    private var displayedID: UUID?
    private var isWarm = false
    private var showTask: Task<Void, Never>?
    private var coolTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private let panel = HoverTooltipPanel()

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func entered(id: UUID, view: NSView, text: String) {
        nextOrder &+= 1
        targets[id] = Target(id: id, view: view, text: text, order: nextOrder)
        coolTask?.cancel()
        coolTask = nil
        installEventMonitor()
        activate(id)
    }

    func updated(id: UUID, view: NSView, text: String) {
        guard let target = targets[id] else { return }
        target.view = view
        target.text = text
        if displayedID == id { panel.update(text: text) }
    }

    func exited(id: UUID) {
        targets[id] = nil
        guard activeID == id else { return }

        if let next = targets.values.max(by: { $0.order < $1.order }) {
            activate(next.id)
        } else {
            activeID = nil
            showTask?.cancel()
            showTask = nil
            hidePanel()
            removeEventMonitor()
            scheduleCooling()
        }
    }

    private func activate(_ id: UUID) {
        guard let target = targets[id] else { return }
        activeID = id
        showTask?.cancel()
        hidePanel()

        let delay = isWarm ? Self.warmDelay : Self.initialDelay
        showTask = Task { @MainActor [weak self, weak target] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self,
                  let target,
                  self.activeID == id,
                  self.targets[id] === target,
                  let view = target.view,
                  view.window?.isVisible == true
            else { return }

            self.displayedID = id
            self.isWarm = true
            self.panel.show(text: target.text, near: NSEvent.mouseLocation, in: view.window)
        }
    }

    private func hidePanel() {
        displayedID = nil
        panel.hide()
    }

    private func scheduleCooling() {
        guard isWarm else { return }
        coolTask?.cancel()
        coolTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.warmGrace)
            guard !Task.isCancelled, let self, self.targets.isEmpty else { return }
            self.isWarm = false
            self.coolTask = nil
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .scrollWheel,
            ]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self,
                          self.targets.values.contains(where: { $0.view?.window === event.window })
                    else { return }
                    self.cancelInteraction()
                }
                return event
            }
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func cancelInteraction() {
        targets.removeAll()
        activeID = nil
        showTask?.cancel()
        showTask = nil
        coolTask?.cancel()
        coolTask = nil
        hidePanel()
        removeEventMonitor()
        isWarm = false
    }
}

private struct HoverTooltipCoordinatorKey: EnvironmentKey {
    static let defaultValue: HoverTooltipCoordinator? = nil
}

private extension EnvironmentValues {
    var hoverTooltipCoordinator: HoverTooltipCoordinator? {
        get { self[HoverTooltipCoordinatorKey.self] }
        set { self[HoverTooltipCoordinatorKey.self] = newValue }
    }
}

private struct HoverTooltipModifier: ViewModifier {
    @Environment(\.hoverTooltipCoordinator) private var coordinator
    let text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let coordinator {
            content
                .overlay {
                    HoverTooltipTrackingRegion(text: text, coordinator: coordinator)
                }
                .accessibilityHint(text)
        } else {
            content.help(text)
        }
    }
}

extension View {
    /// Shares one tooltip coordinator with this view hierarchy.
    func coordinatedHoverTooltips(using coordinator: HoverTooltipCoordinator) -> some View {
        environment(\.hoverTooltipCoordinator, coordinator)
    }

    /// Shows help text with the workspace window's shared tooltip timing.
    func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}

private struct HoverTooltipTrackingRegion: NSViewRepresentable {
    let text: String
    let coordinator: HoverTooltipCoordinator

    func makeNSView(context: Context) -> HoverTooltipTrackingView {
        let view = HoverTooltipTrackingView()
        view.text = text
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ view: HoverTooltipTrackingView, context: Context) {
        if view.isInside, view.coordinator !== coordinator {
            view.coordinator?.exited(id: view.id)
            coordinator.entered(id: view.id, view: view, text: text)
        }
        view.text = text
        view.coordinator = coordinator
        coordinator.updated(id: view.id, view: view, text: text)
    }

    static func dismantleNSView(_ view: HoverTooltipTrackingView, coordinator: ()) {
        if view.isInside { view.coordinator?.exited(id: view.id) }
    }
}

private final class HoverTooltipTrackingView: NSView {
    let id = UUID()
    weak var coordinator: HoverTooltipCoordinator?
    var text = ""
    fileprivate var isInside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        coordinator?.entered(id: id, view: self, text: text)
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        coordinator?.exited(id: id)
    }
}

/// A nonactivating, mouse-transparent panel styled like an AppKit tooltip.
@MainActor
private final class HoverTooltipPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]

        effect.material = .toolTip
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 4
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        label.font = .toolTipsFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -3),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
        contentView = effect
    }

    func show(text: String, near point: NSPoint, in parent: NSWindow?) {
        update(text: text)
        let size = effect.fittingSize
        setContentSize(size)

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? parent?.screen
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: point.x + 10, y: point.y - size.height - 16)
        if origin.x + size.width > visible.maxX { origin.x = visible.maxX - size.width }
        origin.x = max(origin.x, visible.minX)
        if origin.y < visible.minY { origin.y = min(point.y + 18, visible.maxY - size.height) }
        setFrameOrigin(origin)

        if let parent, self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func update(text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        effect.needsLayout = true
        effect.layoutSubtreeIfNeeded()
        if isVisible { setContentSize(effect.fittingSize) }
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
