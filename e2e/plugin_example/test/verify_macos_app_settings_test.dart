/// Verifies that a macOS app builds a plugin whose `Package.swift` decides its
/// defines from the app with the environment the app gives it.
///
/// `geolocator_apple` 2.4.3 leaves out its check for an "always" location
/// description when `BYPASS_PERMISSION_LOCATION_ALWAYS` is 1, which
/// `location_macos` sets in `swift_package_environment`.
library;

import 'package:rules_flutter_e2e_testing/mach_o.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'location_macos.zip',
    appName: 'location_macos',
  );
  try {
    final runner = MachO(bundle.runner);
    bundle.check
      ..expect(
        "the app carries geolocator_apple's plugin",
        condition: runner.hasSymbolContaining('GeolocatorPlugin'),
      )
      ..expect(
        "the app leaves out geolocator_apple's check for an always "
        'description (BYPASS_PERMISSION_LOCATION_ALWAYS=1)',
        condition: !runner.hasSymbolContaining(
          'containsLocationAlwaysDescription',
        ),
      );
    bundle.finish('location_macos carries the code its defines select.');
  } finally {
    bundle.dispose();
  }
}
