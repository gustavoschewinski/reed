import Foundation
import ReedObjC

/// Swift's face on `ReedObjCException` — see that header for why catching
/// an Objective-C exception is necessary at all, and for the rule about
/// keeping the block minimal.
///
/// Foundation-only, no AppKit and nothing under `UI/`, so `Core/` may call
/// it under the same layering rule `DebugLog` is held to.
enum ObjCException {
    /// An `NSException` that was raised and caught, flattened to the two
    /// things worth knowing about it.
    struct Raised: Error, CustomStringConvertible, Equatable {
        let name: String
        let reason: String

        var description: String {
            reason.isEmpty ? name : "\(name): \(reason)"
        }
    }

    /// Runs `body`, converting any Objective-C exception it raises into a
    /// thrown `Raised`. A Swift error thrown inside `body` is *not* handled
    /// here — the block is non-throwing by signature, so a caller that needs
    /// to run a throwing call inside it must catch and carry the error out
    /// itself.
    static func catching(_ body: () -> Void) throws {
        do {
            try ReedObjCException.catching(body)
        } catch let error as NSError {
            throw Raised(
                name: error.userInfo[ReedObjCExceptionNameKey] as? String ?? "NSException",
                reason: error.localizedFailureReason ?? ""
            )
        }
    }
}
