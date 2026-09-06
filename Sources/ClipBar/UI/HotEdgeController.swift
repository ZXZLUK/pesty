import AppKit

/// Invisible strips pinned to the top edge of every screen: touching the topmost
/// line summons the bar instantly. The strips sit above the menu bar window
/// level, so the absolute top line fires even while over the menu bar. There is
/// no dwell delay — the owner accepted fly-through triggers in exchange for
/// zero latency; one-shot arming still keeps the bar from flapping while the
/// cursor parks on the edge.
@MainActor
final class HotEdgeController {
    static let shared = HotEdgeController()

    private static let stripThickness: CGFloat = 4

    private var strips: [NSPanel] = []
    /// One-shot arming: the edge cannot re-trigger until the cursor leaves it, so
    /// parking at the top never flaps the bar while it is already up, and a
    /// dismiss with the cursor still parked does not instantly re-show.
    private var armed = true

    func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { teardown() }
    }

    /// Re-measures the strips after display geometry changes.
    func rebuild() {
        teardown()
        install()
    }

    private func install() {
        guard strips.isEmpty, Settings.shared.hotEdgeEnabled else { return }
        for screen in NSScreen.screens {
            let frame = NSRect(x: screen.frame.minX,
                               y: screen.frame.maxY - Self.stripThickness,
                               width: screen.frame.width,
                               height: Self.stripThickness)
            let strip = HotEdgePanel(frame: frame)
            strip.orderFrontRegardless()
            strips.append(strip)
        }
    }

    private func teardown() {
        for strip in strips { strip.orderOut(nil) }
        strips.removeAll()
        armed = true
    }

    fileprivate func handleEnter() {
        guard armed, !AppController.shared.barIsPresented else { return }
        armed = false
        AppController.shared.showBar()
    }

    fileprivate func handleExit() {
        armed = true
    }
}

/// Borderless, non-activating, fully transparent window whose only job is to
/// receive tracking events along one screen's top edge. It swallows clicks on
/// the outermost 4pt strip — the price of a hover trigger without an event tap.
private final class HotEdgePanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = HotEdgeView(frame: NSRect(origin: .zero, size: frame.size))
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HotEdgeView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        HotEdgeController.shared.handleEnter()
    }

    override func mouseExited(with event: NSEvent) {
        HotEdgeController.shared.handleExit()
    }
}
