/// Every action and reusable workflow a workflow uses is pinned to a commit.
///
/// A tag can be moved to other code after we reviewed it; a full commit SHA
/// cannot. The trailing comment names the ref the SHA was resolved from, so a
/// reader (and a bump) knows which version it is. Local references
/// (`./.github/...`) are in this repository and need neither.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

final _uses = RegExp(r'^\s*(?:-\s*)?uses:\s*(\S+)(.*)$');
final _pinned = RegExp(r'^[^@\s]+@[0-9a-f]{40}$');
final _refComment = RegExp(r'^\s+# \S+');

/// overhead's shared workflows are bumped together with the `overhead` module
/// by `@overhead//pins:check`, which owns their line format; they need the SHA
/// but no comment.
final _overhead = RegExp(r'^aran/rules_dart/\.github/workflows/overhead-');

void main() {
  final runfiles = Runfiles.create(
    sourceRepository: Platform.environment['RUNFILES_SOURCE_REPO'] ?? '',
  );
  final workflows = Platform.environment['WORKFLOWS']!.split(' ');

  test('the workflows are found', () {
    expect(workflows, hasLength(greaterThan(1)));
  });

  for (final workflow in workflows) {
    test('$workflow pins every non-local uses: to a commit SHA', () {
      final lines = File(runfiles.rlocation(workflow)).readAsLinesSync();
      final problems = <String>[];
      for (final (i, line) in lines.indexed) {
        if (line.trimLeft().startsWith('#')) continue;
        final match = _uses.firstMatch(line);
        if (match == null) {
          // A `uses:` the pattern does not recognise must not slip through.
          if (line.contains('uses:')) {
            problems.add('line ${i + 1}: unrecognised uses: line');
          }
          continue;
        }
        final target = match.group(1)!;
        if (target.startsWith('./')) continue;
        if (!_pinned.hasMatch(target)) {
          problems.add('line ${i + 1}: $target is not pinned to a 40-hex SHA');
        } else if (!_overhead.hasMatch(target) &&
            !_refComment.hasMatch(match.group(2)!)) {
          problems.add('line ${i + 1}: $target has no "# <ref>" comment');
        }
      }
      expect(problems, isEmpty);
    });
  }
}
