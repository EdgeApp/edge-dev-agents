#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Hard cap on XCUITest's app-quiescence wait (the wait XCTest runs before and
// after every synthesized event). Modeled on WebDriverAgent's
// XCUIApplicationProcess+FBQuiescence: the private wait methods are swizzled
// to call the original under a bounded _XCTSetApplicationStateTimeout.
@interface EdgeQuiescence : NSObject

// Seconds. Default 1. 0 skips the quiescence wait entirely.
@property (class, nonatomic) NSTimeInterval cap;

// Label of the flow step currently running, printed with each cap hit.
@property (class, nonatomic, copy) NSString *currentStep;

// Number of waits that ran into the cap during this process.
@property (class, nonatomic, readonly) NSInteger capHits;

// Swizzles the wait methods. Safe to call more than once.
+ (void)install;

@end

NS_ASSUME_NONNULL_END
