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
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final quickjs = getJavascriptRuntime().evaluate('6 * 7').stringResult;
  String videoPlayer;
  try {
    await AVFoundationVideoPlayer().init();
    videoPlayer = 'ok';
  } on Object catch (e) {
    videoPlayer = '$e';
  }
  runApp(
    Center(
      child: Text(
        'quickjs: $quickjs\nvideo_player: $videoPlayer',
        textDirection: TextDirection.ltr,
      ),
    ),
  );
}
