#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// Answers `greeting` on the `mixed_plugin` channel.
@interface MXDMixedPlugin : NSObject <FlutterPlugin>

/// The Objective-C half's greeting, which the Swift half's builds on.
+ (NSString *)greeting;

@end

NS_ASSUME_NONNULL_END
