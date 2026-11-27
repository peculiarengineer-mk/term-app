#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes `block` inside an Objective-C `@try/@catch` block and returns any caught `NSException`.
FOUNDATION_EXPORT NSException * _Nullable TermStoreCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
