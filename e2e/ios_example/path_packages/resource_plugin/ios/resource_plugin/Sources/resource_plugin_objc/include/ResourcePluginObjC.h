#import <Foundation/Foundation.h>

/// Reads a resource of its own Swift package target through
/// `SWIFTPM_MODULE_BUNDLE`.
@interface ResourcePluginObjC : NSObject
+ (NSString *)greeting;
@end
