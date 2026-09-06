#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Domain of the `NSError` a caught `NSException` is reported as.
extern NSString *const ReedObjCExceptionErrorDomain;

/// `userInfo` key holding the caught exception's `name`.
extern NSString *const ReedObjCExceptionNameKey;

/// The one thing Swift cannot do for itself: run a block and survive an
/// Objective-C `NSException` raised inside it.
///
/// This exists for AVFAudio. Several of its failures — `installTap` handed a
/// format whose sample rate disagrees with the input hardware's, an engine
/// prepared with no nodes, a graph it cannot configure — are reported by
/// raising, not by returning an error, and a Swift `catch` cannot see a
/// raise. Left uncaught in an app, AppKit swallows it at the top of the run
/// loop: the process keeps running while whatever was half-done stays
/// half-done, which is far worse than a plain failure.
///
/// **Keep the block minimal.** Unwinding an Objective-C exception through a
/// Swift frame skips that frame's ARC cleanup, so a block that does Swift
/// work before the raising call may leak what it was holding. One
/// framework call per block, with everything it needs computed beforehand,
/// keeps that window empty. A leak on a path that used to break the app
/// until relaunch is a good trade; a leak on a path doing real work is not.
@interface ReedObjCException : NSObject

/// Runs `block`. Returns `YES` if it completed, or `NO` having set `error`
/// if it raised. Imported into Swift as a throwing function.
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block
           error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
