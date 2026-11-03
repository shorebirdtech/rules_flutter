/// Verifies that a desktop bundle built in Flutter profile mode carries a
/// profile AOT snapshot, not a release one.
///
/// The bundle comes from `profile_build`, which builds the app with
/// `-c opt --@rules_flutter//flutter:profile` whatever the command line says.
/// Run as `dart_test(args = ["<bundle target name>", "<AOT snapshot path>"])`;
/// the AOT snapshot is `lib/libapp.so` on Linux and `data/app.so` on Windows.
///
/// A profile engine refuses a snapshot built for another mode ("VM snapshot
/// invalid"), so the mode recorded in the snapshot is what decides whether the
/// app starts. Every Dart AOT snapshot opens with a feature string that names
/// the runtime it was built for: `product` for Flutter's release gen_snapshot,
/// `release` for the profile one. A release snapshot in a profile bundle, or
/// the reverse, is exactly what this test exists to catch.
///
/// This runs on the platform that built the bundle, as no other host can
/// produce a Linux or Windows AOT snapshot. Starting the app and reaching its
/// VM service is a manual check (docs/TESTING.md, "Profile mode on Linux and
/// Windows").
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// `<32-hex snapshot hash><mode> <flags...>`, as the Dart VM writes it.
final _features = RegExp('[0-9a-f]{32}(product|release|debug) ');

void main(List<String> args) {
  final bundleName = args[0];
  final aotPath = args[1];

  late Directory bundle;

  setUpAll(() {
    // Through the runfiles library, as `windows-latest` runs with
    // `--noenable_runfiles` and so has no tree to walk.
    bundle = Directory(Runfiles.create().rlocation('_main/$bundleName'));
    if (!bundle.existsSync()) {
      throw StateError('Bundle not found at ${bundle.path}');
    }
  });

  test('the AOT snapshot is a profile snapshot', () {
    final snapshot = File('${bundle.path}/$aotPath');
    expect(
      snapshot.existsSync(),
      isTrue,
      reason:
          '$aotPath is missing: the bundle holds a kernel blob (a debug '
          'build), not an AOT snapshot',
    );
    // The feature string is plain ASCII inside binary data.
    final text = latin1.decode(snapshot.readAsBytesSync());
    final modes = {for (final m in _features.allMatches(text)) m.group(1)};
    expect(
      modes,
      equals({'release'}),
      reason:
          'profile mode is Dart "release", and "product" is a release build, '
          'which serves no VM service',
    );
  });
}
