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
    /// 0.2s dwell: grazing the top band while moving elsewhere must not
    /// summon; resting momentarily is intentional. (Owner felt zero-dwell
    /// misfires when reaching for UI near the top edge; tunable constant.)
    private static let dwellTime: TimeInterval = 0.2

    private var pollTimer: Timer?
    private var dwellTimer: Timer?
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
            if armed {
                // Just entered the zone: start the dwell window. The summon
                // only fires if the cursor is STILL in the zone when it
                // expires — grazing through cancels via tick's else-branch.
                armed = false
                let timer = Timer(timeInterval: Self.dwellTime, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fire() }
                }
                RunLoop.main.add(timer, forMode: .common)
                dwellTimer = timer
            }
            // Already dwelling: let the dwell timer decide.
        } else if dwellTimer != nil {
            // Left the zone before the dwell expired — grazing. Cancel.
            dwellTimer?.invalidate()
            dwellTimer = nil
        }
        if !inZone {
            // Left the band — re-arm so the next intentional entry triggers.
            armed = true
            dwellTimer = nil
        }
    }

    private func fire() {
        guard !(AppController.shared.barIsPresented ?? false) else { return }
        AppController.shared.showBar()
    }
}
