/// Runs Gradle on the host app of add_to_app_host/android, with what a
/// `gradle_host_config` (gradle_host.bzl) names: the Gradle distribution, the
/// JDK and the Android SDK from Bazel, and nothing of the machine's.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// What Gradle gets of this process's environment: where to write temporary
/// files, and what Windows needs to start a process. Nothing else, so that no
/// ANDROID_HOME, JAVA_HOME or GRADLE_USER_HOME of the machine's reaches it.
const _passedEnvironment = ['TMPDIR', 'TMP', 'TEMP', 'SystemRoot'];

/// The host app's build variants, one per Flutter build mode.
const hostVariants = ['debug', 'profile', 'release'];

/// A Gradle build of the host app in a directory of its own.
class GradleHost {
  /// Reads the config whose runfiles path [configRunfile] is and copies the
  /// host project into [workDirectory], where Gradle may write.
  factory GradleHost(String configRunfile, Directory workDirectory) {
    final runfiles = Runfiles.create();
    final config = jsonDecode(
      File(runfiles.rlocation(configRunfile)).readAsStringSync(),
    ) as Map<String, Object?>;
    return GradleHost._(config, runfiles, workDirectory).._copyProject();
  }

  GradleHost._(this._config, this._runfiles, this.workDirectory);

  final Map<String, Object?> _config;
  final Runfiles _runfiles;

  /// Where the project, Gradle's user home and the Android user home are.
  final Directory workDirectory;

  /// The copied host project.
  Directory get project => Directory('${workDirectory.path}/project');

  /// Gradle's user home: its caches of downloads and transforms.
  Directory get gradleUserHome => Directory('${workDirectory.path}/gradle');

  String _runfile(String key) => _runfiles.rlocation(_config[key]! as String);

  /// The repositories the build resolves from, as URIs, in the config's order.
  List<String> get repositories => [
    for (final repository in _config['repositories']! as List<Object?>)
      switch (repository) {
        {'url': final String url} => url,
        {'runfile': final String runfile} => Directory(
          _runfiles.rlocation(runfile),
        ).absolute.uri.toString(),
        _ => throw FormatException('unknown repository $repository'),
      },
  ];

  /// The Android SDK: the physical parent of the toolchain's root marker.
  String get _androidSdk =>
      File(_runfile('android_sdk_root')).resolveSymbolicLinksSync().replaceAll(
        RegExp(r'[\\/][^\\/]+$'),
        '',
      );

  void _copyProject() {
    final source = Directory(_runfile('project'));
    for (final entity in source.listSync(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(source.path.length + 1);
      if (relative == 'gradle_repository.json') continue;
      final target = File('${project.path}/$relative')
        ..parent.createSync(recursive: true);
      entity.copySync(target.path);
    }
    File('${project.path}/local.properties').writeAsStringSync(
      'sdk.dir=${_androidSdk.replaceAll(r'\', r'\\')}\n',
    );
  }

  /// Runs Gradle with [arguments] in the project, streaming its output, and
  /// returns its exit code. [offline] passes `--offline`.
  Future<int> run(List<String> arguments, {required bool offline}) async {
    final javaHome = _runfiles.rlocation(_config['java_home']! as String);
    final java = '$javaHome/bin/java${Platform.isWindows ? '.exe' : ''}';
    final androidUserHome = Directory('${workDirectory.path}/.android')
      ..createSync(recursive: true);
    // What the distribution's bin/gradle runs, with its JVM options.
    final process = await Process.start(
      java,
      [
        '-Xmx64m',
        '-Xms64m',
        '-javaagent:${_runfile('gradle_agent')}',
        '-Dorg.gradle.appname=gradle',
        '-jar',
        _runfile('gradle_launcher'),
        '--no-daemon',
        '--project-dir=${project.path}',
        '--gradle-user-home=${gradleUserHome.path}',
        if (offline) '--offline',
        '-PhostRepositories=${repositories.join(',')}',
        ...arguments,
      ],
      environment: {
        for (final key in _passedEnvironment)
          if (Platform.environment.containsKey(key))
            key: Platform.environment[key]!,
        'JAVA_HOME': javaHome,
        // Where the Android Gradle plugin keeps the debug keystore and its
        // settings. Its analytics read only the older ANDROID_PREFS_ROOT, the
        // directory that holds `.android`.
        'ANDROID_USER_HOME': androidUserHome.path,
        'ANDROID_PREFS_ROOT': workDirectory.path,
        'HOME': workDirectory.path,
      },
      includeParentEnvironment: false,
      workingDirectory: project.path,
    );
    await Future.wait([
      stdout.addStream(process.stdout),
      stderr.addStream(process.stderr),
    ]);
    return process.exitCode;
  }

  /// The APK Gradle built for [variant].
  File apk(String variant) {
    final apks = Directory('${project.path}/app/build/outputs/apk/$variant')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.apk'))
        .toList();
    if (apks.length != 1) {
      throw StateError('expected one $variant APK, found $apks');
    }
    return apks.single;
  }
}
