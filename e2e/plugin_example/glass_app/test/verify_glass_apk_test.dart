/// Verifies that `//glass_plugin`'s own AndroidManifest.xml is merged into
/// the app's: the boot receiver it declares and the permission it asks for
/// are in the APK. A plugin that re-arms alarms after a reboot works only
/// if they are.
library;

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/bytes.dart';

const _expected = [
  'com.example.glass_plugin.GlassBootReceiver',
  'android.intent.action.BOOT_COMPLETED',
  'android.permission.RECEIVE_BOOT_COMPLETED',
];

void main() {
  final apk = Apk.fromRunfiles(
    'glass_app/glass_android.apk',
    prefix: 'glass_apk_',
  );
  final manifest = apk.manifest.readAsBytesSync();
  for (final name in _expected) {
    // Binary XML stores its strings as UTF-16.
    apk.check.expect(
      'merged manifest names $name',
      condition: containsBytes(manifest, utf16leBytes(name)),
      detail: 'merged manifest lacks $name',
    );
  }
  apk.finish('All glass_app APK checks passed.');
}
