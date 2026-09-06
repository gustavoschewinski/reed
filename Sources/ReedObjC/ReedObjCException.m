#import "ReedObjCException.h"

NSString *const ReedObjCExceptionErrorDomain = @"com.reed.ObjCException";
NSString *const ReedObjCExceptionNameKey = @"ReedObjCExceptionName";

@implementation ReedObjCException

+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block
           error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            // The reason string is the diagnosis — "required condition is
            // false: format.sampleRate == inputHWFormat.sampleRate" names
            // both the check and the values that failed it. Carried through
            // verbatim so the log says what happened rather than that
            // something did.
            *error = [NSError errorWithDomain:ReedObjCExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                                         ReedObjCExceptionNameKey : exception.name ?: @"NSException",
                                         NSLocalizedFailureReasonErrorKey : exception.reason ?: @"",
                                     }];
        }
        return NO;
    }
}

@end
