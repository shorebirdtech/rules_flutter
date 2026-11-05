/// Runs a test that is meant to fail, or to run only some of its cases, and
/// passes when it does what the target says it must.
///
/// The executable of `outcome_test`: it starts the wrapped test's own
/// executable, with the environment its rule gave it, and checks how it ended
/// (its exit status), what it reported (the cases in its JUnit file, which of
/// them failed) and what it said. So a test that must fail is a passing target
/// only while it fails the way it should, and a target that is not allowed to
/// hide a gap is not hiding one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

Future<void> main() async {
  final configPath = Platform.environment['TEST_OUTCOME_CONFIG'];
  if (configPath == null) {
    stderr.writeln('test_outcome: TEST_OUTCOME_CONFIG is not set.');
    exit(64);
  }
  final runfiles = Runfiles.create();
  final config = json.decode(
    File(runfiles.rlocation(configPath)).readAsStringSync(),
  ) as Map<String, Object?>;

  final report = Directory.systemTemp.createTempSync('test_outcome');
  final xml = File('${report.path}/report.xml');
  final output = StringBuffer();
  try {
    final environment = <String, String>{
      ...Platform.environment,
      ...(config['env']! as Map<String, Object?>).cast<String, String>(),
      'XML_OUTPUT_FILE': xml.path,
    };
    final filter = config['testFilter'] as String?;
    if (filter == null) {
      environment.remove('TESTBRIDGE_TEST_ONLY');
    } else {
      environment['TESTBRIDGE_TEST_ONLY'] = filter;
    }

    final process = await Process.start(
      runfiles.rlocation(config['executable']! as String),
      const [],
      environment: environment,
    );
    final pumps = [
      process.stdout.transform(utf8.decoder).forEach((text) {
        output.write(text);
        stdout.write(text);
      }),
      process.stderr.transform(utf8.decoder).forEach((text) {
        output.write(text);
        stderr.write(text);
      }),
    ];
    final exitCode = await process.exitCode;
    await Future.wait(pumps);

    final problems = _check(
      config,
      exitCode: exitCode,
      xml: xml.existsSync() ? xml.readAsStringSync() : null,
      output: output.toString(),
    );
    final named = config['noSimulatorNamed'] as String?;
    // The runner names its simulator for its own process: another run of the
    // same test, at the same time, has simulators of its own.
    if (named != null) {
      problems.addAll(await _simulatorsLeft('$named${process.pid}'));
    }
    if (problems.isEmpty) {
      stdout.writeln('test_outcome: the test ended as it should have.');
      return;
    }
    stderr
      ..writeln('test_outcome: the test did not end as it should have:')
      ..writeln(problems.map((p) => '  - $p').join('\n'));
    exit(1);
  } finally {
    report.deleteSync(recursive: true);
  }
}

/// What differs between how the test ended and [config]'s expectation.
List<String> _check(
  Map<String, Object?> config, {
  required int exitCode,
  required String? xml,
  required String output,
}) {
  final problems = <String>[];
  final shouldPass = config['expect'] == 'pass';
  if (shouldPass && exitCode != 0) {
    problems.add('it should have passed and exited with $exitCode');
  }
  if (!shouldPass && exitCode == 0) {
    problems.add('it should have failed and exited with 0');
  }

  final expectedCases = (config['cases'] as List<Object?>?)?.cast<String>();
  final failingCases = (config['failingCases'] as List<Object?>?)
      ?.cast<String>();
  if (expectedCases != null || failingCases != null) {
    if (xml == null) {
      problems.add('it wrote no JUnit report (XML_OUTPUT_FILE)');
    } else {
      final cases = _cases(xml);
      if (expectedCases != null &&
          json.encode(cases.map((c) => c.name).toList()) !=
              json.encode(expectedCases)) {
        problems.add(
          'the report holds cases ${cases.map((c) => c.name).toList()}, '
          'expected $expectedCases',
        );
      }
      if (failingCases != null) {
        final failed = [
          for (final c in cases)
            if (c.failed) c.name,
        ];
        if (json.encode(failed) != json.encode(failingCases)) {
          problems.add(
            'the cases that failed are $failed, expected $failingCases',
          );
        }
      }
    }
  }

  for (final text
      in (config['outputContains'] as List<Object?>? ?? const [])
          .cast<String>()) {
    if (!output.contains(text)) {
      problems.add('its output does not contain "$text"');
    }
  }
  return problems;
}

/// The simulators `simctl list` shows that are called [name]: what the
/// test left behind, which it must not however it ended.
Future<List<String>> _simulatorsLeft(String name) async {
  final result = await Process.run('xcrun', ['simctl', 'list', 'devices']);
  if (result.exitCode != 0) {
    return [
      '`xcrun simctl list devices` exited ${result.exitCode}: ${result.stderr}',
    ];
  }
  return [
    for (final line in const LineSplitter().convert('${result.stdout}'))
      if (line.trim().startsWith('$name '))
        'it left the simulator ${line.trim()}',
  ];
}

/// The cases of a JUnit report, in order, each with whether it failed.
List<({String name, bool failed})> _cases(String xml) {
  final cases = <({String name, bool failed})>[];
  final open = RegExp('<testcase name="([^"]*)"[^>]*?(/>|>)');
  for (final match in open.allMatches(xml)) {
    final name = (match.group(1) ?? '')
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
    var failed = false;
    if (match.group(2) == '>') {
      final end = xml.indexOf('</testcase>', match.end);
      final body = xml.substring(match.end, end < 0 ? xml.length : end);
      failed = body.contains('<failure') || body.contains('<error');
    }
    cases.add((name: name, failed: failed));
  }
  return cases;
}
