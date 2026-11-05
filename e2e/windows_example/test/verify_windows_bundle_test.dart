/// Verifies the Windows bundle produced by flutter_windows_app has the expected
/// directory structure, and that its executable carries the icon, version
/// information and manifest of the `flutter create` runner.
///
/// Runs as a Bazel dart_test with the bundle as data dependency.
library;

import 'package:rules_flutter_e2e_testing/desktop_bundle.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

void main() {
  WindowsBundle.fromRunfiles('app')
    ..checkStandardLayout()
    ..checkRunnerResources(
      version: '2.3.4+56',
      fileVersion: [2, 3, 4, 56],
      icon: requireRunfile('windows/runner/resources/app_icon.ico'),
    )
    ..finish();
}
