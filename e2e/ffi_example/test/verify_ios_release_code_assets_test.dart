/// Verifies a release iOS app for a device carries the framework of the code
/// asset `pick`'s link hook kept and not the one it dropped, which its
/// post-processor removed with the list it read, and that the app's
/// `NativeAssetsManifest.json` names the same.
library;

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'ffi_ios_device.ipa',
    appName: 'ffi_ios_device',
  );
  bundle.check
    ..exists(
      'the kept pick_kept.framework',
      '${bundle.path}/Frameworks/pick_kept.framework/pick_kept',
    )
    ..exists(
      'a code asset no hook chose among, add.framework',
      '${bundle.path}/Frameworks/add.framework/add',
    )
    ..absent(
      'the dropped pick_dropped.framework',
      '${bundle.path}/Frameworks/pick_dropped.framework',
    )
    ..absent(
      'the list of frameworks to remove',
      '${bundle.path}/rules_flutter_dropped_frameworks.txt',
    )
    ..nativeAssetsManifest(
      '${bundle.path}/Frameworks/App.framework/flutter_assets',
      shipped: ['package:pick/kept'],
      dropped: ['package:pick/dropped'],
    );
  bundle.finish('The release iOS app ships what the link hook kept.');
}
