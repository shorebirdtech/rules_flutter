import Flutter
import Foundation

// `swift(>=6)` is true only in the Swift 6 language mode, whatever the
// compiler's version: in Swift 5 mode this file does not compile.
#if swift(>=6)
private let languageMode = "Swift 6 language mode"
#else
#error("swift6_plugin must be compiled in the Swift 6 language mode")
#endif

/// Answers `mode` with the language mode its source needs.
public final class Swift6Plugin: NSObject, FlutterPlugin, Sendable {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "swift6_plugin", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(Swift6Plugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "mode" else {
            // Not `FlutterMethodNotImplemented`, a mutable global that Swift 6
            // refuses to reference.
            result(FlutterError(code: "unknown", message: call.method, details: nil))
            return
        }
        result(languageMode)
    }
}
