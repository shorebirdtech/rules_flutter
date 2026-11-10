/// The `BuildConfig` classes in the APKs of `plugin_example`, per build mode:
/// shared by the tests that check what a plugin can observe about the build.
///
/// A plugin reads `BuildConfig.DEBUG`, `BUILD_TYPE` and
/// `LIBRARY_PACKAGE_NAME` of its own package. The classes are read from the
/// dex of an APK of each mode, built from the pub plugins of
/// `plugin_example`: generated for the hub's plugins and written out by hand
/// for the `flutter/ext/` overlays of `package:jni` and `audio_session`.
/// `app_proguard.pro` keeps every `BuildConfig`, which R8 would otherwise
/// inline and drop.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';

/// One build mode: the APK built in it, and what Gradle's `BuildConfig` says
/// in it.
///
/// Flutter's Gradle plugin creates the app's `profile` build type with
/// `initWith(debug)` (FlutterPlugin.kt) and copies the app's build types,
/// `isDebuggable` included, to every plugin project (PluginHandler.kt), so a
/// profile build is debuggable: a plugin's `BuildConfig.DEBUG` is true in it
/// while `BUILD_TYPE` is `profile`.
class AndroidBuildMode {
  const AndroidBuildMode(
    this.label,
    this.apk, {
    required this.debug,
    required this.buildType,
    required this.internet,
    required this.kernelBlob,
  });

  final String label;

  /// The APK's name in the test's runfiles.
  final String apk;

  /// What Gradle gives `BuildConfig.DEBUG` in this mode.
  final bool debug;

  /// What Gradle gives `BuildConfig.BUILD_TYPE` in this mode.
  final String buildType;

  /// Whether the APK declares `android.permission.INTERNET`: the debug and
  /// profile variant manifests do and the release one does not, which tells
  /// profile and release builds apart from the APK alone.
  final bool internet;

  /// Whether the APK carries Dart as a kernel (JIT) rather than as AOT code.
  final bool kernelBlob;
}

/// Debug, profile, and release built two ways.
const androidBuildModes = [
  AndroidBuildMode(
    'debug (-c dbg)',
    'plugin_android_dbg.apk',
    debug: true,
    buildType: 'debug',
    internet: true,
    kernelBlob: true,
  ),
  AndroidBuildMode(
    'profile (-c opt --@rules_flutter//flutter:profile)',
    'plugin_android_profile.apk',
    debug: true,
    buildType: 'profile',
    internet: true,
    kernelBlob: false,
  ),
  AndroidBuildMode(
    'release (default configuration)',
    'plugin_android_arm64.apk',
    debug: false,
    buildType: 'release',
    internet: false,
    kernelBlob: false,
  ),
  AndroidBuildMode(
    'release (-c opt)',
    'plugin_android_opt.apk',
    debug: false,
    buildType: 'release',
    internet: false,
    kernelBlob: false,
  ),
];

/// The packages of the `BuildConfig` classes that rules_flutter provides for
/// the plugins of `plugin_example`, which every APK must hold, one for each
/// way the class is produced.
///
/// The APK holds two more that are not rules_flutter's to set and are left out:
/// the Flutter embedding's own (`io.flutter`, compiled into `flutter.jar` for
/// the engine's mode) and `com.getkeepsafe.relinker`'s (a Maven library,
/// prebuilt in release).
const pluginBuildConfigPackages = {
  'com.github.dart_lang.jni': 'flutter/ext/jni overlay',
  'com.github.dart_lang.jni_flutter': 'generated for a hub plugin',
  'com.ryanheise.audio_session': 'flutter/ext/audio_session overlay',
  'com.llfbandit.record': 'generated for a hub plugin with resources',
  'dev.fluttercommunity.plus.packageinfo': 'generated for a hub plugin',
  'io.flutter.plugins.sharedpreferences':
      'generated for a hub plugin with Maven dependencies',
  'io.flutter.plugins.urllauncher':
      'generated for a hub plugin with Maven dependencies',
};

final _buildConfigDescriptor = RegExp(r'^L(.+)/BuildConfig;$');

/// The constants of the plugins' `BuildConfig` classes in [apk]
/// ([pluginBuildConfigPackages]), keyed by the package the class is in. A
/// plugin whose class is missing is not in the map.
Map<String, Map<String, Object?>> buildConfigs(Apk apk) {
  final configs = <String, Map<String, Object?>>{};
  for (final MapEntry(key: descriptor, value: constants)
      in apk.staticConstants().entries) {
    final match = _buildConfigDescriptor.firstMatch(descriptor);
    if (match == null) continue;
    final package = match.group(1)!.replaceAll('/', '.');
    if (pluginBuildConfigPackages.containsKey(package)) {
      configs[package] = constants;
    }
  }
  return configs;
}

/// Checks that [apk] is a build in [mode], which a transition that failed to
/// apply would not be: it would make every mode agree with the release one.
void checkApkIsOfMode(Apk apk, AndroidBuildMode mode) {
  apk.check
    ..expect(
      '${mode.label}: APK carries ${mode.kernelBlob ? "a kernel" : "AOT code"}',
      condition:
          apk.file('assets/flutter_assets/kernel_blob.bin').existsSync() ==
          mode.kernelBlob,
    )
    ..expect(
      '${mode.label}: INTERNET ${mode.internet ? "declared" : "not declared"}',
      condition:
          apk.fileHasText(
            'AndroidManifest.xml',
            'android.permission.INTERNET',
          ) ==
          mode.internet,
      detail: 'the APK is not a ${mode.label} build',
    );
}

/// Runs [verify] on the APK of each mode, with the `BuildConfig` constants
/// in it by package, all recording to one log so that one run names every
/// problem in every mode. Ends the test with [success] if every check passed.
void verifyEachMode(
  String success,
  void Function(
    Apk apk,
    AndroidBuildMode mode,
    Map<String, Map<String, Object?>> configs,
  )
  verify,
) {
  final check = BundleCheck();
  for (final mode in androidBuildModes) {
    stdout.writeln('\n=== ${mode.label}: ${mode.apk} ===');
    final apk = Apk.fromRunfiles(
      mode.apk,
      prefix: 'plugin_build_config_test',
      check: check,
    );
    try {
      checkApkIsOfMode(apk, mode);
      verify(apk, mode, buildConfigs(apk));
    } finally {
      apk.dispose();
    }
  }
  check.finish(success);
}
