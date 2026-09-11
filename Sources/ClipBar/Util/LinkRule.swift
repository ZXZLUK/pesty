import Foundation

/// A link-trigger rule: when a captured link's URL host matches `domain`
/// (case-insensitive suffix match, `mp.weixin.qq.com` also covers
/// `xxx.mp.weixin.qq.com`), run `action` — immediately on capture, in the
/// background; nothing else about the capture changes.
///
/// Rules are user-editable data: domains are free-form, and the script action
/// accepts inline shell code (the URL arrives as `$1`) — no external script
/// files to manage.
struct LinkRule: Codable, Equatable, Identifiable {
    let id: UUID
    var domain: String
    var action: ActionKind
    var enabled: Bool

    init(id: UUID = UUID(), domain: String, action: ActionKind, enabled: Bool = true) {
        self.id = id
        self.domain = domain
        self.action = action
        self.enabled = enabled
    }

    enum ActionKind: Codable, Equatable {
        case openInBrowser
        /// Runs via `/bin/zsh -c <code> zsh <url>`: the link is `$1`.
        case runScript(code: String)
    }
}
