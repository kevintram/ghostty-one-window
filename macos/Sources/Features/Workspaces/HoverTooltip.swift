import AppKit
import SwiftUI

/// A tooltip's text, and the least width it's shown at.
struct HoverTooltip: Equatable {
    let text: String
    let minWidth: CGFloat
}

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
        var tooltip: HoverTooltip
        let order: UInt64

        init(id: UUID, view: NSView, tooltip: HoverTooltip, order: UInt64) {
            self.id = id
            self.view = view
            self.tooltip = tooltip
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

    func entered(id: UUID, view: NSView, tooltip: HoverTooltip) {
        nextOrder &+= 1
        targets[id] = Target(id: id, view: view, tooltip: tooltip, order: nextOrder)
        coolTask?.cancel()
        coolTask = nil
        installEventMonitor()
        activate(id)
    }

    func updated(id: UUID, view: NSView, tooltip: HoverTooltip) {
        guard let target = targets[id] else { return }
        target.view = view
        target.tooltip = tooltip
        if displayedID == id { panel.update(tooltip) }
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
            self.panel.show(target.tooltip, below: view)
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
    let tooltip: HoverTooltip

    @ViewBuilder
    func body(content: Content) -> some View {
        if let coordinator {
            content
                .overlay {
                    HoverTooltipTrackingRegion(tooltip: tooltip, coordinator: coordinator)
                }
                .accessibilityHint(tooltip.text)
        } else {
            content.help(tooltip.text)
        }
    }
}

extension View {
    /// Shares one tooltip coordinator with this view hierarchy.
    func coordinatedHoverTooltips(using coordinator: HoverTooltipCoordinator) -> some View {
        environment(\.hoverTooltipCoordinator, coordinator)
    }

    /// Shows help text with the workspace window's shared tooltip timing,
    /// centered below the view and at least `minWidth` wide, so even a
    /// short text like "~" stands out.
    func hoverTooltip(_ text: String, minWidth: CGFloat = 40) -> some View {
        modifier(HoverTooltipModifier(tooltip: HoverTooltip(text: text, minWidth: minWidth)))
    }
}

private struct HoverTooltipTrackingRegion: NSViewRepresentable {
    let tooltip: HoverTooltip
    let coordinator: HoverTooltipCoordinator

    func makeNSView(context: Context) -> HoverTooltipTrackingView {
        let view = HoverTooltipTrackingView(tooltip: tooltip)
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ view: HoverTooltipTrackingView, context: Context) {
        if view.isInside, view.coordinator !== coordinator {
            view.coordinator?.exited(id: view.id)
            coordinator.entered(id: view.id, view: view, tooltip: tooltip)
        }
        view.tooltip = tooltip
        view.coordinator = coordinator
        coordinator.updated(id: view.id, view: view, tooltip: tooltip)
    }

    static func dismantleNSView(_ view: HoverTooltipTrackingView, coordinator: ()) {
        if view.isInside { view.coordinator?.exited(id: view.id) }
    }
}

private final class HoverTooltipTrackingView: NSView {
    let id = UUID()
    weak var coordinator: HoverTooltipCoordinator?
    var tooltip: HoverTooltip
    fileprivate var isInside = false

    init(tooltip: HoverTooltip) {
        self.tooltip = tooltip
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        coordinator?.entered(id: id, view: self, tooltip: tooltip)
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        coordinator?.exited(id: id)
    }
}

/// A nonactivating, mouse-transparent panel styled like Safari's tab
/// tooltips: an opaque rounded card with a bold label. It's centered below
/// the view it describes, rather than placed by the pointer, so it lines up
/// with that view wherever it was entered.
@MainActor
private final class HoverTooltipPanel: NSPanel {
    private let card = HoverTooltipCard()
    private let label = NSTextField(labelWithString: "")

    /// The tooltip shown, and the view it's shown below.
    private var tooltip: HoverTooltip?
    private weak var anchor: NSView?

    private lazy var minWidthConstraint = card.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

    /// The space between the tooltip and its view.
    private static let gap: CGFloat = 5

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

        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.alignment = .natural
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 15),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -15),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            minWidthConstraint,
        ])
        contentView = card
    }

    func show(_ tooltip: HoverTooltip, below view: NSView) {
        guard let parent = view.window else { return }
        anchor = view
        update(tooltip)
        place()

        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func update(_ tooltip: HoverTooltip) {
        guard self.tooltip != tooltip else { return }
        self.tooltip = tooltip
        label.stringValue = tooltip.text
        minWidthConstraint.constant = tooltip.minWidth
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        if isVisible { place() }
    }

    func hide() {
        anchor = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    /// Sizes the tooltip to its text and centers it below its view, or
    /// above it when there's no room below, kept on the view's screen.
    private func place() {
        guard let anchor, let window = anchor.window else { return }
        let size = card.fittingSize
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - Self.gap - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        if origin.y < visible.minY { origin.y = rect.maxY + Self.gap }
        setFrame(NSRect(origin: origin, size: size), display: true)
        // The shadow follows the card's shape, so it's redrawn at its size.
        invalidateShadow()
    }
}

/// The tooltip's rounded card, matching Safari's: white with a faint edge in
/// light mode, and in dark mode a dark gray with a black edge and a faint
/// highlight just inside it. The window's shadow follows its shape.
private final class HoverTooltipCard: NSView {
    /// A view rather than a bare sublayer, whose frame changes would
    /// animate, visibly resizing it each time the tooltip does.
    private let highlight = NSView()

    private static let cornerRadius: CGFloat = 12
    private static let edgeWidth: CGFloat = 0.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Self.edgeWidth

        // Just inside the edge, and twice its width, as in Safari.
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = Self.cornerRadius - Self.edgeWidth
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.borderWidth = Self.edgeWidth * 2
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.edgeWidth),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.edgeWidth),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: Self.edgeWidth),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.edgeWidth),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 0.15, alpha: 1) : .white).cgColor
        layer?.borderColor = (dark ? NSColor(white: 0.04, alpha: 1) : NSColor(white: 0, alpha: 0.2)).cgColor
        highlight.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        highlight.isHidden = !dark
    }
}
