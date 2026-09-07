import AppKit
import SwiftUI

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AppController.shared.handleBarCommandShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class BarWindowController: NSWindowController, NSWindowDelegate {

    /// Authoritative answer to "is the bar up?". `NSWindow.isVisible` used to serve
    /// that role and caused issue #64 — a missed `orderOut` (dropped animation
    /// completion handler) left the panel permanently "visible", so every hotkey
    /// press routed to `hide()` and the bar never came back until relaunch.
    /// Show/hide are now instant: no animation, no completion handlers at all.
    private enum Phase: Equatable {
        case hidden
        case shown
    }

    private var phase: Phase = .hidden

    /// True while the bar is up. `AppController.toggleBar` asks this instead of
    /// `window.isVisible`.
    var isPresented: Bool { phase == .shown }

    private var outsideClickMonitor: Any?
    /// Lower-half auto-dismiss: y below this boundary means the user moved on.
    /// nil = feature off. Computed at show time for the panel's screen.
    private var lowerDismissBoundary: CGFloat?
    /// Armed only when the cursor is above the boundary at summon time, so a
    /// ⌘⇧V summon with the mouse already low does not instantly self-dismiss.
    private var lowerDismissArmed = false
    private var lowerHalfTimer: Timer?

    /// Watches for real clicks in other apps while the bar is up. Events for our own
    /// panels never reach a global monitor, so clicks inside the bar (cards, chrome,
    /// blank areas) cannot fire it; only a mouse-down on some other app's window or
    /// the desktop does, and only when it lands outside the panel frame.
    private func startOutsideClickMonitor() {
        guard Settings.shared.hideOnClickOutside, outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.window, panel.isVisible else { return }
            let location = NSEvent.mouseLocation

            guard !panel.frame.contains(location) else { return }
            guard !Self.isOverOwnWindow(at: location) else { return }
            AppController.shared.hideBar()
        }
    }

    /// True when `location` lands on a visible window of this app other than the
    /// bar itself — menu popups, the settings window, previews. NSMenu tracking
    /// consumes item clicks before normal dispatch, so clicks on our own menus
    /// still arrive through this global monitor; without this check, selecting
    /// any menu item dismissed the bar mid-click. Scans NSApp.windows (in-memory,
    /// microseconds) — a CGWindowList round-trip here added visible delay to
    /// every dismissal.
    private nonisolated static func isOverOwnWindow(at location: NSPoint) -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.frame.contains(location)
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private static var contentBottomExtension: CGFloat {
        if #available(macOS 26.0, *) { return Theme.cornerRadius }
        return 0
    }

    init() {
        let panel = BarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        // Without this a stray close() would deallocate the panel and leave `window`
        // nil, which is another way to never show the bar again.
        panel.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: BarView())
        if #available(macOS 26.0, *) {
            let glassContent = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            glassContent.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: glassContent.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glassContent.trailingAnchor),
                content.topAnchor.constraint(equalTo: glassContent.topAnchor),
                content.bottomAnchor.constraint(equalTo: glassContent.bottomAnchor,
                                                constant: -Theme.cornerRadius),
            ])

            let glass = NSGlassEffectView()
            glass.contentView = glassContent
            glass.cornerRadius = Theme.cornerRadius
            glass.tintColor = NSColor.black.withAlphaComponent(0.12)
            glass.style = .regular
            panel.contentView = glass
            panel.hasShadow = false
        } else {
            panel.contentView = content
        }
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// The screen the bar should slide up from: the one under the pointer.
    ///
    /// `NSRect.contains` excludes a rect's max edges, so a pointer sitting exactly on
    /// the boundary between two displays matches none of them. Displays of differing
    /// sizes also leave unreachable gaps in the global coordinate space. Both cases
    /// used to fall through to `NSScreen.main`, which is the screen holding the *key
    /// window* — not the one the pointer is on — so the bar surfaced on the wrong
    /// display. Hit-test with `NSMouseInRect`, then fall back to the nearest screen.
    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return hit
        }
        return NSScreen.screens.min { a, b in
            distanceSquared(from: a.frame, to: mouse) < distanceSquared(from: b.frame, to: mouse)
        }
    }

    private static func distanceSquared(from rect: NSRect, to point: NSPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    func show() {
        guard let panel = window else { return }
        guard let screen = Self.targetScreen() else { return }
        panel.level = Settings.shared.hideOnClickOutside ? .modalPanel : .floating
        let vf = screen.visibleFrame
        let height = min(CGFloat(Settings.shared.barHeight), vf.height)
        let fromTop = Settings.shared.showFromTop
        let onScreen = NSRect(x: vf.minX,
                              y: fromTop ? vf.maxY - height : vf.minY,
                              width: vf.width, height: height)

        // No slide animation: the window parks at its final frame and the content is
        // placed at its final offset *before* ordering front, so summon is instant.
        // (The content still moves inside the window rather than the window frame
        // itself: on multi-display setups a staging rect outside the target display
        // can land on a neighbouring screen.)
        panel.setFrame(onScreen, display: false)
        guard let content = panel.contentView else { return }
        let bottomExtension = Self.contentBottomExtension
        let contentHeight = height + bottomExtension
        content.autoresizingMask = []
        content.frame = NSRect(x: 0, y: fromTop ? 0 : -bottomExtension,
                               width: onScreen.width, height: contentHeight)

        phase = .shown
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitor()

        // Arm lower-half auto-dismiss: the boundary is the panel screen's vertical
        // midline (never above the panel itself), and only if the cursor is not
        // already below it at summon time.
        if Settings.shared.lowerHalfDismiss {
            lowerDismissBoundary = max(vf.midY, onScreen.minY)
            lowerDismissArmed = NSEvent.mouseLocation.y >= lowerDismissBoundary!
            startLowerHalfWatch()
        } else {
            lowerDismissBoundary = nil
            stopLowerHalfWatch()
        }
    }

    /// Polls the cursor while the bar is up: entering the lower half dismisses.
    /// Polling instead of a global mouseMoved monitor because AppKit only produces
    /// mouseMoved NSEvents for windows that accept them — other apps' windows
    /// mostly don't, so the monitor would never fire. 0.1s = imperceptible.
    private func startLowerHalfWatch() {
        lowerHalfTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let boundary = self.lowerDismissBoundary,
                      self.window?.isVisible == true else { return }
                let loc = NSEvent.mouseLocation
                if loc.y < boundary {
                    // Downward crossing of the midline = "I moved on".
                    if self.lowerDismissArmed {
                        self.lowerDismissArmed = false
                        AppController.shared.hideBar()
                    }
                } else {
                    // Upward crossing re-arms, so the dismissal works no matter
                    // where the cursor was when the bar was summoned.
                    self.lowerDismissArmed = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lowerHalfTimer = timer
    }

    private func stopLowerHalfWatch() {
        lowerHalfTimer?.invalidate()
        lowerHalfTimer = nil
    }

    func hide() {
        guard let panel = window else { return }
        guard isPresented else { return }

        stopOutsideClickMonitor()
        stopLowerHalfWatch()
        phase = .hidden
        panel.orderOut(nil)
        // Drop decoded images shortly after dismissal so idle footprint returns to
        // the framework baseline regardless of how many images were browsed. The
        // delay keeps a quick re-summon on warm cache.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            ClipboardStore.shared.purgeImageCache()
        }
    }

    /// Drops the bar immediately with no animation. Used after sleep or a display
    /// change, where an in-flight transition can be left stranded on a screen that
    /// no longer exists.
    func forceHide() {
        stopLowerHalfWatch()
        phase = .hidden
        stopOutsideClickMonitor()
        window?.orderOut(nil)
    }
}
