import Foundation

/// A link-trigger rule: when a captured link's URL host matches `domain`
/// (case-insensitive suffix match, `mp.weixin.qq.com` also covers
/// `xxx.mp.weixin.qq.com`), run `action` — immediately on capture, in the
/// background; nothing else about the capture changes.
///
/// The point of this type is extensibility: rules are user-data, actions are
/// pluggable (`ActionKind`), and the settings UI edits them freely. Nothing is
/// hard-wired to WeChat.
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
        case runScript(path: String)
    }
}
