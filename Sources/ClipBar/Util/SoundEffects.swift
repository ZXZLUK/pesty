import AppKit

/// Capture/paste feedback sounds. Capture feedback is deliberately quiet —
/// it fires on every real copy, so it must stay out of the way.
@MainActor
enum SoundEffects {
    /// Built-in system sounds offered in Settings, ordered subtest-first.
    static let captureChoices: [(name: String, labelEN: String, labelZH: String)] = [
        ("", "Off", "关闭"),
        ("Tink", "Tink (轻点)", "Tink（轻点）"),
        ("Pop", "Pop (啵)", "Pop（啵）"),
        ("Ping", "Ping (叮)", "Ping（叮）"),
        ("Glass", "Glass (玻璃)", "Glass（玻璃）"),
        ("Bubbles", "Bubbles (气泡)", "Bubbles（气泡）"),
        ("Submarine", "Submarine (低鸣)", "Submarine（低鸣）"),
    ]

    static func playCapture() {
        let name = Settings.shared.captureSound
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.18
        sound.play()
    }

    /// Settings preview uses full-ish volume so the choice is audible.
    static func preview(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.6
        sound.play()
    }
}
