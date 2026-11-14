/// Property: a release iOS app ships its Dart snapshot stripped, as
/// `flutter build ios --release` does.
///
/// `App.framework/App` keeps no local symbols (they name the app's Dart
/// functions, and are the bulk of the file) and no debugging-map entries; only
/// the external symbols the engine looks the snapshot up by remain.
///
/// Checked on the framework the device build assembles, which is the `App` the
/// bundle embeds, for each `-c` that builds Flutter's release mode (see the
/// BUILD file).
library;

import 'package:rules_flutter_e2e_testing/apple_release.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';

void main() {
  final check = BundleCheck();
  checkAppBinaryStripped(check, runfilesAppBinary());
  check.finish('The App binary is stripped.');
}
