// A native iOS app built by Xcode that shows a Flutter screen, as Flutter's
// add-to-app guide for SwiftUI does: it runs a FlutterEngine, registers the
// module's plugins and shows a FlutterViewController.
import Flutter
import FlutterPluginRegistrant
import SwiftUI
import mixed_plugin

final class FlutterDependencies {
  let engine = FlutterEngine(name: "host")

  init() {
    engine.run()
    GeneratedPluginRegistrant.register(with: engine)
    // The Swift half of a plugin that mixes Swift and Objective-C, called
    // from the host through the plugin's module.
    print("add_to_app_host \(MixedSwiftGreeter.greeting())")
  }
}

struct FlutterView: UIViewControllerRepresentable {
  let engine: FlutterEngine

  func makeUIViewController(context: Context) -> FlutterViewController {
    FlutterViewController(engine: engine, nibName: nil, bundle: nil)
  }

  func updateUIViewController(_ controller: FlutterViewController, context: Context) {}
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
      }
    }
  }
}
