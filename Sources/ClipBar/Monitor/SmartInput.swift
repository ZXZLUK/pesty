import AppKit
import ApplicationServices

/// Smart-paste focus: after activating the target app, make sure a text input —
/// not whatever else happened to hold focus — receives the paste. Uses the
/// Accessibility API (the same grant direct paste already needs):
///   1. If the app's focused element is already a text field/area, done.
///   2. Otherwise search the focused window for text elements and focus the
///      best candidate (bottom-most wins — prompt boxes live at the bottom).
/// Falls back silently: when nothing is found, paste behaves exactly as
/// before (⌘V into whatever the app focuses itself).
///
/// macOS 26.5 SDK note: AXUIElement{Copy,Set}AttributeValue lost the trailing
/// error-pointer parameter (3-arg signatures), and the role constants are
/// #define macros invisible to Swift — use string literals ("AXTextArea").
@MainActor
enum SmartInput {

    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField"]

    static func focusInputBox(ofApp app: NSRunningApplication) -> Bool {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        // 1. Focus already on a text element — nothing to do.
        if let focused = element(appEl, kAXFocusedUIElementAttribute), isTextElement(focused) {
            return true
        }

        // 2. Search the focused window for a text input candidate.
        guard let window = element(appEl, kAXFocusedWindowAttribute)
            ?? element(appEl, kAXMainWindowAttribute) else { return false }
        var candidates: [AXUIElement] = []
        var visited = 0
        collectTextElements(window, depth: 0, visited: &visited, into: &candidates)
        guard let best = pick(candidates) else { return false }

        return AXUIElementSetAttributeValue(best, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    // MARK: - AX helpers

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let anyValue = value else { return nil }
        return unsafeDowncast(anyValue, to: AXUIElement.self)
    }

    private static func role(_ el: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isTextElement(_ el: AXUIElement) -> Bool {
        guard let r = role(el) else { return false }
        return textRoles.contains(r)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let p = position as? NSValue, let s = size as? NSValue else { return nil }
        return CGRect(origin: p.pointValue, size: s.sizeValue)
    }

    private static func collectTextElements(_ el: AXUIElement, depth: Int,
                                            visited: inout Int, into out: inout [AXUIElement]) {
        guard depth <= 9, visited < 400 else { return }
        visited += 1
        if isTextElement(el), let f = frame(el), f.width > 40, f.height > 12 {
            out.append(el)
        }
        for child in children(el) {
            collectTextElements(child, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    /// Prompt boxes sit at the bottom of a window: prefer the lowest text
    /// element; larger area breaks ties (the big input beats a stray search box).
    private static func pick(_ candidates: [AXUIElement]) -> AXUIElement? {
        var best: (el: AXUIElement, score: CGFloat)?
        for c in candidates {
            guard let f = frame(c) else { continue }
            let score = f.maxY * 1000 + min(f.width * f.height, 1_000_000)
            if best == nil || score > best!.score { best = (c, score) }
        }
        return best?.el
    }
}
