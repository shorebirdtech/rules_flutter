/// The program behind `bazel run` of the App Bundle `flutter_android_app`
/// declares: installs the bundle on a device.
///
/// bundletool makes the device's APKs from the bundle (`build-apks
/// --local-testing`), signed with the debug key the bundle's base module was
/// signed with, then installs them (`install-apks`). Every tool comes from the
/// runfiles: the JDK, bundletool with the Kotlin runtime its device commands
/// need, `aapt2` and `adb`.
///
/// Environment:
///   RULES_FLUTTER_ANDROID_BUNDLE_INSTALL_CONFIG  runfiles path of the JSON
///       file the rule writes: `label`, and the runfiles paths `aab`, `aapt2`,
///       `adb`, `java`, `key` and `bundletoolClasspath` (a list).
///   ANDROID_SERIAL  the device to install on, as adb takes it. Unset, the
///       only device connected.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const configEnv = 'RULES_FLUTTER_ANDROID_BUNDLE_INSTALL_CONFIG';

/// bundletool's main class, run from [InstallConfig.bundletoolClasspath].
const bundletoolMain = 'com.android.tools.build.bundletool.BundleToolMain';

/// A failure the user can act on, reported as `error: <message>`.
class InstallException implements Exception {
  InstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the rule tells the program, with every path resolved.
class InstallConfig {
  InstallConfig({
    required this.label,
    required this.aab,
    required this.aapt2,
    required this.adb,
    required this.java,
    required this.key,
    required this.bundletoolClasspath,
  });

  /// Reads the config the rule wrote, resolving its paths with [rlocation].
  factory InstallConfig.fromJson(
    Map<String, Object?> json,
    String Function(String) rlocation,
  ) {
    String plain(String key) {
      final value = json[key];
      if (value is! String) {
        throw InstallException('the install config has no `$key`');
      }
      return value;
    }

    final classpath = json['bundletoolClasspath'];
    if (classpath is! List || classpath.isEmpty) {
      throw InstallException('the install config has no `bundletoolClasspath`');
    }
    return InstallConfig(
      label: plain('label'),
      aab: rlocation(plain('aab')),
      aapt2: rlocation(plain('aapt2')),
      adb: rlocation(plain('adb')),
      java: rlocation(plain('java')),
      key: rlocation(plain('key')),
      bundletoolClasspath: [
        for (final jar in classpath) rlocation(jar as String),
      ],
    );
  }

  final String label;
  final String aab;
  final String aapt2;

  /// Absolute: ddmlib, inside bundletool, starts adb from adb's own directory.
  final String adb;
  final String java;

  /// The debug keystore rules_android signs with.
  final String key;
  final List<String> bundletoolClasspath;
}

List<String> _bundletool(InstallConfig config, String command) => [
  '-cp',
  config.bundletoolClasspath.join(Platform.isWindows ? ';' : ':'),
  bundletoolMain,
  command,
];

List<String> _device(String? serial) =>
    serial == null || serial.isEmpty ? const [] : ['--device-id=$serial'];

/// The `java` arguments that make the device APKs of the bundle in [apks].
List<String> buildApksArgs(InstallConfig config, String apks) => [
  ..._bundletool(config, 'build-apks'),
  '--bundle=${config.aab}',
  '--output=$apks',
  '--overwrite',
  '--aapt2=${config.aapt2}',
  '--local-testing',
  '--ks=${config.key}',
  // rules_android's debug keystore, as its own `bazel run` signs with.
  '--ks-pass=pass:android',
  '--ks-key-alias=androiddebugkey',
  '--key-pass=pass:android',
];

/// The `java` arguments that install [apks] on the device [serial] names, or
/// on the only one connected.
List<String> installApksArgs(
  InstallConfig config,
  String apks,
  String? serial,
) => [
  ..._bundletool(config, 'install-apks'),
  '--adb=${config.adb}',
  '--apks=$apks',
  '--modules=_ALL_',
  ..._device(serial),
];

Future<void> _run(InstallConfig config, List<String> args, String what) async {
  final Process process;
  try {
    process = await Process.start(
      config.java,
      args,
      mode: ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (e) {
    throw InstallException('$what could not start: ${e.message}');
  }
  final code = await process.exitCode;
  if (code != 0) {
    throw InstallException('$what failed (exit $code)');
  }
}

Future<void> main(List<String> args) async {
  try {
    if (args.isNotEmpty) {
      throw InstallException('takes no arguments; got ${args.join(' ')}');
    }
    final configPath = Platform.environment[configEnv];
    if (configPath == null || configPath.isEmpty) {
      throw InstallException(
        'run this through `bazel run` of the App Bundle a flutter_android_app '
        'declares',
      );
    }
    final runfiles = Runfiles.create();
    final file = File(runfiles.rlocation(configPath));
    if (!file.existsSync()) {
      throw InstallException('the install config ${file.path} is missing');
    }
    final config = InstallConfig.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
      runfiles.rlocation,
    );
    final tmp = Directory.systemTemp.createTempSync('flutter_bundle_install');
    try {
      final apks = '${tmp.path}/app.apks';
      await _run(config, buildApksArgs(config, apks), 'bundletool build-apks');
      await _run(
        config,
        installApksArgs(config, apks, Platform.environment['ANDROID_SERIAL']),
        'bundletool install-apks',
      );
    } finally {
      tmp.deleteSync(recursive: true);
    }
    stdout.writeln('Installed ${config.label}.');
  } on InstallException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}
