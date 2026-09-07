import AppKit

@MainActor
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]
    private static let cacheLimit = 128

    static func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID else { return generic }
        if let cached = cache[bundleID] { return cached }
        var image = generic
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[bundleID] = image
        return image
    }

    static let generic: NSImage =
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        ?? NSImage()
}
