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
  // `pick`'s link hook keeps the library of the `Op` the app constructs and
  // drops the other, which neither the bundle nor its manifest carries.
  check
    ..exists(
      'code asset the link hook kept, pick_kept.dll',
      bundle.file('pick_kept.dll'),
      nonEmpty: true,
    )
    ..absent(
      'code asset the link hook dropped, pick_dropped.dll,',
      bundle.file('pick_dropped.dll'),
    )
    ..nativeAssetsManifest(
      bundle.flutterAssets,
      shipped: ['package:pick/kept', 'package:add_plugin/add_plugin.dart'],
      dropped: ['package:pick/dropped'],
    );
  bundle.finish();
}
