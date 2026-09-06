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

    /// Where the bar is in its show/hide cycle.
    ///
    /// This is the authoritative answer to "is the bar up?". `NSWindow.isVisible` used
    /// to serve that role, but it only returns to false inside an animation completion
    /// handler, and AppKit drops those handlers when a later animation supersedes them
    /// on the same property. One missed `orderOut` left the panel permanently
    /// "visible", so every hotkey press routed to `hide()` and the bar never came back
    /// until the app was relaunched. That is issue #64.
    private enum Phase: Equatable {
        case hidden
        case showing(Int)
        case shown
        case hiding(Int)
    }

    private var phase: Phase = .hidden
    private var epoch = 0
    /// Direction the bar most recently slid in from. hide() reuses it so a mid-flight
    /// settings change cannot make the exit slide the wrong way through the panel.
    private var dockedFromTop = false
    /// Global mouse-down watcher installed while the bar is up. Dismissal is defined
    /// as an actual click landing outside the panel — never as "the panel lost key":
    /// agent-style frontmost apps re-assert focus on their own timers, and treating
    /// that as an outside click made the bar vanish while the user was still moving
    /// the mouse toward it.

    /// True while the bar is up or on its way up. `AppController.toggleBar` asks this
    /// instead of `window.isVisible`.
    var isPresented: Bool {
        switch phase {
        case .showing, .shown: return true
        case .hidden, .hiding: return false
        }
    }

    /// Short as possible while still reading as a slide, not a flash.
    private static let showDuration: TimeInterval = 0.12
    private static let hideDuration: TimeInterval = 0.12

    private var outsideClickMonitor: Any?

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

    /// True when `location` lands on an on-screen window owned by this app other than
    /// the bar itself — menu popups, the settings window, previews. NSMenu tracking
    /// consumes item clicks before normal dispatch, so clicks on our own menus still
    /// arrive through this global monitor; without this check, selecting any menu
    /// item (Settings…, Pin, context menus) dismissed the bar mid-click.
    private nonisolated static func isOverOwnWindow(at location: NSPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        let pid = ProcessInfo.processInfo.processIdentifier
        // CGWindow bounds are top-left origin; NSEvent.mouseLocation is bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: location.x, y: primaryHeight - location.y)
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if frame.contains(point) { return true }
        }
        return false
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

    /// Bumps the transition counter so any completion still in flight becomes stale.
    private func beginTransition() -> Int {
        epoch &+= 1
        return epoch
    }

    /// Runs `body` exactly once for the transition identified by `token`, and never for
    /// a transition that has already been superseded.
    ///
    /// Both the animation completion handler and a backstop timer call through here.
    /// The timer is what actually guarantees progress - AppKit drops completion handlers
    /// when a later animation replaces them, and relying on one to run was the original
    /// bug. Bumping `epoch` on settle makes the second caller for the same token a no-op.
    private func settle(_ token: Int, _ body: () -> Void) {
        guard epoch == token else { return }
        epoch &+= 1
        body()
    }

    func show() {
        guard let panel = window else { return }
        guard let screen = Self.targetScreen() else { return }
        panel.level = Settings.shared.hideOnClickOutside ? .modalPanel : .floating
        let vf = screen.visibleFrame
        let height = min(CGFloat(Settings.shared.barHeight), vf.height)
        let fromTop = Settings.shared.showFromTop
        dockedFromTop = fromTop
        let onScreen = NSRect(x: vf.minX,
                              y: fromTop ? vf.maxY - height : vf.minY,
                              width: vf.width, height: height)

        // The panel stays parked at its final frame and the content slides in *inside*
        // it (up from the bottom edge, or down from the top edge). Animating the window
        // frame itself is not safe on multi-display setups: the old staging rect
        // (vf.minY - height) is only genuinely off-screen when nothing sits below the
        // target display. With displays stacked vertically it lands on the neighbouring
        // screen, so the bar appeared there in full and then flew across the bezel.
        // A view clipped to the window can never escape it.
        panel.setFrame(onScreen, display: false)
        guard let content = panel.contentView else { return }
        let bottomExtension = Self.contentBottomExtension
        let contentHeight = height + bottomExtension
        content.autoresizingMask = []
        content.frame = NSRect(x: 0, y: fromTop ? contentHeight : -contentHeight,
                               width: onScreen.width, height: contentHeight)

        let token = beginTransition()
        phase = .showing(token)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.settle(token) {
                self.phase = .shown
            }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.showDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.animator().frame = NSRect(x: 0, y: fromTop ? 0 : -bottomExtension,
                                              width: onScreen.width, height: contentHeight)
        }, completionHandler: { DispatchQueue.main.async(execute: finish) })
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDuration + 0.05, execute: finish)
        startOutsideClickMonitor()
    }

    func hide() {
        guard let panel = window, let content = panel.contentView else { return }
        guard isPresented else { return }

        stopOutsideClickMonitor()
        let token = beginTransition()
        phase = .hiding(token)
        let exit = NSRect(x: 0,
                          y: dockedFromTop ? content.frame.height : -content.frame.height,
                          width: content.frame.width, height: content.frame.height)

        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.settle(token) {
                panel.orderOut(nil)
                self.phase = .hidden
            }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.hideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            content.animator().frame = exit
        }, completionHandler: { DispatchQueue.main.async(execute: finish) })
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDuration + 0.05, execute: finish)
    }

    /// Drops the bar with no animation and no completion handler to depend on.
    /// Used after sleep or a display change, where an in-flight transition can be
    /// left stranded on a screen that no longer exists.
    func forceHide() {
        _ = beginTransition()
        phase = .hidden
        stopOutsideClickMonitor()
        window?.orderOut(nil)
    }
}
