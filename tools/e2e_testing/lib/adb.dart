/// Installing an APK on a connected Android device and watching it run.
library;

import 'dart:io';

import 'runfiles_paths.dart';

/// An app on a connected emulator or device, driven through `adb`.
///
/// The steps a runtime test takes are install, [launch], [waitForResumed],
/// [watchStability]; what the test then asserts of the app's log is its own.
/// A step that fails prints `FAIL: ...`, stops the app and exits 1.
class AdbApp {
  /// An app with [packageName] whose APK is at [apkPath].
  AdbApp({required this.packageName, required this.apkPath});

  /// The APK at [workspacePath] in the test's runfiles.
  ///
  /// Exits 1 if it is missing.
  factory AdbApp.fromRunfiles(
    String workspacePath, {
    required String packageName,
  }) => AdbApp(
    packageName: packageName,
    apkPath: requireRunfile(workspacePath, what: 'APK'),
  );

  /// The application id.
  final String packageName;

  /// The APK to install.
  final String apkPath;

  /// Runs `adb` with [args].
  ProcessResult adb(List<String> args) => Process.runSync('adb', args);

  /// Exits 1 unless `adb` is on the `PATH` and a device is connected.
  void requireDevice() {
    if (Process.runSync('which', ['adb']).exitCode != 0) {
      stderr.writeln('adb not found in PATH');
      exit(1);
    }
    final devices = adb(['devices']).stdout
        .toString()
        .trim()
        .split('\n')
        .where((l) => l.contains('\tdevice'))
        .toList();
    if (devices.isEmpty) {
      stderr.writeln('No Android devices/emulators connected');
      exit(1);
    }
    stdout.writeln('Found ${devices.length} device(s)');
  }

  /// Installs [apkPath], replacing any installed copy.
  void install() {
    stdout.writeln('Installing APK...');
    final result = adb(['install', '-r', apkPath]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to install APK: ${result.stderr}');
      exit(1);
    }
    stdout.writeln('APK installed successfully');
  }

  /// Empties the crash and main log buffers, so a check sees only this run's.
  void clearLogs() {
    adb(['logcat', '-b', 'crash', '-c']);
    adb(['logcat', '-c']);
  }

  /// Force-stops the app.
  void stop() => adb(['shell', 'am', 'force-stop', packageName]);

  /// Stops the app, prints `FAIL: [message]` and exits 1.
  Never fail(String message) {
    stderr.writeln('FAIL: $message');
    stop();
    exit(1);
  }

  /// Starts the app's launcher activity. Exits 1 if it cannot be resolved or
  /// does not start.
  void launch() {
    final resolve = adb([
      'shell',
      'cmd',
      'package',
      'resolve-activity',
      '--brief',
      '-a',
      'android.intent.action.MAIN',
      '-c',
      'android.intent.category.LAUNCHER',
      packageName,
    ]);
    final component = resolve.stdout
        .toString()
        .trim()
        .split('\n')
        .where((l) => l.startsWith('$packageName/'))
        .toList();
    if (resolve.exitCode != 0 || component.isEmpty) {
      stderr.writeln(
        'Failed to resolve launcher activity for $packageName: '
        '${resolve.stdout}${resolve.stderr}',
      );
      exit(1);
    }

    stdout.writeln('Starting activity ${component.single} ...');
    final start = adb(['shell', 'am', 'start', '-n', component.single]);
    final output = '${start.stdout}${start.stderr}';
    if (start.exitCode != 0 || output.contains('Error')) {
      stderr.writeln('Failed to start activity: $output');
      exit(1);
    }
  }

  /// Whether one of the app's activities is the resumed one.
  ///
  /// Matches both `mResumedActivity`/`ResumedActivity:` (older releases) and
  /// `topResumedActivity=` (API 29+).
  bool get isResumed =>
      adb(['shell', 'dumpsys', 'activity', 'activities']).stdout
          .toString()
          .split('\n')
          .any((l) => l.contains('ResumedActivity') && l.contains(packageName));

  /// The crash buffer if it holds an entry for the app, otherwise null.
  String? get crashLog {
    final log = adb(['logcat', '-b', 'crash', '-d']).stdout.toString();
    return log.contains(packageName) ? log : null;
  }

  /// Exits 1, with the crash log, if the app has crashed.
  void failOnCrash(String when) {
    final log = crashLog;
    if (log != null) fail('app crashed $when:\n$log');
  }

  /// Waits up to [timeout] for the app to be resumed, failing at once if it
  /// crashes meanwhile.
  Future<void> waitForResumed(Duration timeout) async {
    stdout.writeln(
      'Waiting for RESUMED state (up to ${timeout.inSeconds}s)...',
    );
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      failOnCrash('before reaching RESUMED');
      if (isResumed) {
        stdout.writeln('Activity is RESUMED');
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    fail('Activity did not reach RESUMED state');
  }

  /// Watches the app for [window], failing at once if it crashes, and returns
  /// whether it was still resumed when the window ended (or when it stopped
  /// being resumed, if sooner).
  Future<bool> watchStability(Duration window) async {
    stdout.writeln('Verifying stability (${window.inSeconds}s)...');
    final end = DateTime.now().add(window);
    var stillResumed = true;
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      failOnCrash('during the stability window');
      stillResumed = isResumed;
      if (!stillResumed) break;
    }
    return stillResumed;
  }

  /// The lines of the device log, optionally only those logged under [tag],
  /// that contain [marker], oldest first.
  List<String> logLines(String marker, {String? tag}) => adb([
    'logcat',
    '-d',
    if (tag != null) ...['-s', tag],
  ]).stdout.toString().split('\n').where((l) => l.contains(marker)).toList();

  /// Waits up to [timeout] for a log line containing [marker] and returns the
  /// last such line, or null if none appears. Fails at once if the app
  /// crashes meanwhile.
  Future<String?> waitForLogLine(String marker, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      failOnCrash('while waiting for "$marker"');
      final lines = logLines(marker);
      if (lines.isNotEmpty) return lines.last;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  /// Saves a screenshot of the device to a new temporary directory named from
  /// [prefix] and returns its path, or null if there is none.
  String? screenshot(String prefix) {
    stdout.writeln('Capturing screenshot...');
    final remote = '/sdcard/$prefix.png';
    adb(['shell', 'screencap', '-p', remote]);
    final local =
        '${Directory.systemTemp.createTempSync(prefix).path}'
        '/screenshot.png';
    adb(['pull', remote, local]);
    adb(['shell', 'rm', remote]);
    if (!File(local).existsSync()) return null;
    stdout.writeln('Screenshot saved to $local');
    return local;
  }
}
