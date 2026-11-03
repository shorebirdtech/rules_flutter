/// Verifies the macOS .app bundle has the expected structure,
/// including the native dylib with the correct filename.
///
/// rules_apple outputs a .zip — we extract it to a temp dir and verify.
library;

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'ffi_macos.zip',
    appName: 'ffi_macos',
  );
  try {
    final check = bundle.check
      ..exists(
        'Native-asset dylib libadd.dylib exists',
        '${bundle.frameworks}/libadd.dylib',
      )
      ..exists(
        'native_deps dylib libmul.dylib exists',
        '${bundle.frameworks}/libmul.dylib',
      )
      ..exists(
        'code-asset dylib libsub.dylib exists',
        '${bundle.frameworks}/libsub.dylib',
      )
      ..exists(
        'curated code-asset dylib libsqlite3.dylib exists',
        '${bundle.frameworks}/libsqlite3.dylib',
      )
      ..exists(
        'combined code-asset dylib libcounter.dylib exists',
        '${bundle.frameworks}/libcounter.dylib',
      );
    // The app serves both packages' ids from `libcounter.dylib`, so the
    // standalone libraries the packages declare for themselves stay out.
    for (final name in ['libcounter_a.dylib', 'libcounter_b.dylib']) {
      check.absent('replaced code asset $name', '${bundle.frameworks}/$name');
    }
    bundle
      ..checkFlutterLayout(nib: null)
      ..finish('All macOS bundle verification checks passed.');
  } finally {
    bundle.dispose();
  }
}
