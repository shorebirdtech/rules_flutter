import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';
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
  runApp(
    Center(
      child: Text(
        'quickjs: $quickjs\nvideo_player: $videoPlayer\nfirebase: $firebase',
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
