// Prints the matrix of the `E2E` jobs in .github/workflows/ci.yaml, as a
// `matrix=<json>` line for $GITHUB_OUTPUT, after checking that the table in
// e2e_matrix.dart accounts for every workspace under e2e/ on every system, and
// that .gitattributes leaves every e2e/ entry but `smoke` out of the release
// archive.
//
//   dart run tools/ci_matrix/ci_matrix.dart       from the repository root
//   bazel run //tools/ci_matrix
//
// Exits 1 with the problems on stderr, printing no matrix, when the table and
// the tree disagree.
import 'dart:convert';
import 'dart:io';

import '../e2e_workspaces/e2e_workspaces.dart';
import 'e2e_matrix.dart';

void main() {
  final repo =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  final found = findWorkspaces(Directory('$repo/e2e'));
  if (found.isEmpty) {
    stderr.writeln(
      'ci_matrix: no workspace with a MODULE.bazel under $repo/e2e',
    );
    exit(2);
  }
  final problems = matrixProblems(e2eWorkspaces, found);
  if (problems.isNotEmpty) {
    stderr
      ..writeln('ci_matrix: the e2e matrix does not match e2e/:')
      ..writeln(problems.map((p) => '  $p').join('\n'));
    exit(1);
  }
  final entries = [
    for (final entity in Directory('$repo/e2e').listSync())
      // A hidden entry (`.DS_Store`) is local state git ignores.
      if (!entity.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('.'))
        entity.uri.pathSegments.where((s) => s.isNotEmpty).last +
            (entity is Directory ? '/' : ''),
  ];
  final archiveIssues = archiveProblems(
    entries,
    File('$repo/.gitattributes').readAsStringSync(),
  );
  if (archiveIssues.isNotEmpty) {
    stderr
      ..writeln('ci_matrix: the release archive does not leave out e2e/:')
      ..writeln(archiveIssues.map((p) => '  $p').join('\n'));
    exit(1);
  }
  String buildFile(String workspace) =>
      File('$repo/e2e/$workspace/BUILD.bazel').readAsStringSync();
  final targetIssues = targetProblems(e2eWorkspaces, buildFile);
  if (targetIssues.isNotEmpty) {
    stderr
      ..writeln('ci_matrix: the e2e matrix selects tests that are not there:')
      ..writeln(targetIssues.map((p) => '  $p').join('\n'));
    exit(1);
  }
  stdout.writeln(
    'matrix=${jsonEncode({'include': matrixInclude(e2eWorkspaces, buildFile)})}',
  );
}
