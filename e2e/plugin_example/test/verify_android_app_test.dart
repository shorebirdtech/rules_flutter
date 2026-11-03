/// Runtime verification: installs the plugin_example APK on an Android
/// emulator/device, launches the activity, and asserts that the app reaches
/// RESUMED state, stays alive, and that the plugins actually resolved —
/// the `plugin_example_results` log line must report a real Android
/// documents path from path_provider (which is jnigen-based as of
/// path_provider_android 2.3 and exercises package:jni's libdartjni.so and
/// Java support classes end to end).
///
/// This test requires a running Android emulator and is tagged "manual"
/// to skip during normal `bazel test //...` runs.
/// Run explicitly: `bazel test :verify_android_app_test --test_tag_filters=`
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:rules_flutter_e2e_testing/adb.dart';

const _packageName = 'com.example.plugin_example';
const _timeout = Duration(seconds: 30);
const _resultsTimeout = Duration(seconds: 60);
const _stabilityWindow = Duration(seconds: 10);

Future<void> main() async {
  final app =
      AdbApp.fromRunfiles('plugin_android.apk', packageName: _packageName)
        ..requireDevice()
        ..install();

  // record_android's library manifest declares RECORD_AUDIO; `pm grant`
  // rejects permissions an app does not declare, so a successful grant
  // proves the plugin's manifest merged into the APK. Granting up front
  // also makes the app's hasPermission probe deterministic (has=true).
  print('Granting RECORD_AUDIO (proves record_android manifest merge)...');
  final grant = app.adb([
    'shell',
    'pm',
    'grant',
    _packageName,
    'android.permission.RECORD_AUDIO',
  ]);
  final grantOutput = '${grant.stdout}${grant.stderr}'.trim();
  if (grant.exitCode != 0 || grantOutput.isNotEmpty) {
    stderr.writeln(
      "FAIL: pm grant RECORD_AUDIO failed — record_android's "
      'manifest did not merge into the APK: $grantOutput',
    );
    exit(1);
  }
  print('RECORD_AUDIO granted');

  // Clear log buffers so crash and results checks only see this run.
  app
    ..clearLogs()
    ..launch();
  await app.waitForResumed(_timeout);

  // Wait for the app's single-line plugin results summary in logcat. This is
  // the dispositive plugin check: it only appears after every plugin call in
  // lib/main.dart resolved. UnsatisfiedLinkError on libdartjni.so aborts
  // plugin registration before any of them can respond.
  print(
    'Waiting for plugin_example_results (up to '
    '${_resultsTimeout.inSeconds}s)...',
  );
  final resultsLine = await app.waitForLogLine(
    'plugin_example_results',
    _resultsTimeout,
  );
  if (resultsLine == null) {
    stderr.writeln(
      'FAIL: plugin_example_results line never appeared in '
      'logcat — plugins did not resolve',
    );
    _dumpRegistrationErrors(app);
    app.stop();
    exit(1);
  }
  print('Results: $resultsLine');

  var resultsOk = true;
  void expectResult(String description, {required bool condition}) {
    if (condition) {
      print('OK: $description');
    } else {
      stderr.writeln('FAIL: $description — got: $resultsLine');
      resultsOk = false;
    }
  }

  // path_provider (jnigen: package:jni + libdartjni.so end to end).
  expectResult(
    'documentsPath is a real Android app-data path',
    condition: resultsLine.contains(
      'documentsPath=/data/user/0/$_packageName/',
    ),
  );
  expectResult(
    'tempPath is a real Android cache path',
    condition: resultsLine.contains(
      'tempPath=/data/user/0/$_packageName/cache',
    ),
  );
  // package_info_plus and the hand-written greeting plugin registered too.
  expectResult(
    'greeting resolved',
    condition: resultsLine.contains('greeting=Hello from GreetingPlugin!'),
  );
  expectResult(
    'appName resolved',
    condition: resultsLine.contains('appName=plugin_example'),
  );
  // url_launcher registered and its MethodChannel responded. `denied` is
  // the correct Android answer here: canLaunchUrl is subject to package
  // visibility, and the app declares no <queries> for https VIEW intents
  // (flutter create output, which plugin_example ships untouched, doesn't
  // include one).
  expectResult(
    'url_launcher channel responded (package visibility denies)',
    condition: resultsLine.contains('launchOk=launch denied'),
  );
  expectResult(
    'audio_session resolved',
    condition: resultsLine.contains('audioSession=audio ok'),
  );
  // record_android registered, its resources compiled, and its
  // MethodChannel responded with the permission granted above.
  expectResult(
    'record_android channel responded with granted permission',
    condition: resultsLine.contains('recordHasPermission=has=true'),
  );
  expectResult(
    'no plugin returned an error',
    condition: !resultsLine.contains('error:'),
  );

  if (!resultsOk) {
    app.stop();
    exit(1);
  }

  final stillResumed = await app.watchStability(_stabilityWindow);

  app
    ..screenshot('plugin_android_screenshot')
    ..stop();

  print('');
  print('=== Results ===');
  print('Activity resumed: yes');
  print('Still resumed after ${_stabilityWindow.inSeconds}s: $stillResumed');
  print('Plugin results verified: yes');

  if (!stillResumed) {
    stderr.writeln('FAIL: Activity crashed or was stopped');
    exit(1);
  }

  print('PASS');
}

/// Dumps plugin-registration failures (e.g. UnsatisfiedLinkError from a
/// missing native library) to aid diagnosis when the results line is absent.
void _dumpRegistrationErrors(AdbApp app) {
  final log = app.adb(['logcat', '-d']).stdout.toString();
  final interesting = log
      .split('\n')
      .where(
        (l) =>
            l.contains('GeneratedPluginsRegister') ||
            l.contains('UnsatisfiedLinkError') ||
            l.contains('flutter'),
      )
      .take(200)
      .join('\n');
  stderr.writeln('--- relevant logcat ---\n$interesting');
}
