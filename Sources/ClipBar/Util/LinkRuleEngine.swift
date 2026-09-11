import AppKit
import Foundation

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
        NSWorkspace.shared.open(url)
        guard let browserURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }

        // Page render buffer for WeChat articles (~2-3s on a normal network),
        // then a click into the page body moves focus off the address bar
        // (new tabs start with the URL bar focused — ⌘A would grab the URL),
        // and finally ⌘A ⌘C ⌘W. Each step aborts if the browser isn't
        // frontmost anymore — a synthetic ⌘W into another app would close
        // someone else's tab.
        let loadWait: TimeInterval = 3.0
        let cmd: CGEventFlags = [.maskCommand]
        postClick(CGPoint(x: 960, y: 540), at: loadWait, frontmost: browserURL)
        postCombo(0, flags: cmd, at: loadWait + 0.4, frontmost: browserURL)        // ⌘A select all
        postCombo(8, flags: cmd, at: loadWait + 0.8, frontmost: browserURL)        // ⌘C copy
        postCombo(13, flags: cmd, at: loadWait + 1.2, frontmost: browserURL)       // ⌘W close tab
    }

    private static func postClick(_ point: CGPoint, at delay: TimeInterval, frontmost appURL: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard NSWorkspace.shared.frontmostApplication?.bundleURL == appURL else { return }
            let src = CGEventSource(stateID: .combinedSessionState)
            guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private static func postCombo(_ keyCode: CGKeyCode, flags: CGEventFlags,
                                  at delay: TimeInterval, frontmost appURL: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard NSWorkspace.shared.frontmostApplication?.bundleURL == appURL else {
                NSLog("ClipBar: grab keystroke skipped — browser left frontmost")
                return
            }
            let src = CGEventSource(stateID: .combinedSessionState)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
            down.flags = flags
            down.post(tap: .cghidEventTap)
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}
