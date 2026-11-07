import 'dart:io';

import 'package:test/test.dart';

import '../android_bundle_install.dart';

InstallConfig _config() => InstallConfig.fromJson({
  'label': '@@//:app_bundle',
  'aab': '_main/app_bundle.aab',
  'aapt2': 'androidsdk/aapt2',
  'adb': 'androidsdk/platform-tools/adb',
  'java': 'remotejdk/bin/java',
  'key': 'rules_android/debug.keystore',
  'bundletoolClasspath': [
    'rules_android/bundletool_deploy.jar',
    'maven/kotlin-stdlib.jar',
  ],
}, (path) => '/runfiles/$path');

void main() {
  test('every path resolves through the runfiles', () {
    final config = _config();
    expect(config.aab, '/runfiles/_main/app_bundle.aab');
    expect(config.adb, '/runfiles/androidsdk/platform-tools/adb');
    expect(config.bundletoolClasspath, [
      '/runfiles/rules_android/bundletool_deploy.jar',
      '/runfiles/maven/kotlin-stdlib.jar',
    ]);
  });

  test('build-apks runs bundletool with the Kotlin runtime, aapt2 and the debug key', () {
    final args = buildApksArgs(_config(), '/tmp/x/app.apks');
    expect(args.take(4), [
      '-cp',
      [
        '/runfiles/rules_android/bundletool_deploy.jar',
        '/runfiles/maven/kotlin-stdlib.jar',
      ].join(Platform.isWindows ? ';' : ':'),
      bundletoolMain,
      'build-apks',
    ]);
    expect(
      args,
      containsAll([
        '--bundle=/runfiles/_main/app_bundle.aab',
        '--output=/tmp/x/app.apks',
        '--aapt2=/runfiles/androidsdk/aapt2',
        '--local-testing',
        '--ks=/runfiles/rules_android/debug.keystore',
        '--ks-key-alias=androiddebugkey',
      ]),
    );
  });

  test(
    "install-apks uses the SDK's adb and the device ANDROID_SERIAL names",
    () {
      final args = installApksArgs(
        _config(),
        '/tmp/x/app.apks',
        'emulator-5554',
      );
      expect(args[3], 'install-apks');
      expect(
        args,
        containsAll([
          '--adb=/runfiles/androidsdk/platform-tools/adb',
          '--apks=/tmp/x/app.apks',
          '--modules=_ALL_',
          '--device-id=emulator-5554',
        ]),
      );
      expect(
        installApksArgs(_config(), '/tmp/x/app.apks', null),
        isNot(contains(startsWith('--device-id'))),
      );
    },
  );

  test('a config without a bundletool classpath is refused', () {
    expect(
      () => InstallConfig.fromJson({'label': 'x'}, (p) => p),
      throwsA(isA<InstallException>()),
    );
  });
}
