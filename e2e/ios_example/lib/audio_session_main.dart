import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator_apple/geolocator_apple.dart';

/// Shows what audio_session and geolocator_apple answer, each built with the
/// environment variable this app sets for its Package.swift.
///
/// audio_session compiles in its record permission code only with
/// `AUDIO_SESSION_MICROPHONE=1`: with it, `recordPermission` answers with the
/// permission (`undetermined` on a fresh simulator); without it, the plugin
/// does not implement the call. geolocator_apple answers `checkPermission`
/// either way.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final record = await _answer(
    () async => (await AVAudioSession().recordPermission).name,
  );
  final location = await _answer(
    () async => (await GeolocatorApple().checkPermission()).name,
  );
  runApp(
    Center(
      child: Text(
        'record: $record\nlocation: $location',
        textDirection: TextDirection.ltr,
      ),
    ),
  );
}

Future<String> _answer(Future<String> Function() call) async {
  try {
    return await call();
  } on Object catch (e) {
    return '$e';
  }
}
