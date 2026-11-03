/// Verifies the plugins' generated `BuildConfig` classes are present in the
/// APK of every build mode and name the package they are in.
///
/// Property: whatever the build mode, a plugin that reads
/// `BuildConfig.LIBRARY_PACKAGE_NAME` gets its own namespace, and each way
/// the stub is produced (generated for a hub plugin, written out by hand for
/// an `ext/` overlay) yields a `BuildConfig` in its plugin's package.
///
/// What the class says about the mode is checked by
/// `verify_android_build_config_mode_test`.
library;

import 'android_build_config.dart';

void main() {
  verifyEachMode('\nAll plugin_example BuildConfig identity checks passed.', (
    apk,
    mode,
    configs,
  ) {
    pluginBuildConfigPackages.forEach((package, how) {
      apk.check.expect(
        '${mode.label}: $package.BuildConfig is in the APK ($how)',
        condition: configs.containsKey(package),
        detail: 'found only ${configs.keys.toList()..sort()}',
      );
    });
    for (final MapEntry(key: package, value: fields) in configs.entries) {
      apk.check.expect(
        '${mode.label}: $package.BuildConfig.LIBRARY_PACKAGE_NAME '
        'is "$package"',
        condition: fields['LIBRARY_PACKAGE_NAME'] == package,
        detail: 'LIBRARY_PACKAGE_NAME is ${fields['LIBRARY_PACKAGE_NAME']}',
      );
    }
  });
}
