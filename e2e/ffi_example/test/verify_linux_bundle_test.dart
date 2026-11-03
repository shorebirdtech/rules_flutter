/// Verifies the Linux bundle has the expected structure,
/// including the native shared library with the correct filename.
library;

import 'package:rules_flutter_e2e_testing/desktop_bundle.dart';

void main() {
  final bundle = LinuxBundle.fromRunfiles('ffi_linux')..checkStandardLayout();
  final check = bundle.check
    ..exists(
      'Native-asset lib libadd.so',
      bundle.lib('libadd.so'),
      nonEmpty: true,
    )
    ..exists(
      'native_deps lib libmul.so',
      bundle.lib('libmul.so'),
      nonEmpty: true,
    )
    ..exists(
      'curated code-asset lib libsqlite3.so',
      bundle.lib('libsqlite3.so'),
      nonEmpty: true,
    )
    ..exists(
      'combined code-asset lib libcounter.so',
      bundle.lib('libcounter.so'),
      nonEmpty: true,
    );
  // The app serves both packages' ids from `libcounter.so`, so the standalone
  // libraries the packages declare for themselves stay out.
  for (final name in ['libcounter_a.so', 'libcounter_b.so']) {
    check.absent('replaced code asset $name', bundle.lib(name));
  }
  bundle.finish();
}
