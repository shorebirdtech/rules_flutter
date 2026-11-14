/// Verifies the `Info.plist` inside the built `.ipa` — specifically that an
/// app's own iOS 14+ Local Network Privacy keys coexist with the Dart VM
/// service keys rules_flutter adds to non-release builds.
///
/// `flutter_ios_app` adds `NSBonjourServices` and
/// `NSLocalNetworkUsageDescription` to every non-release build so the engine
/// can advertise the VM service over mDNS. Those keys are (correctly) absent
/// from `-c opt`: they exist for the debugger, not for the app. An app that
/// needs Local Network Privacy for *itself* must declare the keys in
/// `ios/Runner/Info.plist`, where they survive into release — and this
/// example does.
///
/// rules_apple's plisttool hard-fails when two plists declare one key with
/// different values, so the VM service keys are merged into the app's own
/// plist — the app's values win and the Bonjour service lists are unioned —
/// rather than passed beside it. This test asserts that on the real artifact.
///
/// It also checks the version keys come from the app's `build_name` and
/// `build_number`, the build name padded to three numbers as `flutter build`
/// pads it.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/plist.dart';

/// The Bonjour service this example declares for itself.
const _appService = '_rulesflutterexample._tcp';

/// The service the Flutter engine advertises the Dart VM service under.
const _vmService = '_dartVmService._tcp';

/// The opening words of this example's own usage description, which must win
/// over rules_flutter's ("Allow Flutter tools to find and connect…").
const _appUsageDescriptionPrefix = 'The example browses the local network';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'app.ipa',
    appName: 'app',
    prefix: 'ios_info_plist_',
  );
  try {
    final check = bundle.check..exists('Info.plist', bundle.infoPlist);
    if (check.ok) {
      // The bundled plist is in Apple's binary format; plutil renders it.
      final plist = Plist.readXml(bundle.infoPlist);
      final values = Plist.read(bundle.infoPlist);

      check
        ..expect(
          "the app's own Bonjour service survives the merge ($_appService)",
          condition: plist.contains(_appService),
        )
        ..expect(
          'the Dart VM service is unioned in, not substituted for it '
          '($_vmService)',
          condition: plist.contains(_vmService),
        )
        ..expect(
          "the app's own NSLocalNetworkUsageDescription wins over "
          "rules_flutter's",
          condition: plist.contains(_appUsageDescriptionPrefix),
        )
        ..expect(
          "rules_flutter's VM-service description did not overwrite the "
          "app's",
          condition: !plist.contains('Allow Flutter tools to find and connect'),
        )
        ..expect(
          'CFBundleShortVersionString is 2.3.0, from build_name "2.3"',
          condition: values['CFBundleShortVersionString'] == '2.3.0',
        )
        ..expect(
          'CFBundleVersion is 42, from build_number',
          condition: values['CFBundleVersion'] == '42',
        );
      if (!check.ok) {
        stderr
          ..writeln('\n--- Info.plist ---')
          ..writeln(plist);
      }
    }

    bundle.finish('\nAll iOS Info.plist checks passed.');
  } finally {
    bundle.dispose();
  }
}
