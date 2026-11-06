// Prints the matrix of the `E2E` jobs in .github/workflows/ci.yaml, as a
// `matrix=<json>` line for $GITHUB_OUTPUT, after checking that the table in
// e2e_matrix.dart accounts for every workspace under e2e/ on every system.
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
  final targetIssues = targetProblems(
    e2eWorkspaces,
    (workspace) => File('$repo/e2e/$workspace/BUILD.bazel').readAsStringSync(),
  );
  if (targetIssues.isNotEmpty) {
    stderr
      ..writeln('ci_matrix: the e2e matrix names targets that are not there:')
      ..writeln(targetIssues.map((p) => '  $p').join('\n'));
    exit(1);
  }
  stdout.writeln(
    'matrix=${jsonEncode({'include': matrixInclude(e2eWorkspaces)})}',
  );
}
