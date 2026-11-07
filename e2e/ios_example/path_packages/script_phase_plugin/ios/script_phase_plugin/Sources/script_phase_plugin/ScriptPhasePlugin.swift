import Flutter

/// Answers `build` with `swiftpm`: this code is in the app only when the
/// plugin is built from its Package.swift.
public class ScriptPhasePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "script_phase_plugin", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(ScriptPhasePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        result(call.method == "build" ? "swiftpm" : FlutterMethodNotImplemented)
    }
}
