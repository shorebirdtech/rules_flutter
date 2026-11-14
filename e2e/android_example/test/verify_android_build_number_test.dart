/// Verifies that `--@rules_flutter//flutter:build_number` reaches the APK.
///
/// `:second_app` repeats its application's build number, 42, as its own
/// `build_number`. Built with the setting at 123, as
/// `flutter build apk --build-number 123` would build it, its manifest's
/// `versionCode` is 123, and its `versionName` stays the application's.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/apk_contents.dart';

void main() {
  final apk = Apk.fromRunfiles(
    'second_app.apk',
    prefix: 'android_build_number',
  );
  final root = manifestElements(apk.manifest.readAsBytesSync()).first;
  final versionCode = root.attributes['versionCode'];
  final versionName = root.attributes['versionName'];
  print('Version: $versionName ($versionCode)');
  apk.check
    ..expect(
      'versionCode is 123',
      condition: versionCode == '123',
      detail: 'expected versionCode 123 from the build_number setting',
    )
    ..expect(
      'versionName is 2.3.4',
      condition: versionName == '2.3.4',
      detail: "expected the application's versionName 2.3.4",
    );
  apk.finish('The APK carries the build number the setting gives.');
}
