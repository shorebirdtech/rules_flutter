/// Verifies that a shared library a plugin's Android library builds from
/// source reaches the APK, and that every native library there is aligned for
/// 16 KB pages: the Android C/C++ toolchain links the plugin's code, and
/// rules_flutter leaves it as the toolchain made it.
library;

import 'package:rules_flutter_e2e_testing/apk.dart';

void main() {
  final apk = Apk.fromRunfiles(
    'jni_probe/jni_probe_android_app.apk',
    prefix: 'jni_probe_apk_',
  );
  apk.check.exists(
    'the plugin builds libjni_probe.so (arm64-v8a)',
    '${apk.path}/lib/arm64-v8a/libjni_probe.so',
  );
  apk
    ..checkNativeLibraries()
    ..finish('All jni_probe APK checks passed.');
}
