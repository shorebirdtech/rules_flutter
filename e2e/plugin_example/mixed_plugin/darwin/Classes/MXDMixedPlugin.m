#import "MXDMixedPlugin.h"

// How Flutter's plugin template imports the Swift half's generated header.
#if __has_include(<mixed_plugin/mixed_plugin-Swift.h>)
#import <mixed_plugin/mixed_plugin-Swift.h>
#else
#import "mixed_plugin-Swift.h"
#endif

@implementation MXDMixedPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
#if TARGET_OS_OSX
  NSObject<FlutterBinaryMessenger> *messenger = registrar.messenger;
#else
  NSObject<FlutterBinaryMessenger> *messenger = [registrar messenger];
#endif
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"mixed_plugin"
                                                              binaryMessenger:messenger];
  [registrar addMethodCallDelegate:[[MXDMixedPlugin alloc] init] channel:channel];
}

+ (NSString *)greeting {
  return @"Hello from Objective-C";
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"greeting"]) {
    // The Swift half, which the Objective-C sees through its generated
    // header.
    result([MixedSwiftGreeter greeting]);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end
