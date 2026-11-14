/// Verifies that what an Android plugin can observe about the build through
/// its `BuildConfig` is what Gradle would give it for the build mode.
///
/// Property: in every mode, each plugin's `BuildConfig.DEBUG` and
/// `BUILD_TYPE` are what the plugin would see in a Gradle build of the same
/// mode, so a plugin that gates logging or checks on them behaves in a Bazel
/// build as it does under `flutter run`:
///
/// | mode    | `DEBUG` | `BUILD_TYPE` |
/// |---------|---------|--------------|
/// | debug   | true    | `debug`      |
/// | profile | true    | `profile`    |
/// | release | false   | `release`    |
///
/// Profile is debuggable because Flutter's Gradle plugin makes its build type
/// from debug's: see [AndroidBuildMode].
library;

import 'android_build_config.dart';

void main() {
  verifyEachMode('\nAll plugin_example BuildConfig mode checks passed.', (
    apk,
    mode,
    configs,
  ) {
    if (configs.isEmpty) apk.check.fail('${mode.label}: no BuildConfig found');
    for (final MapEntry(key: package, value: fields) in configs.entries) {
      final where = '${mode.label}: $package.BuildConfig';
      apk.check
        ..expect(
          '$where.DEBUG is ${mode.debug}',
          condition: fields['DEBUG'] == mode.debug,
          detail: 'DEBUG is ${fields['DEBUG']}',
        )
        ..expect(
          '$where.BUILD_TYPE is "${mode.buildType}"',
          condition: fields['BUILD_TYPE'] == mode.buildType,
          detail: 'BUILD_TYPE is ${fields['BUILD_TYPE']}',
        );
    }
  });
}
