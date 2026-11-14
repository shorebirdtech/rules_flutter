/// Verifies an Android app carries the plugins it depends on and no others.
///
/// `package_info_only_android` depends on one plugin, `package_info_plus`.
/// pubspec.lock lists many more (`record_android`,
/// `shared_preferences_android`, `url_launcher_android`, `audio_session`,
/// `package:jni`): an app that does not use a plugin has no reason to compile
/// its Java into the APK, to ask for the permission it declares, or to make
/// the user install the Maven artifacts its Gradle build names.
library;

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';

/// The plugin the app uses: its class is registered, so it must be in the dex.
const _used = <String, String>{
  'package:package_info_plus (the plugin the app uses)':
      'Ldev/fluttercommunity/plus/packageinfo/PackageInfoPlugin;',
};

/// Plugins the app does not use, by what ships their class.
const _unused = <String, String>{
  'package:record_android': 'Lcom/llfbandit/record/RecordPlugin;',
  'package:shared_preferences_android':
      'Lio/flutter/plugins/sharedpreferences/SharedPreferencesPlugin;',
  'package:url_launcher_android':
      'Lio/flutter/plugins/urllauncher/UrlLauncherPlugin;',
  'package:audio_session': 'Lcom/ryanheise/audio_session/AudioSessionPlugin;',
  'package:jni': 'Lcom/github/dart_lang/jni/JniPlugin;',
};

void main() {
  // One log across the APKs, so one run names every problem in both. Without
  // R8 each library is dexed on its own, and only the libraries the app
  // depends on may be reachable to be dexed; with it the whole classpath is
  // shrunk together.
  final check = BundleCheck();
  for (final (label, apkName, renames) in [
    ('without R8', 'package_info_only_opt.apk', false),
    ('with R8', 'package_info_only_r8_opt.apk', true),
  ]) {
    final apk = Apk.fromRunfiles(
      apkName,
      prefix: 'plugin_scope_test',
      check: check,
    );
    try {
      _verify(apk, label, renames: renames);
    } finally {
      apk.dispose();
    }
  }
  check.finish('\nEach APK carries the plugin the app uses and no other.');
}

/// [renames]: R8 renames the classes no keep rule names, so the class of the
/// plugin the app uses is looked for by name only without it.
void _verify(Apk apk, String label, {required bool renames}) {
  final check = apk.check;
  final defined = apk.definedClasses();
  check.expect(
    '$label: the dex defines classes',
    condition: defined.isNotEmpty,
    detail: 'no class definitions parsed from dex files',
  );
  if (!renames) {
    _used.forEach((source, descriptor) {
      check.expect(
        '$label: $descriptor is in the dex ($source)',
        condition: defined.contains(descriptor),
        detail: '$source is a dependency of the app but is missing',
      );
    });
  }
  _unused.forEach((source, descriptor) {
    check.expect(
      '$label: $descriptor is not in the dex ($source is not a dependency)',
      condition: !defined.contains(descriptor),
      detail:
          '$source is not a dependency of the app, but its code is in '
          'the APK',
    );
  });

  // record_android's library manifest declares RECORD_AUDIO.
  check.expect(
    '$label: the manifest does not declare RECORD_AUDIO '
    '(package:record_android is not a dependency)',
    condition: !apk.fileHasText(
      'AndroidManifest.xml',
      'android.permission.RECORD_AUDIO',
    ),
    detail:
        "RECORD_AUDIO is in the manifest, from package:record_android's own, "
        'though the app does not use it',
  );
}
