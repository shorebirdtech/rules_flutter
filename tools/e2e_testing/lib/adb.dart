/// Installing an APK on a connected Android device and watching it run.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'runfiles_paths.dart';

/// The environment variable a test is told its `adb` by: the runfiles path of
/// the Android SDK's `adb` that Bazel resolved, which a `dart_test` sets as
///
/// ```
/// data = ["@androidsdk//:adb", ...],
/// env = {"ADB_RUNFILE": "$(rlocationpath @androidsdk//:adb)"},
/// ```
const adbRunfileEnv = 'ADB_RUNFILE';

/// An app on a connected emulator or device, driven through `adb`.
///
/// The steps a runtime test takes are install, [launch], [waitForResumed],
/// [watchStability]; what the test then asserts of the app's log is its own.
/// A step that fails prints `FAIL: ...`, stops the app and exits 1.
class AdbApp {
  /// An app with [packageName] whose APK is at [apkPath], driven through the
  /// `adb` at [adbPath].
  AdbApp({
    required this.packageName,
    required this.apkPath,
    required this.adbPath,
    Map<String, String>? environment,
  }) : _environment = environment ?? Platform.environment;

  /// The APK at [workspacePath] in the test's runfiles, driven through the
  /// Android SDK's `adb` that the test's [adbRunfileEnv] names.
  ///
  /// Exits 1 if either is missing.
  factory AdbApp.fromRunfiles(
    String workspacePath, {
    required String packageName,
  }) => AdbApp(
    packageName: packageName,
    apkPath: requireRunfile(workspacePath, what: 'APK'),
    adbPath: _adbFromRunfiles(),
  );

  /// The application id.
  final String packageName;

  /// The APK to install.
  final String apkPath;

  /// The `adb` executable.
  final String adbPath;

  final Map<String, String> _environment;

  String? _serial;

  /// The serial of the device this app is driven on, once [chooseDevice] has
  /// chosen it.
  String? get serial => _serial;

  /// Runs `adb` with [args] on the chosen device ([chooseDevice] first).
  ProcessResult adb(List<String> args) {
    final serial = _serial;
    if (serial == null) {
      throw StateError('adb() before chooseDevice(): no device is chosen');
    }
    return Process.runSync(adbPath, ['-s', serial, ...args]);
  }

  /// Chooses the device to drive, and returns its serial.
  ///
  /// `$ANDROID_SERIAL` names it, as it does for `adb` itself; with none set,
  /// the one attached device is it. Several attached with none named is an
  /// error, because `adb` would refuse each later call with "more than one
  /// device" in the middle of the test. Throws [AdbDeviceChoiceError] naming the
  /// attached devices and how to choose.
  String chooseDevice() {
    final listing = Process.runSync(adbPath, ['devices']);
    if (listing.exitCode != 0) {
      throw AdbDeviceChoiceError(
        '`adb devices` exited ${listing.exitCode}: '
        '${listing.stdout}${listing.stderr}',
      );
    }
    final attached = parseAdbDevices(listing.stdout.toString());
    final ready = attached.where((d) => d.state == 'device').toList();
    final listed = attached.isEmpty
        ? 'none attached'
        : attached.map((d) => '${d.serial} (${d.state})').join(', ');
    final requested = _environment['ANDROID_SERIAL'];
    final String chosen;
    if (requested != null && requested.isNotEmpty) {
      final match = attached.where((d) => d.serial == requested).toList();
      if (match.isEmpty || match.single.state != 'device') {
        throw AdbDeviceChoiceError(
          '\$ANDROID_SERIAL names $requested, which '
          '${match.isEmpty ? 'is not attached' : 'is ${match.single.state}'}; '
          'attached: $listed',
        );
      }
      chosen = requested;
    } else if (ready.isEmpty) {
      throw AdbDeviceChoiceError(
        'No Android device or emulator is ready; attached: $listed',
      );
    } else if (ready.length > 1) {
      throw AdbDeviceChoiceError(
        '${ready.length} Android devices are attached '
        '(${ready.map((d) => d.serial).join(', ')}) and \$ANDROID_SERIAL '
        'does not choose one. Pass it to the test with '
        '`--test_env=ANDROID_SERIAL=<serial>`.',
      );
    } else {
      chosen = ready.single.serial;
    }
    return _serial = chosen;
  }

  /// Chooses the device ([chooseDevice]); exits 1, saying why, if there is none
  /// to choose.
  void requireDevice() {
    try {
      stdout.writeln('Using device ${chooseDevice()}');
    } on AdbDeviceChoiceError catch (e) {
      stderr.writeln(e.message);
      exit(1);
    }
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

/// The `adb` at the runfiles path [adbRunfileEnv] holds. Exits 1 if the test
/// was not given one or nothing is there, naming what to set.
String _adbFromRunfiles() {
  final rlocationPath = Platform.environment[adbRunfileEnv];
  if (rlocationPath == null || rlocationPath.isEmpty) {
    stderr.writeln(
      '\$$adbRunfileEnv is not set: the test target needs '
      '`data = ["@androidsdk//:adb"]` and '
      '`env = {"$adbRunfileEnv": "\$(rlocationpath @androidsdk//:adb)"}`',
    );
    exit(1);
  }
  final path = Runfiles.create().rlocation(rlocationPath);
  if (!File(path).existsSync()) {
    stderr.writeln(
      'adb not found at $path (from \$$adbRunfileEnv=$rlocationPath): the '
      'Android SDK at ANDROID_HOME needs its platform-tools package '
      '(`sdkmanager platform-tools`)',
    );
    exit(1);
  }
  return path;
}

/// Why no device could be chosen.
class AdbDeviceChoiceError implements Exception {
  AdbDeviceChoiceError(this.message);

  /// What went wrong and how to fix it.
  final String message;
}

/// One line of `adb devices`: a serial and the state adb reports it in.
class AdbDevice {
  AdbDevice(this.serial, this.state);

  /// What `-s` and `$ANDROID_SERIAL` name it by.
  final String serial;

  /// `device` when it can be driven; `offline`, `unauthorized` and the like
  /// when it cannot.
  final String state;
}

/// The devices `adb devices` printed [output] lists, in its order.
///
/// Anchored on adb's `List of devices attached` header, because adb prints
/// daemon start-up notes (`* daemon started successfully`) ahead of it.
List<AdbDevice> parseAdbDevices(String output) {
  final lines = output.split('\n').map((l) => l.trimRight()).toList();
  final header = lines.indexWhere((l) => l.startsWith('List of devices'));
  return [
    for (final line in lines.skip(header + 1))
      if (line.contains('\t'))
        AdbDevice(line.split('\t').first, line.split('\t')[1].trim()),
  ];
}
