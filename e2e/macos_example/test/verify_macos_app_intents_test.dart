/// Verifies that `flutter_macos_app(runner_deps = [...], app_intents = [...])`
/// ships App Intents: the bundle carries the extracted metadata and it names
/// the intent, and the runner binary links the library that declares it.
library;

import 'package:rules_flutter_e2e_testing/app_intents.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'app_intents.zip',
    appName: 'Intents App',
    prefix: 'macos_intents_test',
  );
  try {
    final check = bundle.check;
    AppIntentsMetadata('${bundle.contents}/Resources')
        .checkNames(check, 'PingIntent', owner: 'the bundle');

    // The metadata alone is not the app: the runner has to carry the code.
    check.expect(
      'the runner binary links PingIntent',
      condition: MachO(bundle.runner).hasSymbolContaining('PingIntent'),
    );

    bundle.finish('All macOS App Intents checks passed.');
  } finally {
    bundle.dispose();
  }
}
