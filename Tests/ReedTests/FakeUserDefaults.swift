import Foundation
@testable import Reed

/// In-memory `UserDefaultsLike` (Item 6) — see that protocol's doc comment
/// for why this replaced a real, suite-named `UserDefaults` everywhere in
/// this test target. Nothing here ever touches disk or the real
/// preferences system, so there is no domain to remove and no file that
/// could possibly be left behind in the user's real
/// `~/Library/Preferences` — not "carefully cleaned up," just never
/// created.
final class FakeUserDefaults: UserDefaultsLike {
    private var storage: [String: Any] = [:]

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }

    func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    func integer(forKey defaultName: String) -> Int {
        (storage[defaultName] as? Int) ?? 0
    }

    func float(forKey defaultName: String) -> Float {
        (storage[defaultName] as? Float) ?? 0
    }

    func bool(forKey defaultName: String) -> Bool {
        (storage[defaultName] as? Bool) ?? false
    }

    func register(defaults registrationDictionary: [String: Any]) {
        for (key, value) in registrationDictionary where storage[key] == nil {
            storage[key] = value
        }
    }

    @discardableResult
    func synchronize() -> Bool { true }
}
