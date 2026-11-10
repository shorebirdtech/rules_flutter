import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

/// Shows what permission_handler_apple answers for the camera, which this
/// app's Info.plist explains, and for the microphone, which it does not.
///
/// The plugin compiles in a permission's code only when its Package.swift,
/// evaluated for the app, finds the usage description in the app's Info.plist.
/// With both permissions granted beforehand (`xcrun simctl privacy ... grant`),
/// the camera reads `granted` and the microphone `denied`: compiled out, it
/// answers `denied` whatever the system says.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final camera = await Permission.camera.status;
  final microphone = await Permission.microphone.status;
  runApp(
    Center(
      child: Text(
        'camera: ${camera.name}\nmicrophone: ${microphone.name}',
        textDirection: TextDirection.ltr,
      ),
    ),
  );
}
