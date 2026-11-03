/// Runtime verification: installs APK on Android emulator, launches the
/// activity, and verifies it reaches RESUMED state without crashing.
///
/// This test requires a running Android emulator and is tagged "manual"
/// to skip during normal `bazel test //...` runs.
/// Run explicitly: `bazel test :verify_android_app_test --test_tag_filters=`
///
/// Pass criteria:
/// - APK installs successfully via adb
/// - Activity starts and reaches RESUMED state within 30s
/// - Activity stays resumed with no crash for 10s — long enough to cover
///   androidx.profileinstaller's startup-initializer write, which runs a few
///   seconds after launch and exercises the profileinstaller dependency
///   chain (concurrent-futures, listenablefuture) at runtime
/// - The app logs `android_example shared=2`: one bump through each of two
///   asset ids the app serves from one library moved one count, so both ids
///   reached one loaded image of it (two copies would log `shared=1`)
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:rules_flutter_e2e_testing/adb.dart';

const _packageName = 'com.example.flutterapp';
const _timeout = Duration(seconds: 30);
const _stabilityWindow = Duration(seconds: 10);
const _sharedMarker = 'android_example shared=';

Future<void> main() async {
  final app = AdbApp.fromRunfiles('app.apk', packageName: _packageName)
    ..requireDevice()
    ..install()
    // Clear the crash log buffer so the stability check only sees crashes
    // from this run, and the main buffer so the shared-counter line is this
    // run's.
    ..clearLogs()
    // A previous run's process would keep its count and skip `main`.
    ..stop()
    ..launch();
  await app.waitForResumed(_timeout);

  // Verify the app stays resumed with no crash for the full stability
  // window, polling so a crash fails fast with its log attached.
  final stillResumed = await app.watchStability(_stabilityWindow);

  // `main` logs the count before the first frame, so by now it is there.
  final sharedLines = app.logLines(_sharedMarker, tag: 'flutter');
  final shared = sharedLines.isEmpty
      ? null
      : sharedLines.last.split(_sharedMarker).last.trim();
  print('Shared counter: ${shared ?? '(not logged)'}');

  app
    ..screenshot('android_screenshot')
    ..stop();

  // Report results.
  print('');
  print('=== Results ===');
  print('Activity resumed: yes');
  print('Still resumed after ${_stabilityWindow.inSeconds}s: $stillResumed');

  if (!stillResumed) {
    stderr.writeln('FAIL: Activity crashed or was stopped');
    exit(1);
  }
  if (shared != '2') {
    stderr.writeln(
      'FAIL: expected "${_sharedMarker}2" in logcat, got '
      '${shared == null ? 'no such line' : '"$_sharedMarker$shared"'}: the '
      'two asset ids did not reach one image of the shared library',
    );
    exit(1);
  }

  print('PASS');
}
