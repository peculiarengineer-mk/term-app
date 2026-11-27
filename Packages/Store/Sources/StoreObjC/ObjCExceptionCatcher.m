#import "ObjCExceptionCatcher.h"

NSException * _Nullable TermStoreCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        if (block != nil) {
            block();
        }
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
