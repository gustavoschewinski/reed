import Foundation

/// The narrow slice of `UserDefaults` that `Settings` and `SystemAudio`'s
/// crash-safety persistence (Item 1) actually need.
///
/// Real callers use the real `UserDefaults` (conformance below); tests
/// substitute an in-memory fake instead (Item 6) — a plain suite-named
/// `UserDefaults` looks isolated but isn't, fully: cfprefsd persists
/// domains asynchronously and out-of-process, so even a careful same-
/// process teardown (`removePersistentDomain` + `synchronize()` + deleting
/// the file by hand) can still race it and leave a stray plist behind in
/// the user's real `~/Library/Preferences` — observed directly while
/// building this fix, intermittently, even with that teardown in place.
/// A fake that never touches the real preferences system at all has no
/// race to lose.
protocol UserDefaultsLike: AnyObject {
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
    func object(forKey defaultName: String) -> Any?
    func integer(forKey defaultName: String) -> Int
    func float(forKey defaultName: String) -> Float
    func bool(forKey defaultName: String) -> Bool
    func register(defaults registrationDictionary: [String: Any])
    @discardableResult
    func synchronize() -> Bool
}

extension UserDefaults: UserDefaultsLike {}
