/// Verifies an Android app's `maven_artifacts` target reports the Maven
/// artifacts of the plugins that app depends on and no others.
///
/// `plugin_android` depends on every plugin of pubspec.lock;
/// `package_info_only_android` on `package_info_plus` alone, whose Gradle
/// build declares nothing. The first lists what `shared_preferences_android`,
/// `url_launcher_android` and `audio_session` declare, the second lists none
/// of it. Neither lists an artifact to raise for alignment: the install
/// holds the -ktx companions at the versions their main artifacts' Gradle
/// module metadata asks for.
///
/// The reports read that metadata from `test/gradle_module_metadata.json`,
/// not from maven.google.com, so the test needs no network. After a re-pin
/// that changes a version, the test fails naming what the snapshot lacks:
/// `bazel run //:record_gradle_module_metadata` records it again.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Runs the program whose runfiles path is in `$<envName>_PROGRAM`, as
/// `bazel run` does: with the runfiles path of its report in `$<envName>`,
/// and the metadata snapshot in place of the repositories.
String _run(String envName) {
  final runfiles = Runfiles.create();
  final binary = runfiles.rlocation(
    Platform.environment['${envName}_PROGRAM']!,
  );
  final snapshot = runfiles.rlocation(Platform.environment['SNAPSHOT']!);
  final result = Process.runSync(binary, [
    Platform.environment[envName]!,
    '--metadata=$snapshot',
  ]);
  if (result.exitCode != 0) {
    stderr.writeln('$envName exited ${result.exitCode}\n${result.stderr}');
    exit(1);
  }
  return result.stdout as String;
}

void main() {
  final problems = <String>[];
  final all = _run('ALL_PLUGINS_REPORT');
  final one = _run('ONE_PLUGIN_REPORT');

  for (final (needle, why) in [
    ('androidx.datastore:datastore:', 'a shared_preferences_android artifact'),
    ('androidx.browser:browser:', 'a url_launcher_android artifact'),
    ('androidx.media:media:', 'an audio_session artifact'),
  ]) {
    if (!all.contains(needle)) {
      problems.add('the app that uses every plugin lacks $why:\n$all');
    }
    if (one.contains(needle)) {
      problems.add(
        'the app that uses package_info_plus alone lists $why:\n$one',
      );
    }
  }
  if (all.contains('aligned with')) {
    problems.add(
      'the install resolves artifacts Gradle would raise to align them '
      'with another:\n$all',
    );
  }
  if (!one.contains('# None.')) {
    problems.add(
      'the app that uses package_info_plus alone should need nothing:\n$one',
    );
  }
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n\n'));
    exit(1);
  }
  stdout.writeln('Each app reports the artifacts of its own plugins only.');
}
