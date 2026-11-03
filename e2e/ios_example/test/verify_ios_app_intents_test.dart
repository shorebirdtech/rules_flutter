/// Verifies that `flutter_ios_app(runner_deps = [...], app_intents = [...])`
/// ships App Intents: the bundle carries the extracted metadata at its root and
/// it names the intent, and the runner binary links the library that declares
/// it.
library;

import 'package:rules_flutter_e2e_testing/app_intents.dart';
import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'app_intents.ipa',
    prefix: 'ios_intents_test',
  );
  try {
    final check = bundle.check;
    AppIntentsMetadata(bundle.path)
        .checkNames(check, 'PingIntent', owner: 'the bundle');

    // The metadata alone is not the app: the runner has to carry the code. A
    // debug build may put it in a sibling `.debug.dylib`, so look in every
    // Mach-O file at the bundle root.
    check.expect(
      'a binary in the bundle links PingIntent',
      condition: bundle.rootFiles.any(
        (f) => MachO(f.path).hasSymbolContaining('PingIntent'),
      ),
    );

    bundle.finish('All iOS App Intents checks passed.');
  } finally {
    bundle.dispose();
  }
}
