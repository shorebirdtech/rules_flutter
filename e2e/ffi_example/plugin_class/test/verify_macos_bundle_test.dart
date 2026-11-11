/// Verifies the macOS .app bundle has the expected structure,
/// including the native dylib with the correct filename.
///
/// rules_apple outputs a .zip — we extract it to a temp dir and verify.
library;

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'plugin_class/plugin_class_macos.zip',
    appName: 'plugin_class_macos',
  );
  try {
    bundle
      ..check.exists(
        'Native dylib libmultiply.dylib exists',
        '${bundle.frameworks}/libmultiply.dylib',
      )
      ..checkFlutterLayout(nib: null)
      ..finish('All macOS bundle verification checks passed.');
  } finally {
    bundle.dispose();
  }
}
