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
}
