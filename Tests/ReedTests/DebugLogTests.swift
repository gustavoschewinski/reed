import Foundation
import Testing
@testable import Reed

/// `swift test` must never create `~/Library/Logs/Reed/reed-debug.log` —
/// `DebugLog` is gated on `REED_DEBUG_LOG=1`, which the test environment
/// does not set. This asserts that gate holds rather than just trusting it:
/// it snapshots whatever's on disk before calling `DebugLog.log`, then
/// checks nothing changed, so it's safe to run on a machine where the app
/// was previously run with logging enabled (a real log file already
/// there) without deleting that file as a side effect of testing.
@Test func debugLogIsANoOpWhenTheEnvironmentVariableIsUnset() throws {
    guard ProcessInfo.processInfo.environment["REED_DEBUG_LOG"] != "1" else {
        // This test's premise doesn't hold in an environment that has
        // deliberately opted into logging; nothing to assert here.
        return
    }

    let path = NSHomeDirectory() + "/Library/Logs/Reed/reed-debug.log"
    let existedBefore = FileManager.default.fileExists(atPath: path)
    let sizeBefore: UInt64? = existedBefore
        ? (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
        : nil

    for i in 0..<5 {
        DebugLog.log("swift test must never produce this line (\(i))")
    }

    let existedAfter = FileManager.default.fileExists(atPath: path)
    #expect(existedBefore == existedAfter)
    if existedAfter {
        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
        #expect(sizeBefore == sizeAfter)
    }
}
