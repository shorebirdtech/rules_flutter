/// Verifies the Linux bundle has the expected structure,
/// including the native shared library with the correct filename.
library;

import 'package:rules_flutter_e2e_testing/desktop_bundle.dart';

void main() {
  final bundle = LinuxBundle.fromRunfiles('ffi_plugin_linux');
  bundle
    ..checkStandardLayout()
    ..check.exists(
      'Native lib libmultiply.so',
      bundle.lib('libmultiply.so'),
      nonEmpty: true,
    )
    ..finish();
}
