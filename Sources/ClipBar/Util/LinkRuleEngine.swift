import AppKit
import Foundation

/// Appends to the grab debug trace (/tmp/clipbar_grab_debug.log).
fileprivate func grabLog(_ message: String) {
    let line = "\(Date()) grab: \(message)\n"
    let path = "/tmp/clipbar_grab_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Evaluates link-trigger rules against newly captured links and runs their
/// actions. Everything happens off the capture path: rules are checked on the
/// main actor right after `addCaptured`, so a slow action (script launch) can
/// never stall monitoring.
@MainActor
enum LinkRuleEngine {

    /// Runs after `ClipboardStore.addCaptured`: fires every enabled rule whose
    /// domain matches the item's URL host.
    static func evaluate(_ item: ClipItem, in store: ClipboardStore) {
        guard item.type == .link else { return }
        guard let raw = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let host = url.host?.lowercased() else { return }
        for rule in Settings.shared.linkRules where rule.enabled {
            guard matches(host: host, domain: rule.domain) else { continue }
            run(rule, url: url)
        }
    }

    /// Suffix match: `mp.weixin.qq.com` covers itself and any subdomain.
    private static func matches(host: String, domain: String) -> Bool {
        let d = domain.lowercased()
        return host == d || host.hasSuffix("." + d)
    }

    private static func run(_ rule: LinkRule, url: URL) {
        NSLog("ClipBar: link rule fired (%@) -> %@", rule.domain, url.absoluteString)
        // Env-gated debug trace: CLIPBAR_RULE_DEBUG=1 appends every fire to a
        // temp file, so trigger semantics can be verified headlessly.
        if ProcessInfo.processInfo.environment["CLIPBAR_RULE_DEBUG"] == "1" {
            let line = "\(Date()) fired [\(rule.domain)] \(url.absoluteString)\n"
            let path = "/tmp/clipbar_rule_fires.log"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        switch rule.action {
        case .openInBrowser:
            NSWorkspace.shared.open(url)
        case .openCopyAllClose:
            openAndGrab(url)
        case .runScript(let code):
            // Inline user code: the link arrives as $1. zsh -c never blocks
            // capture (launched async) and its output is discarded.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-c", code, "zsh", url.absoluteString]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                NSLog("ClipBar: link-rule script failed: \(error)")
            }
        }
    }

    /// Open → wait for render → ⌘A ⌘C ⌘W inside the browser. Every keystroke
    /// is gated on the DEFAULT BROWSER still being frontmost: a synthetic ⌘W
    /// into an unknown app would close someone else's tab.
    private static func openAndGrab(_ url: URL) {
        grabLog("open \(url.absoluteString)")
        NSWorkspace.shared.open(url)
        guard let browserURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            grabLog("no app resolves for this URL")
            return
        }
        grabLog("browser = \(browserURL.path)")

        // Page render buffer for WeChat articles (~2-3s on a normal network),
        // then the grab keys 0.1s apart. Steps are driven by a repeating
        // 0.05s Timer instead of DispatchQueue.main.asyncAfter: asyncAfter
        // blocks scheduled from the capture flow proved unreliable in this
        // app (they often never ran), while main-runloop Timers demonstrably
        // fire. Every step aborts if the browser isn't frontmost anymore —
        // a synthetic ⌘W into another app would close someone else's tab.
        let loadWait: TimeInterval = 2.5
        let cmd: CGEventFlags = [.maskCommand]
        let start = Date()
        let keys: [(key: CGKeyCode, at: TimeInterval, name: String)] = [
            (0, loadWait, "⌘A"),
            (8, loadWait + 0.1, "⌘C"),
            (13, loadWait + 0.2, "⌘W"),
        ]
        let appURL = browserURL
        var fired = 0
        let stepper = Timer(timeInterval: 0.05, repeats: true) { t in
            MainActor.assumeIsolated {
                guard fired < keys.count else { t.invalidate(); return }
                // 前台已不是浏览器 = 用户切走了 → 放弃剩余序列
                guard NSWorkspace.shared.frontmostApplication?.bundleURL == appURL else {
                    grabLog("abort: frontmost left at step \(fired)")
                    t.invalidate()
                    return
                }
                let now = Date().timeIntervalSince(start)
                guard now >= keys[fired].at else { return }
                postCombo(keys[fired].key, flags: [.maskCommand])
                grabLog("sent \(keys[fired].name)")
                fired += 1
            }
        }
        RunLoop.main.add(stepper, forMode: .common)
    }

    private static func postCombo(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        down.post(tap: .cghidEventTap)
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }
}
