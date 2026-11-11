/// Verifies the Windows bundle has the expected structure, including both
/// native shared libraries next to the runner exe (that is where the loader —
/// and the native-assets manifest's bare-basename entries — expect them).
library;

import 'package:rules_flutter_e2e_testing/desktop_bundle.dart';

void main() {
  final bundle = WindowsBundle.fromRunfiles('ffi_windows')
    ..checkStandardLayout();
  final check = bundle.check
    ..exists('Native-asset lib add.dll', bundle.file('add.dll'), nonEmpty: true)
    ..exists('native_deps lib mul.dll', bundle.file('mul.dll'), nonEmpty: true)
    ..exists(
      'curated code-asset lib sqlite3.dll',
      bundle.file('sqlite3.dll'),
      nonEmpty: true,
    )
    ..exists(
      'combined code-asset lib counter.dll',
      bundle.file('counter.dll'),
      nonEmpty: true,
    )
    ..exists(
      'prebuilt code-asset lib negate.dll',
      bundle.file('negate.dll'),
      nonEmpty: true,
    );
  // The app serves both packages' ids from `counter.dll`, so the standalone
  // libraries the packages declare for themselves stay out.
  for (final name in ['counter_a.dll', 'counter_b.dll']) {
    check.absent('replaced code asset $name', bundle.file(name));
  }
  bundle.finish();
}
