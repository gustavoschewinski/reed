import AppKit

enum Cues {
    private static func play(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "aiff"),
              let sound = NSSound(contentsOf: url, byReference: true)
        else { return }
        sound.volume = 0.35
        sound.play()
    }

    static func start() { play("start") }
    static func stop() { play("stop") }
    static func cancel() { play("cancel") }
}
