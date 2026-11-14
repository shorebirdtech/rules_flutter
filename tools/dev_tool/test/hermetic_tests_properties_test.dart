/// Properties of the dev tool's unit tests themselves: what a verdict depends
/// on.
///
/// A unit test's result should depend on the code and on nothing the machine
/// happens to have. Two ways the suite lets it depend on the machine:
///
///   * A test builds its zip fixture by running the host's `zip`. macOS has
///     one, GitHub's Ubuntu image has one, a plain Ubuntu cloud image ships
///     only `unzip`, and Windows has neither; the target declares no
///     `target_compatible_with` and no data, so the failure is a
///     `ProcessException` about a missing binary, in a test about fingerprints.
///   * A test writes a file with a fixed name into the shared system temp
///     directory, so two runs on one machine (a Bazel shard and a bare
///     `dart test`, two agents) write and delete each other's file.
///
/// This reads the suite's own sources, which is a proxy: the property is "the
/// verdict does not depend on the host", and the cheap way to defend it across
/// a suite that other people keep adding files to is to forbid the two spellings
/// that have broken it. The fixtures are meant to be built in process.
///
/// Tagged `runfiles`: it needs the sources in the target's `data`, which Bazel
/// supplies and a bare `dart test` does not.
library;

import 'dart:io';

import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:test/test.dart';

/// Host archivers a unit test must not spawn. Matched as the program argument
/// of a `Process` call, bare or by path.
final _hostArchiver = RegExp(
  r'''Process\.(?:run|runSync|start)\(\s*['"][^'"]*\b(?:zip|unzip|tar|7z|7za)['"]''',
);

/// A file named directly under the system temp directory rather than inside a
/// directory made for the test with `createTemp`.
final _fixedNameInSharedTemp = RegExp(r'systemTemp\.path');

/// Every unit test source in this package, other than this file.
List<File> _unitTestSources() {
  const self = 'hermetic_tests_properties_test.dart';
  final key = 'rules_flutter/tools/dev_tool/test/$self';
  final path = resolveRunfile(key);
  if (path == null) {
    throw StateError(
      'Could not resolve $key from runfiles. This test reads the suite\'s '
      'sources, declared in the target\'s `data`: run it with '
      '`bazel test //tools/dev_tool:hermetic_tests_properties_test`.',
    );
  }
  return [
    for (final entity in File(path).parent.listSync())
      if (entity is File &&
          entity.path.endsWith('.dart') &&
          !entity.path.endsWith(self))
        entity,
  ];
}

/// `file:line` for each line of [files] that [pattern] matches, where the
/// match may start on one line and finish on the next.
List<String> _hits(List<File> files, RegExp pattern) {
  final hits = <String>[];
  for (final file in files) {
    final source = file.readAsStringSync();
    for (final match in pattern.allMatches(source)) {
      final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
      hits.add('${file.uri.pathSegments.last}:$line');
    }
  }
  return hits..sort();
}

void main() {
  group('the unit tests', tags: 'runfiles', () {
    test('there are sources to read', () {
      expect(_unitTestSources(), isNotEmpty);
    });

    test('depend on no host archiver', () {
      expect(
        _hits(_unitTestSources(), _hostArchiver),
        isEmpty,
        reason:
            'these tests spawn a host `zip`/`unzip`/`tar`, which the Bazel '
            'target does not declare and not every host has; build the '
            'fixture in process',
      );
    });

    test('write nothing under a fixed name in the shared temp directory', () {
      expect(
        _hits(_unitTestSources(), _fixedNameInSharedTemp),
        isEmpty,
        reason:
            'a fixed name in the shared temp directory is shared with every '
            'other run on the machine; use a directory made with createTemp',
      );
    });
  });
}
