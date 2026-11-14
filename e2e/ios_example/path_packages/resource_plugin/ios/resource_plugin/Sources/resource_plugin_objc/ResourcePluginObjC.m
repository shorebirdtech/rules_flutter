#import "ResourcePluginObjC.h"

@implementation ResourcePluginObjC

+ (NSString *)greeting {
  NSURL *url = [SWIFTPM_MODULE_BUNDLE URLForResource:@"objc_greeting"
                                       withExtension:@"txt"];
  NSString *text = url ? [NSString stringWithContentsOfURL:url
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil]
                       : nil;
  return text ?: @"no objc_greeting.txt";
}

@end
