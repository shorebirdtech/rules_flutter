#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import AppKit
  import FlutterMacOS
#endif

public class GlassPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "glass_plugin", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(GlassPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "reduceTransparency":
      #if os(iOS)
        result([
          "platform": "ios",
          "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
        ])
      #else
        result([
          "platform": "macos",
          "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        ])
      #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
