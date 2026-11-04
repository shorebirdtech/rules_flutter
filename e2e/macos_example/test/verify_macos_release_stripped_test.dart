/// Property: a release macOS bundle ships its Dart snapshot stripped, as
/// `flutter build macos --release` does.
///
/// `App.framework/App` keeps no local symbols (they name the app's Dart
/// functions, and are the bulk of the file) and no debugging-map entries; only
/// the external symbols the engine looks the snapshot up by remain.
///
/// Run once for each `-c` that builds Flutter's release mode (see the BUILD
/// file), since the strip must not depend on which of them was asked for.
library;

import 'package:rules_flutter_e2e_testing/apple_release.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles('app.zip', appName: 'Flutter App');
  try {
    bundle.check.exists(
      'App binary exists',
      '${bundle.frameworks}/App.framework/App',
    );
    checkAppBinaryStripped(
      bundle.check,
      '${bundle.frameworks}/App.framework/App',
    );
    bundle.finish('The App binary is stripped.');
  } finally {
    bundle.dispose();
  }
}
