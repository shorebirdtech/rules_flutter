/// Property: a release macOS build leaves a dSYM that symbolicates the shipped
/// `App.framework/App`, as `flutter build macos --release` does.
///
/// Built with `--apple_generate_dsym`, the flag a Bazel Apple developer turns
/// on to get dSYMs, the outputs hold a `.dSYM` whose UUID is the `App`
/// binary's. A crash reporter matches reports to dSYMs by that UUID.
///
/// Run once for each `-c` that builds Flutter's release mode (see the BUILD
/// file).
library;

import 'package:rules_flutter_e2e_testing/apple_release.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles('app.zip', appName: 'Flutter App');
  try {
    checkDsymMatches(
      bundle.check,
      '${bundle.frameworks}/App.framework/App',
      runfilesDsyms(),
    );
    bundle.finish('A dSYM matches the App binary.');
  } finally {
    bundle.dispose();
  }
}
