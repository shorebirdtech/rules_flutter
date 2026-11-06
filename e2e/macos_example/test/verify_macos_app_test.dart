/// Runtime verification: launches the macOS .app, checks window dimensions, and
/// checks that both bundled native libraries loaded.
///
/// This test requires a GUI environment (an unlocked screen; it wakes a
/// sleeping display itself) and accessibility permissions, so it
/// uses `tags = ["manual"]` to skip during normal `bazel test //...` runs.
/// Run explicitly: `bazel test :verify_macos_app_test --test_tag_filters=`
///
/// Everything is addressed by the PID this test launched, never by the bundle
/// name: a leftover instance — one an earlier run failed to reap, or a copy
/// launched by hand — would otherwise answer for the bundle under test, and
/// the run would pass without the freshly built binary drawing anything.
/// Launching `Contents/MacOS/<exe>` directly rather than through `open` is
/// part of that: LaunchServices activates an already-running instance of the
/// same bundle id instead of starting ours.
///
/// Pass criteria:
/// - App launches without crashing
/// - Window appears within 30s
/// - Window width > 100 AND height > 100
/// - The app prints `macos_example_native sum=7 difference=3`: `add` from
///   `libadd.dylib` (built at its package root) and `sub` from `libsub.dylib`
///   (built in a subdirectory of its package) both loaded and answered. A
///   window alone does not show this — a library that fails to load throws in
///   `main()` before `runApp`, and the runner still opens its window at full
///   size.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:rules_flutter_e2e_testing/app_process.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';
import 'package:rules_flutter_e2e_testing/macos_gui_session.dart';
import 'package:rules_flutter_e2e_testing/macos_windows.dart';

const _nativeMarker = 'macos_example_native';
const _expectedNative = '$_nativeMarker sum=7 difference=3';

// The version `:app_flutter` declares, and the Flutter release that compiled
// it, as the program reads them from its compile-time defines.
const _versionMarker = 'macos_example_version';
final _expectedVersion = RegExp(
  '$_versionMarker name=2\\.3\\.4 number=42 '
  r'flutter=\d+\.\d+\.\d+ dart=\d+\.\d+\.\d+$',
);

Future<void> main() async {
  final bundle = MacosBundle.fromRunfiles(
    'app.zip',
    appName: 'Flutter App',
    prefix: 'macos_app_test',
  );
  AppProcess? app;
  // A sleeping display makes System Events report no windows, exactly as a
  // missing accessibility grant does, so the test declares the user active
  // (and wakes the display) for its whole run.
  final gui = await GuiSession.hold();
  try {
    await AppWindows.assertEnumerationWorks();

    final launched = app = await AppProcess.start(bundle.runner);
    final windows = AppWindows(launched);

    // A crash exits before any window can appear; waitForWindow reports that
    // rather than spending 30s waiting for a window from a process that is
    // already gone.
    print('Waiting for window (up to 30s) ...');
    if (!await windows.waitForWindow(const Duration(seconds: 30))) {
      stderr.writeln('FAIL: No window found for PID ${launched.pid} after 30s');
      await launched.stop();
      exit(1);
    }
    print('Window found.');

    // Give Flutter a moment to render.
    await Future<void>.delayed(const Duration(seconds: 3));

    final (width, height) = await windows.size();
    print('Window size: $width,$height');

    final processAlive = !launched.exited;
    print('Process alive: $processAlive');

    // `main()` prints this before `runApp`, so it normally arrived before the
    // first frame. Bounded because an app whose library failed to load never
    // reaches the print, and the wait has to end for that to be reported.
    final native =
        await launched.waitForLine(
          _nativeMarker,
          timeout: const Duration(seconds: 10),
        ) ??
        '';

    final version =
        await launched.waitForLine(
          _versionMarker,
          timeout: const Duration(seconds: 10),
        ) ??
        '';

    await launched.stop();

    // Evaluate results.
    final sizeOk = width > 100 && height > 100;
    print('');
    print('=== Results ===');
    print('Window appeared: yes');
    print(
      'Window size: ${width}x$height '
      '(${sizeOk ? "OK" : "FAIL — too small"})',
    );
    print('Process alive: $processAlive');
    print('Native libraries: ${native.isEmpty ? "no report" : native}');

    if (!native.contains(_expectedNative)) {
      stderr.writeln(
        'FAIL: expected the app to print "$_expectedNative" — a bundled '
        'native library did not load or did not answer',
      );
      launched.dumpOutput();
      exit(1);
    }
    print('Version: ${version.isEmpty ? "no report" : version}');
    if (!_expectedVersion.hasMatch(version)) {
      stderr.writeln(
        'FAIL: expected the app to print a line matching $_expectedVersion: '
        'the build did not describe the app and the SDK to the program',
      );
      launched.dumpOutput();
      exit(1);
    }
    if (!sizeOk) {
      stderr.writeln(
        'FAIL: Window size ${width}x$height is too small '
        '(expected > 100x100)',
      );
      exit(1);
    }
    if (!processAlive) {
      stderr.writeln('FAIL: Process crashed before verification completed');
      exit(1);
    }

    print('PASS');
  } finally {
    await app?.stop();
    bundle.dispose();
    await gui.release();
  }
}
