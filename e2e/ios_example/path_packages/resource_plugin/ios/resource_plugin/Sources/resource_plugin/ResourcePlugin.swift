import Flutter
import Foundation

/// Answers `greeting` with the text of `greeting.txt`, a resource of the
/// plugin's Swift package, which it finds through `Bundle.module`.
public class ResourcePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "resource_plugin", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(ResourcePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "greeting" else {
            result(FlutterMethodNotImplemented)
            return
        }
        let url = Bundle.module.url(forResource: "greeting", withExtension: "txt")
        result(url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "no greeting.txt")
    }
}
