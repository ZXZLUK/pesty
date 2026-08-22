import AppKit

/// Capture/paste feedback sounds. Capture feedback is deliberately quiet —
/// it fires on every real copy, so it must stay out of the way.
@MainActor
enum SoundEffects {
    /// Built-in system sounds offered in Settings, ordered subtest-first.
    static let captureChoices: [(name: String, labelEN: String, labelZH: String)] = [
        ("", "Off", "关闭"),
        ("Tink", "Tink", "Tink（轻嗒）"),
        ("Pop", "Pop", "Pop（啵）"),
        ("Frog", "Frog", "Frog（青蛙）"),
        ("Glass", "Glass", "Glass（玻璃）"),
        ("Ping", "Ping", "Ping（叮）"),
        ("Morse", "Morse", "Morse（电码）"),
        ("Sosumi", "Sosumi", "Sosumi（经典）"),
        ("Hero", "Hero", "Hero（上扬）"),
        ("Purr", "Purr", "Purr（呼噜）"),
        ("Bottle", "Bottle", "Bottle（瓶哨）"),
        ("Blow", "Blow", "Blow（吹气）"),
        ("Bubbles", "Bubbles", "Bubbles（气泡）"),
        ("Submarine", "Submarine", "Submarine（低鸣）"),
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
