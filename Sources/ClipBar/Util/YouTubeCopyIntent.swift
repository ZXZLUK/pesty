import AppKit

/// One-shot semantic intent armed by the YouTube subtitle extension shortcut.
/// It never intercepts the keystroke; it only labels the next text capture from
/// the same browser within a short deadline.
@MainActor
final class YouTubeCopyIntent {
    static let shared = YouTubeCopyIntent()
    static let ttl: TimeInterval = 15

    private struct ArmedIntent {
        let bundleID: String?
        let appName: String?
        let expiresAt: Date
    }

    private var monitor: Any?
    private var armed: ArmedIntent?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.observe(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        armed = nil
    }

    func arm(bundleID: String?, appName: String?, now: Date = Date()) {
        guard Self.isSupportedBrowser(bundleID: bundleID, appName: appName) else {
            armed = nil
            return
        }
        armed = ArmedIntent(bundleID: bundleID, appName: appName,
                            expiresAt: now.addingTimeInterval(Self.ttl))
    }

    /// The first text capture after arming consumes the intent whether it matches
    /// or not. This prevents a later unrelated copy from inheriting stale intent.
    func consume(bundleID: String?, appName: String?, now: Date = Date()) -> ClipboardAgentMetadata? {
        guard let candidate = armed else { return nil }
        armed = nil
        guard now <= candidate.expiresAt,
              Self.sameBrowser(candidateBundleID: candidate.bundleID,
                               candidateAppName: candidate.appName,
                               captureBundleID: bundleID,
                               captureAppName: appName) else { return nil }
        return ClipboardAgentMetadata(v: 1, source: "youtube", kind: "transcript", intent: "compile")
    }

    private func observe(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.shift),
              !flags.contains(.command), !flags.contains(.option),
              event.charactersIgnoringModifiers?.lowercased() == "c" else { return }
        let app = NSWorkspace.shared.frontmostApplication
        arm(bundleID: app?.bundleIdentifier, appName: app?.localizedName)
    }

    private static func isSupportedBrowser(bundleID: String?, appName: String?) -> Bool {
        let id = bundleID?.lowercased() ?? ""
        let name = appName?.lowercased() ?? ""
        return name == "arc"
            || name.hasPrefix("google chrome")
            || id == "company.thebrowser.browser"
            || id == "com.google.chrome"
            || id.hasPrefix("com.google.chrome.")
    }

    private static func sameBrowser(candidateBundleID: String?,
                                    candidateAppName: String?,
                                    captureBundleID: String?,
                                    captureAppName: String?) -> Bool {
        if let expected = candidateBundleID, !expected.isEmpty,
           let actual = captureBundleID, !actual.isEmpty {
            return expected == actual
        }
        return candidateAppName?.caseInsensitiveCompare(captureAppName ?? "") == .orderedSame
    }
}
