#import "MXDMixedPlugin.h"

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
    result([MXDMixedPlugin greeting]);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end
