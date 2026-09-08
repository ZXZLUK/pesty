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
        switch rule.action {
        case .openInBrowser:
            NSWorkspace.shared.open(url)
        case .runScript(let path):
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expanded)
                || FileManager.default.fileExists(atPath: expanded) else {
                NSLog("ClipBar: link-rule script not found at \(path)")
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: expanded)
            task.arguments = [url.absoluteString]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                NSLog("ClipBar: link-rule script failed to launch (\(path)): \(error)")
            }
        }
    }
}
