/// Verifies an APK's native libraries come from one place: each ABI's
/// `libapp.so` once, the code asset `pick`'s link hook kept, stored, and, in
/// release, not the one it dropped, which the shipped
/// `NativeAssetsManifest.json` leaves out too. A debug build runs no hook and
/// ships both.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';
import 'package:rules_flutter_e2e_testing/zip_entries.dart';

void main() {
  final check = BundleCheck();
  for (final (apkName, release) in [
    ('pick_android_arm64.apk', true),
    ('pick_android_dbg.apk', false),
  ]) {
    const abi = 'arm64-v8a';
    final entries = zipEntries(
      File(requireRunfile(apkName, what: 'APK')).readAsBytesSync(),
    );
    List<ZipEntry> named(String name) => [
      for (final entry in entries)
        if (entry.name == name) entry,
    ];
    final libApp = named('lib/$abi/libapp.so');
    check.expect(
      '$apkName has ${release ? 'one' : 'no'} lib/$abi/libapp.so',
      condition: libApp.length == (release ? 1 : 0),
      detail: 'found ${libApp.length}',
    );
    final kept = named('lib/$abi/libpick_kept.so');
    check
      ..expect(
        '$apkName has lib/$abi/libpick_kept.so once, stored',
        condition: kept.length == 1 && kept.single.stored,
        detail: 'found ${kept.length}',
      )
      ..expect(
        '$apkName ${release ? 'leaves out' : 'has'} the dropped '
        'lib/$abi/libpick_dropped.so',
        condition:
            named('lib/$abi/libpick_dropped.so').length == (release ? 0 : 1),
      );
    final apk = Apk.fromRunfiles(apkName, prefix: 'pick_apk', check: check);
    try {
      check.nativeAssetsManifest(
        apk.file('assets/flutter_assets').path,
        shipped: ['package:pick/kept', if (!release) 'package:pick/dropped'],
        dropped: [if (release) 'package:pick/dropped'],
      );
    } finally {
      apk.dispose();
    }
  }
  check.finish('The APKs carry their native libraries once each.');
}
