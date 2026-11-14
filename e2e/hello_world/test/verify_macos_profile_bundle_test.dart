/// Verifies that a macOS app built in Flutter profile mode carries a profile
/// AOT snapshot, not a release one.
///
/// The app comes from `flutter_profile_build`, which builds it with
/// `-c opt --@rules_flutter//flutter:profile` whatever the command line says.
/// Run as `dart_test(args = ["<app target>.zip", "<app name>"])`.
///
/// A profile engine refuses a snapshot built for another mode ("VM snapshot
/// invalid"). Every Dart AOT snapshot opens with a feature string that names
/// the runtime it was built for: `product` for Flutter's release gen_snapshot,
/// `release` for the profile one. The snapshot is `App.framework`'s binary.
/// Which engine the app bundles is checked at analysis
/// (`//flutter/tests:apple_engine_test`); starting the app is a manual check.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

/// `<32-hex snapshot hash><mode> <flags...>`, as the Dart VM writes it.
final _features = RegExp('[0-9a-f]{32}(product|release|debug) ');

void main(List<String> args) {
  final bundle = MacosBundle.fromRunfiles(
    args[0],
    appName: args[1],
    prefix: 'macos_profile_bundle_',
  );
  try {
    final app = '${bundle.frameworks}/App.framework/App';
    final check = bundle.check..exists('App.framework binary', app);
    if (check.ok) {
      // The feature string is plain ASCII inside binary data.
      final text = latin1.decode(File(app).readAsBytesSync());
      final modes = {for (final m in _features.allMatches(text)) m.group(1)};
      check.expect(
        'the AOT snapshot is a profile one',
        condition: modes.length == 1 && modes.first == 'release',
        detail:
            'its snapshot modes are $modes; profile mode is Dart "release", '
            'and "product" is a release build, which serves no VM service',
      );
    }
    bundle.finish('the profile macOS app carries a profile AOT snapshot');
  } finally {
    bundle.dispose();
  }
}
