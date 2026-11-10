/// Verifies that a plugin whose `Package.swift` decides its defines from the
/// app is built for each app with the defines Xcode would give it.
///
/// `permission_handler_apple` 9.6.5 compiles in a permission's code when the
/// app's Info.plist has its usage description. `permission_app`'s plist has
/// `NSCameraUsageDescription` and no other: its binary carries the camera's
/// code and not the microphone's or the contacts'.
///
/// `audio_session` 0.2.4 compiles in its record permission code when
/// `AUDIO_SESSION_MICROPHONE` is 1 in the manifest's environment, and
/// `geolocator_apple` 2.4.3 leaves out its check for an "always" location
/// description when `BYPASS_PERMISSION_LOCATION_ALWAYS` is 1.
/// `audio_session_app` sets both in `swift_package_environment`.
library;

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';

void main() {
  _check('permission_app.ipa', 'ios_permission_test', [
    (
      'the camera permission (NSCameraUsageDescription)',
      '+[AudioVideoPermissionStrategy permissionStatus:]',
      true,
    ),
    (
      'the contacts permission (no usage description)',
      '-[ContactPermissionStrategy checkPermissionStatus:]',
      false,
    ),
  ]);
  _check('audio_session_app.ipa', 'ios_audio_session_test', [
    (
      "audio_session's record permission (AUDIO_SESSION_MICROPHONE=1)",
      '-[DarwinAudioSession flutterToRecordPermission:]',
      true,
    ),
    ("geolocator_apple's plugin", 'GeolocatorPlugin', true),
    (
      "geolocator_apple's check for an always description "
          '(BYPASS_PERMISSION_LOCATION_ALWAYS=1)',
      'containsLocationAlwaysDescription',
      false,
    ),
  ]);
}

void _check(String ipa, String prefix, List<(String, String, bool)> code) {
  final bundle = IosBundle.fromRunfiles(ipa, prefix: prefix);
  try {
    // A debug build may put the runner's code in a sibling `.debug.dylib`.
    final binaries = bundle.rootFiles;
    for (final (what, symbol, present) in code) {
      final found = binaries.any(
        (f) => MachO(f.path).hasSymbolContaining(symbol),
      );
      bundle.check.expect(
        '$ipa ${present ? 'carries' : 'leaves out'} $what',
        condition: found == present,
      );
    }
    bundle.finish('$ipa carries the code its defines select.');
  } finally {
    bundle.dispose();
  }
}
