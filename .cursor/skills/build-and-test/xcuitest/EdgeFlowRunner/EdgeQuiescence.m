#import "EdgeQuiescence.h"

#import <dlfcn.h>
#import <objc/runtime.h>

typedef void (*SetTimeoutFn)(double);
typedef double (*GetTimeoutFn)(void);

static NSTimeInterval gCap = 1;
static NSString *gCurrentStep = @"";
static NSInteger gCapHits = 0;
static NSInteger gDepth = 0;
static NSRecursiveLock *gLock;
static SetTimeoutFn gSetTimeout;
static GetTimeoutFn gGetTimeout;

static IMP gOrigIdle;
static IMP gOrigPreEvent;
static IMP gOrigActivity;

// The application-state timeout is process-wide, so the set/wait/restore
// sequence runs under one lock. Nested waits (one wait method calling another)
// only apply the cap at the outermost level.
static void capped(NSString *name, void (^original)(void))
{
  if (gCap <= 0) return;
  [gLock lock];
  gDepth += 1;
  if (gDepth > 1) {
    original();
    gDepth -= 1;
    [gLock unlock];
    return;
  }
  double previous = gGetTimeout != NULL ? gGetTimeout() : 0;
  if (gSetTimeout != NULL) gSetTimeout(gCap);
  NSDate *start = [NSDate date];
  @try {
    original();
  } @finally {
    if (gSetTimeout != NULL) gSetTimeout(previous);
    NSTimeInterval elapsed = -[start timeIntervalSinceNow];
    if (elapsed >= gCap * 0.95) {
      gCapHits += 1;
      NSLog(@"[edge-flow] quiescence cap hit (%.2fs >= %.2fs) %@ step: %@", elapsed, gCap, name, gCurrentStep);
    }
    gDepth -= 1;
    [gLock unlock];
  }
}

static void swizzledIdle(id self, SEL _cmd, BOOL includingAnimations)
{
  capped(@"waitForQuiescenceIncludingAnimationsIdle:", ^{
    ((void (*)(id, SEL, BOOL))gOrigIdle)(self, _cmd, includingAnimations);
  });
}

static void swizzledPreEvent(id self, SEL _cmd, BOOL includingAnimations, BOOL isPreEvent)
{
  capped(@"waitForQuiescenceIncludingAnimationsIdle:isPreEvent:", ^{
    ((void (*)(id, SEL, BOOL, BOOL))gOrigPreEvent)(self, _cmd, includingAnimations, isPreEvent);
  });
}

// usingActivity is a BOOL, not an XCTActivity (Xcode 26 passes 0/1 there).
static void swizzledActivity(id self, SEL _cmd, BOOL includingAnimations, BOOL usingActivity, BOOL isPreEvent)
{
  capped(@"waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:", ^{
    ((void (*)(id, SEL, BOOL, BOOL, BOOL))gOrigActivity)(self, _cmd, includingAnimations, usingActivity, isPreEvent);
  });
}

// Swaps only when every argument is a BOOL (`B` or `c`) and the method
// returns void, so a changed private signature skips the cap instead of
// crashing the runner.
static IMP swap(Class cls, NSString *selectorName, IMP replacement, unsigned int boolArgs)
{
  Method method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
  if (method == NULL) return NULL;
  unsigned int count = method_getNumberOfArguments(method);
  char returnType[8];
  method_getReturnType(method, returnType, sizeof(returnType));
  BOOL matches = count == boolArgs + 2 && returnType[0] == 'v';
  for (unsigned int i = 2; matches && i < count; i++) {
    char argType[8];
    method_getArgumentType(method, i, argType, sizeof(argType));
    matches = argType[0] == 'B' || argType[0] == 'c';
  }
  if (!matches) {
    NSLog(@"[edge-flow] quiescence cap skips %@ (unexpected signature %s)", selectorName, method_getTypeEncoding(method));
    return NULL;
  }
  return method_setImplementation(method, replacement);
}

@implementation EdgeQuiescence

+ (NSTimeInterval)cap { return gCap; }
+ (void)setCap:(NSTimeInterval)cap { gCap = cap; }
+ (NSString *)currentStep { return gCurrentStep; }
+ (void)setCurrentStep:(NSString *)step { gCurrentStep = [step copy]; }
+ (NSInteger)capHits { return gCapHits; }

+ (void)install
{
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gLock = [NSRecursiveLock new];
    gSetTimeout = (SetTimeoutFn)dlsym(RTLD_DEFAULT, "_XCTSetApplicationStateTimeout");
    gGetTimeout = (GetTimeoutFn)dlsym(RTLD_DEFAULT, "_XCTApplicationStateTimeout");
    Class cls = NSClassFromString(@"XCUIApplicationProcess");
    if (cls == Nil || gSetTimeout == NULL) {
      NSLog(@"[edge-flow] quiescence cap unavailable (XCUIApplicationProcess or _XCTSetApplicationStateTimeout missing)");
      return;
    }
    gOrigIdle = swap(cls, @"waitForQuiescenceIncludingAnimationsIdle:", (IMP)swizzledIdle, 1);
    gOrigPreEvent = swap(cls, @"waitForQuiescenceIncludingAnimationsIdle:isPreEvent:", (IMP)swizzledPreEvent, 2);
    gOrigActivity = swap(cls, @"waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:", (IMP)swizzledActivity, 3);
    NSLog(@"[edge-flow] quiescence cap installed (idle=%d preEvent=%d activity=%d)", gOrigIdle != NULL, gOrigPreEvent != NULL, gOrigActivity != NULL);
  });
}

@end
