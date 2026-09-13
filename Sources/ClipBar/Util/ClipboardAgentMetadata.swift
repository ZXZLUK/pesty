import Foundation

struct ClipboardAgentMetadata: Codable, Equatable {
    static let mimeType = "application/x-clipbar-agent+json"
    static let webCustomFormatMapType = "org.w3.web-custom-format.map"
    static let htmlCommentPrefix = "<!--CLIPBAR:v1;"
    static let chromiumSourceURLType = "org.chromium.source-url"
    static let chromiumSourceFrameTokenType = "org.chromium.internal.source-rfh-token"

    let v: Int
    let source: String
    let kind: String
    let intent: String

    var requestsCompile: Bool {
        v == 1 && intent == "compile" && Self.isValidToken(source) && Self.isValidToken(kind)
    }

    static func decodeRoutingPayload(_ data: Data) -> ClipboardAgentMetadata? {
        guard data.count <= 4_096,
              let value = try? JSONDecoder().decode(ClipboardAgentMetadata.self, from: data),
              value.requestsCompile else { return nil }
        return value
    }

    static func mappedPasteboardType(fromWebCustomFormatMap data: Data) -> String? {
        guard data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: Any],
              let raw = map[mimeType] as? String,
              raw.count <= 128,
              raw.hasPrefix("org.w3.web-custom-format.type-") else { return nil }
        let suffix = raw.dropFirst("org.w3.web-custom-format.type-".count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return raw
    }

    static func stripLeadingMarker(from text: String) -> (text: String, metadata: ClipboardAgentMetadata?) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstRaw = parts.first else { return (text, nil) }
        let first = String(firstRaw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard first.hasPrefix("[[CLIPBAR:v1;"), first.hasSuffix("]]"), first.count <= 256,
              let metadata = parseCompactFields(String(first.dropFirst(2).dropLast(2))) else {
            return (text, nil)
        }
        return (parts.count == 2 ? String(parts[1]) : "", metadata)
    }

    static func metadataFromHTML(_ html: String) -> ClipboardAgentMetadata? {
        let prefix = html.prefix(512)
        guard let start = prefix.range(of: htmlCommentPrefix),
              let end = prefix[start.lowerBound...].range(of: "-->") else { return nil }
        let marker = String(prefix[start.lowerBound..<end.lowerBound].dropFirst(4))
        return parseCompactFields(marker)
    }

    /// Chromium exposes provenance marker types on programmatic clipboard writes, but the
    /// `org.chromium.source-url` value is not guaranteed to be readable cross-process on macOS.
    /// When the URL is readable it must be YouTube. When it is unreadable, only the exact
    /// programmatic plain-text shape from Arc/Chrome is accepted as the producer fallback.
    static func metadataFromChromiumYouTubePlainText(typeNames: Set<String>,
                                                     sourceURL: String?,
                                                     sourceBundleID: String? = nil,
                                                     sourceAppName: String? = nil) -> ClipboardAgentMetadata? {
        guard typeNames.contains(chromiumSourceURLType),
              typeNames.contains(chromiumSourceFrameTokenType),
              typeNames.contains("public.utf8-plain-text") || typeNames.contains("NSStringPboardType"),
              !typeNames.contains("public.html"),
              !typeNames.contains("public.rtf") else { return nil }

        let rawURL = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawURL.isEmpty,
           rawURL.count <= 4_096,
           let url = URL(string: rawURL),
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           let host = url.host?.lowercased() {
            guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        } else {
            // Arc may expose the source-url pasteboard type while returning an opaque or
            // non-URL value cross-process. Treat that the same as an unreadable value,
            // but only when the full Chromium programmatic-write fingerprint and browser
            // identity already passed the guards above.
            guard isSupportedChromiumBrowser(bundleID: sourceBundleID, appName: sourceAppName) else { return nil }
        }
        return ClipboardAgentMetadata(v: 1, source: "youtube", kind: "transcript", intent: "compile")
    }

    private static func isSupportedChromiumBrowser(bundleID: String?, appName: String?) -> Bool {
        let id = bundleID?.lowercased() ?? ""
        let name = appName?.lowercased() ?? ""
        return id == "company.thebrowser.browser"
            || id == "com.google.chrome"
            || id.hasPrefix("com.google.chrome.")
            || name == "arc"
            || name.hasPrefix("google chrome")
    }

    private static func parseCompactFields(_ body: String) -> ClipboardAgentMetadata? {
        let fields = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.first == "CLIPBAR:v1" else { return nil }
        var values: [String: String] = [:]
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0])
            let value = String(pair[1])
            guard ["source", "kind", "intent"].contains(key), values[key] == nil else { return nil }
            values[key] = value
        }
        guard let source = values["source"], let kind = values["kind"], let intent = values["intent"] else {
            return nil
        }
        let metadata = ClipboardAgentMetadata(v: 1, source: source, kind: kind, intent: intent)
        return metadata.requestsCompile ? metadata : nil
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
