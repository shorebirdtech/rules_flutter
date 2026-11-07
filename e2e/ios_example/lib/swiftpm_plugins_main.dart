import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:libremidi_flutter/libremidi_flutter.dart';
import 'package:resource_plugin/resource_plugin.dart';
import 'package:script_phase_plugin/script_phase_plugin.dart';
import 'package:swift6_plugin/swift6_plugin.dart';
import 'package:video_player_avfoundation/video_player_avfoundation.dart';

/// Shows what plugins built from their Swift packages answer:
///
/// * QuickJS, compiled from flutter_qjs_next's C sources, evaluates `6 * 7`
///   to `42`.
/// * video_player_avfoundation, a package of four targets, answers `init()`
///   over its platform channel: `ok`, or the error when its native side is
///   missing.
/// * firebase_core configures the Firebase SDK, a remote Swift package, with
///   these options (no network is needed), and answers with the app's
///   project: `rules-flutter-e2e`.
/// * libremidi_flutter, an FFI plugin whose C++ its Swift package builds,
///   lists the MIDI outputs through `DynamicLibrary.process()`: a count, or
///   the error when its code is not in the app.
/// * script_phase_plugin, whose podspec runs a script phase but which Flutter
///   builds from its Package.swift, answers `swiftpm`.
/// * resource_plugin reads a resource of its Swift package from
///   `Bundle.module`: `from the bundle`; and one of its Objective-C target
///   from `SWIFTPM_MODULE_BUNDLE`: `from the objc bundle`.
/// * swift6_plugin, whose source compiles only in the Swift 6 language mode,
///   answers `Swift 6 language mode`.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final quickjs = getJavascriptRuntime().evaluate('6 * 7').stringResult;
  final videoPlayer = await _answer(() => AVFoundationVideoPlayer().init());
  final firebase = await _answer(() async {
    final app = await Firebase.initializeApp(
      options: const FirebaseOptions(
        // As Firebase checks a key: 39 characters, starting with `A`.
        apiKey: 'AIzaSyBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        appId: '1:123456789012:ios:0123456789abcdef012345',
        messagingSenderId: '123456789012',
        projectId: 'rules-flutter-e2e',
        iosBundleId: 'com.rulesflutter.ios.example.swiftpm',
      ),
    );
    return app.options.projectId;
  });
  final midi = await _answer(
    () async => '${MidiObserver().getOutputPorts().length} outputs',
  );
  final scriptPhase = await _answer(scriptPhasePluginBuild);
  final resource = await _answer(resourcePluginGreeting);
  final resourceObjc = await _answer(resourcePluginObjcGreeting);
  final swift6 = await _answer(swift6PluginMode);
  runApp(
    Center(
      child: Text(
        'quickjs: $quickjs\nvideo_player: $videoPlayer\nfirebase: $firebase\n'
        'midi: $midi\nscript_phase: $scriptPhase\nresource: $resource\n'
        'resource_objc: $resourceObjc\n'
        'swift6: $swift6',
        textDirection: TextDirection.ltr,
      ),
    ),
  );
}

Future<String> _answer(Future<Object?> Function() call) async {
  try {
    final result = await call();
    return result is String ? result : 'ok';
  } on Object catch (e) {
    return '$e';
  }
}
