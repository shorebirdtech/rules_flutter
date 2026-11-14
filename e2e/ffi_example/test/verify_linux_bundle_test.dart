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
    )
    ..exists(
      'prebuilt code-asset lib libnegate.so',
      bundle.lib('libnegate.so'),
      nonEmpty: true,
    );
  // The app serves both packages' ids from `libcounter.so`, so the standalone
  // libraries the packages declare for themselves stay out.
  for (final name in ['libcounter_a.so', 'libcounter_b.so']) {
    check.absent('replaced code asset $name', bundle.lib(name));
  }
  // `pick`'s link hook keeps the library of the `Op` the app constructs and
  // drops the other, which neither the bundle nor its manifest carries.
  check
    ..exists(
      'code asset the link hook kept, libpick_kept.so',
      bundle.lib('libpick_kept.so'),
      nonEmpty: true,
    )
    ..absent(
      'code asset the link hook dropped, libpick_dropped.so,',
      bundle.lib('libpick_dropped.so'),
    )
    ..nativeAssetsManifest(
      bundle.flutterAssets,
      shipped: ['package:pick/kept', 'package:add_plugin/add_plugin.dart'],
      dropped: ['package:pick/dropped'],
    );
  bundle.finish();
}
