#import "FixturePlugin.h"
#import "FixtureInternal.h"

@implementation FixturePlugin
+ (NSString *)feature {
#if FIXTURE_FEATURE
    return @"on";
#else
    return @"off";
#endif
}
@end
