/// Verifies that `--@rules_flutter//flutter:build_number` reaches the bundle.
///
/// `:app` repeats its application's build number, 42, as its own
/// `build_number`. Built with the setting at 123, as
/// `flutter build macos --build-number 123` would build it, its Info.plist
/// carries 123, and its build name stays the application's.
library;

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'app.zip',
    appName: 'Flutter App',
    prefix: 'macos_build_number_test',
  );
  try {
    bundle
      ..checkInfoPlistValue('CFBundleVersion', '123')
      ..checkInfoPlistValue('CFBundleShortVersionString', '2.3.4')
      ..finish('The bundle carries the build number the setting gives.');
  } finally {
    bundle.dispose();
  }
}
