// A native macOS app built by Xcode that shows a Flutter screen: it runs a
// FlutterEngine, registers the module's plugins and shows a
// FlutterViewController.
import FlutterMacOS
import FlutterPluginRegistrant
import SwiftUI
import mixed_plugin

final class FlutterDependencies {
  let engine = FlutterEngine(name: "host", project: nil)

  init() {
    engine.run(withEntrypoint: nil)
    RegisterGeneratedPlugins(registry: engine)
    // The Swift half of a plugin that mixes Swift and Objective-C, called
    // from the host through the plugin's module.
    print("add_to_app_host \(MixedSwiftGreeter.greeting())")
  }
}

struct FlutterView: NSViewControllerRepresentable {
  let engine: FlutterEngine

  func makeNSViewController(context: Context) -> FlutterViewController {
    FlutterViewController(engine: engine, nibName: nil, bundle: nil)
  }

  func updateNSViewController(_ controller: FlutterViewController, context: Context) {}
}

@main
struct HostApp: App {
  let flutter = FlutterDependencies()

  var body: some Scene {
    WindowGroup {
      VStack(spacing: 0) {
        Text("Native SwiftUI host")
          .font(.headline)
          .padding()
        FlutterView(engine: flutter.engine)
          .frame(minWidth: 480, minHeight: 640)
      }
    }
  }
}
