/// Records, or checks, `test/gradle_module_metadata.json`: the Gradle module
/// metadata of the artifacts `@rules_android_maven` resolves, which
/// `verify_android_maven_artifacts_test` reads in place of maven.google.com.
///
/// Usage: `gradle_module_metadata record|check [--snapshot=SNAPSHOT]
/// (PROGRAM REPORT)...`: the runfiles paths of the snapshot and of each
/// `maven_artifacts` report program and the report it reads.
///
/// `record` runs each `maven_artifacts` report program against the live
/// repositories and writes the metadata they read to the snapshot in the
/// workspace (`bazel run //:record_gradle_module_metadata`). `check` records
/// the same into a scratch file and fails if it differs from the snapshot
/// (`gradle_module_metadata_live_test`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _snapshotPath = 'test/gradle_module_metadata.json';

void _usage() {
  stderr.writeln(
    'usage: gradle_module_metadata record|check [--snapshot=<path>] '
    '(<report program> <report>)...',
  );
  exit(2);
}

/// Runs the report [program] on [report], recording the metadata it reads
/// into [snapshot]. Whether it succeeded.
bool _record(String program, String report, File snapshot) {
  final result = Process.runSync(program, [
    report,
    '--record=${snapshot.path}',
  ]);
  if (result.exitCode == 0) return true;
  stderr.writeln('$program exited ${result.exitCode}\n${result.stderr}');
  return false;
}

/// The lines saying where [recorded] and [snapshot] differ, sorted.
List<String> _differences(
  Map<String, Object?> recorded,
  Map<String, Object?> snapshot,
) {
  String describe(Map<String, Object?> map, String absent, String key) =>
      map.containsKey(key) ? jsonEncode(map[key]) : absent;
  String line(String key) =>
      '  $key: the snapshot has ${describe(snapshot, 'nothing', key)}, the '
      'repositories ${describe(recorded, 'were not asked', key)}';
  return [
    for (final key in {...recorded.keys, ...snapshot.keys})
      if (describe(recorded, '-', key) != describe(snapshot, '-', key))
        line(key),
  ]..sort();
}

void main(List<String> args) {
  if (args.isEmpty || !const ['record', 'check'].contains(args.first)) {
    _usage();
  }
  final mode = args.first;
  final rest = args.skip(1).toList();
  String? snapshotArg;
  if (rest.isNotEmpty && rest.first.startsWith('--snapshot=')) {
    snapshotArg = rest.removeAt(0).substring('--snapshot='.length);
  }
  if (rest.isEmpty ||
      rest.length.isOdd ||
      (mode == 'check') != (snapshotArg != null)) {
    _usage();
  }

  final runfiles = Runfiles.create();
  final scratch = Directory.systemTemp.createTempSync('gradle_metadata');
  try {
    final recorded = File('${scratch.path}/gradle_module_metadata.json');
    for (var i = 0; i < rest.length; i += 2) {
      if (!_record(runfiles.rlocation(rest[i]), rest[i + 1], recorded)) {
        exitCode = 1;
        return;
      }
    }
    if (mode == 'record') {
      final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
      if (workspace == null) {
        stderr.writeln("record writes the workspace's snapshot: bazel run it");
        exitCode = 2;
        return;
      }
      recorded.copySync('$workspace/$_snapshotPath');
      stdout.writeln('Wrote $_snapshotPath.');
      return;
    }
    final snapshot = File(runfiles.rlocation(snapshotArg!));
    final differences = _differences(
      jsonDecode(recorded.readAsStringSync()) as Map<String, Object?>,
      jsonDecode(snapshot.readAsStringSync()) as Map<String, Object?>,
    );
    if (differences.isNotEmpty) {
      stderr.writeln(
        '$_snapshotPath no longer matches the repositories. Record it again '
        'with `bazel run //:record_gradle_module_metadata`:\n'
        '${differences.join('\n')}',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('$_snapshotPath matches the repositories.');
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
