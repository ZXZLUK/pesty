import AppKit

/// Top-edge summon: a lightweight cursor poll detects entry into the middle
/// of any screen's top edge (left 20% / right 30% dead) and summons the bar
/// instantly (zero dwell — owner locked 0s after testing the ladder).
///
/// Deliberately NO overlay strip: an invisible window across the top would
/// swallow clicks in that band (menu-bar clicks, window close buttons) and
/// interfere with normal UI. Polling NSEvent.mouseLocation every 0.1s is
/// imperceptible and touches nothing.
@MainActor
final class HotEdgeController {
    static let shared = HotEdgeController()

    private static let bandThickness: CGFloat = 4
    private static let leftMarginRatio: CGFloat = 0.2
    private static let rightMarginRatio: CGFloat = 0.3
    private static let pollInterval: TimeInterval = 0.1

    private var pollTimer: Timer?
    private var armed = true

    func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { teardown() }
    }

    /// Display geometry is computed live from NSScreen each tick, so display
    /// changes need no rebuild — kept for API compatibility with AppController.
    func rebuild() {}

    func install() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        armed = true
    }

    private var inZone = false

    private func tick() {
        guard Settings.shared.hotEdgeEnabled else { return }
        let loc = NSEvent.mouseLocation
        inZone = NSScreen.screens.contains { screen in
            let f = screen.frame
            return loc.x >= f.minX + f.width * Self.leftMarginRatio
                && loc.x <= f.maxX - f.width * Self.rightMarginRatio
                && loc.y >= f.maxY - Self.bandThickness
        }
        if inZone {
            guard armed, !(AppController.shared.barIsPresented ?? false) else { return }
            armed = false
            AppController.shared.showBar()
        } else {
            // Left the band — re-arm so the next entry triggers again.
            armed = true
        }
    }
}
