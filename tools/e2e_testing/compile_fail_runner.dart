/// Runs the actions of a build that must fail and passes when they fail as
/// they should.
///
/// The executable of `compile_fail_test` (compile_fail_test.bzl). Its config
/// lists the actions, as their rule registered them: the record of the
/// command line and param files (compile_fail_command.dart), environment,
/// inputs and outputs by exec path. Each action's inputs are in this test's
/// runfiles under its `execroot`, at their exec paths. This links them into a
/// fresh directory at those paths, as Bazel's sandbox does, writes the param
/// files there, makes the directories the outputs go in, and runs the command
/// there with the action's environment alone.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

Future<void> main() async {
  final configPath = Platform.environment['COMPILE_FAIL_CONFIG'];
  if (configPath == null) {
    stderr.writeln('compile_fail_test: COMPILE_FAIL_CONFIG is not set.');
    exit(64);
  }
  final runfiles = Runfiles.create();
  final config = json.decode(
    File(runfiles.rlocation(configPath)).readAsStringSync(),
  ) as Map<String, Object?>;
  final status = await _run(config, runfiles);
  await Future.wait([stdout.flush(), stderr.flush()]);
  exit(status);
}

Future<int> _run(Map<String, Object?> config, Runfiles runfiles) async {
  final expected = (config['outputContains']! as List).cast<String>();
  final scratch =
      Platform.environment['TEST_TMPDIR'] ??
      Directory.systemTemp.createTempSync('compile_fail').path;

  final failures = StringBuffer();
  var failed = 0;
  final actions = (config['actions']! as List).cast<Map<String, Object?>>();
  for (final (index, action) in actions.indexed) {
    final prefix = action['execroot']! as String;
    final execroot = Directory('$scratch/execroot_$index')..createSync();
    for (final input in (action['inputs']! as List).cast<String>()) {
      final link = Link('${execroot.path}/$input');
      link.parent.createSync(recursive: true);
      link.createSync(runfiles.rlocation('$prefix/$input'));
    }
    for (final output
        in (action['outputs']! as List).cast<Map<String, Object?>>()) {
      final path = '${execroot.path}/${output['path']}';
      if (output['directory']! as bool) {
        Directory(path).createSync(recursive: true);
      } else {
        File(path).parent.createSync(recursive: true);
      }
    }
    final command = json.decode(
      File(
        runfiles.rlocation(action['command']! as String),
      ).readAsStringSync(),
    ) as Map<String, Object?>;
    for (final MapEntry(key: path, :value)
        in (command['paramFiles']! as Map<String, Object?>).entries) {
      File('${execroot.path}/$path')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(value! as String);
    }
    final tmp = Directory('$scratch/tmp_$index')..createSync();

    final argv = (command['argv']! as List).cast<String>();
    final mnemonic = action['mnemonic']! as String;
    final result = await Process.run(
      _executable(argv.first, execroot.path),
      argv.skip(1).toList(),
      workingDirectory: execroot.path,
      environment: {
        ...(action['env']! as Map<String, Object?>).cast<String, String>(),
        'TMPDIR': tmp.path,
      },
      includeParentEnvironment: false,
    );
    final output = '${result.stdout}${result.stderr}';
    stdout.writeln(
      'compile_fail_test: $mnemonic exited ${result.exitCode}: '
      '${argv.join(' ')}',
    );
    stdout.writeln(output);
    if (result.exitCode != 0) {
      failed++;
      failures.writeln(output);
    }
  }

  if (failed == 0) {
    stderr.writeln(
      'compile_fail_test: FAIL: every action succeeded, so the '
      'build that must fail now builds.',
    );
    return 1;
  }
  final missing = [
    for (final text in expected)
      if (!failures.toString().contains(text)) text,
  ];
  if (missing.isNotEmpty) {
    stderr.writeln(
      'compile_fail_test: FAIL: $failed of ${actions.length} '
      'actions failed, but not as expected: their output lacks '
      '${missing.map((text) => '"$text"').join(', ')}.',
    );
    return 1;
  }
  stdout.writeln(
    'compile_fail_test: PASS: $failed of ${actions.length} '
    'actions failed, with ${expected.map((t) => '"$t"').join(', ')}.',
  );
  return 0;
}

/// [command] as the action names it: an exec path, relative to [execroot],
/// or a program found on the action's own `PATH`.
String _executable(String command, String execroot) =>
    command.contains('/') && !command.startsWith('/')
    ? '$execroot/$command'
    : command;
