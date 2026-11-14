import Flutter
import Foundation
import resource_plugin_objc

/// Answers `greeting` with the text of `greeting.txt`, a resource of the
/// plugin's Swift package, which it finds through `Bundle.module`; and
/// `greetingObjc` with the text of `objc_greeting.txt`, a resource of the
/// package's Objective-C target, which that target reads through
/// `SWIFTPM_MODULE_BUNDLE`.
public class ResourcePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "resource_plugin", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(ResourcePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "greetingObjc" {
            result(ResourcePluginObjC.greeting())
            return
        }
        guard call.method == "greeting" else {
            result(FlutterMethodNotImplemented)
            return
        }
        let url = Bundle.module.url(forResource: "greeting", withExtension: "txt")
        result(url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "no greeting.txt")
    }
}
