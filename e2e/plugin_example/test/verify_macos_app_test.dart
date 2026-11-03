/// Runtime verification: launches the macOS .app produced by :plugin_macos
/// and asserts the four plugin-result strings appear in its stdout.
///
/// The four strings come from `lib/main.dart`'s FutureBuilder:
///   * `appName` from `PackageInfo.fromPlatform()`
///   * `documentsPath` from `getApplicationDocumentsDirectory()`
///   * `tempPath` from `getTemporaryDirectory()`
///   * `launchOk` from `canLaunchUrl(...)`
///
/// Empty/null/error content fails this test loudly.
///
/// Tagged "manual" + "exclusive" so it doesn't run in default `bazel test`
/// invocations — it requires a GUI session and accessibility-style behaviors
/// (the app launches a window and writes to its own stdout).
/// Run explicitly:
///   bazel test :verify_macos_app_test --test_tag_filters= \
///     --strategy=TestRunner=standalone
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:rules_flutter_e2e_testing/app_process.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

const _summaryMarker = 'plugin_example_results';

Future<void> main() async {
  final bundle = MacosBundle.fromRunfiles(
    'plugin_macos.zip',
    appName: 'plugin_macos',
    prefix: 'plugin_macos_test',
  );
  AppProcess? app;
  try {
    final launched = app = await AppProcess.start(bundle.runner, mirror: true);

    final summary = await launched.waitForLine(
      _summaryMarker,
      timeout: const Duration(seconds: 30),
    );

    await launched.stop();

    if (summary == null) {
      stderr
        ..writeln('FAIL: $_summaryMarker line not seen within 30s')
        ..writeln('--- captured output ---')
        ..writeln(launched.output);
      exit(1);
    }

    print('Got summary: $summary');

    final fails = <String>[];
    if (!summary.contains('appName=Plugin Example')) {
      fails.add('appName is not "Plugin Example"');
    }
    if (!RegExp('documentsPath=/Users/').hasMatch(summary)) {
      fails.add('documentsPath does not start with /Users/');
    }
    if (!RegExp('tempPath=/').hasMatch(summary)) {
      fails.add('tempPath is not an absolute path');
    }
    if (!summary.contains('launchOk=launch ok')) {
      fails.add('launchOk is not "launch ok"');
    }
    if (!summary.contains('prefs=roundtrip ok')) {
      fails.add('prefs is not "roundtrip ok"');
    }
    if (!summary.contains('greeting=Hello from GreetingPlugin!')) {
      fails.add('greeting (regression case) did not register');
    }
    // audio_session uses the SwiftPM-canonical
    // Sources/<pkg>/include/<pkg>/Foo.h public-header layout — exercises
    // the include-path wiring in flutter_apple_plugin_library / the
    // SwiftPM include auto-detection in flutter_pub_package.
    if (!summary.contains('audioSession=audio ok')) {
      fails.add('audioSession is not "audio ok"');
    }

    if (fails.isNotEmpty) {
      stderr.writeln('FAIL:');
      for (final f in fails) {
        stderr.writeln('  - $f');
      }
      stderr.writeln('summary line was: $summary');
      exit(1);
    }

    print('PASS');
  } finally {
    await app?.stop();
    bundle.dispose();
  }
}
