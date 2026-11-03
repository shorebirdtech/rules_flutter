/// Verifies the Windows bundle produced by flutter_windows_app has the expected
/// directory structure.
///
/// Runs as a Bazel dart_test with the bundle as data dependency.
library;

import 'package:rules_flutter_e2e_testing/desktop_bundle.dart';

void main() {
  WindowsBundle.fromRunfiles('app')
    ..checkStandardLayout()
    ..finish();
}
