import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Checks the LCOV report `bazel coverage --combined_report=lcov` wrote for
/// `//coverage/...` (the first argument) against the fixture's sources: it
/// covers exactly the sources the other arguments name, by their paths in the
/// workspace, each line of one marked `// covered` has hits and each marked
/// `// uncovered` has none.
void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: check_report <lcov report> <source>...');
    exit(2);
  }
  final report = _parse(File(args.first).readAsLinesSync());
  final expected = args.skip(1).toSet();
  final runfiles = Runfiles.create();
  final problems = <String>[];
  final reported = report.keys.toSet();
  if (reported.length != expected.length || !reported.containsAll(expected)) {
    problems.add(
      'the report covers ${reported.toList()..sort()}, '
      'not ${expected.toList()..sort()}',
    );
  }
  for (final path in expected) {
    final lines = File(runfiles.rlocation('_main/$path')).readAsLinesSync();
    final hits = report[path] ?? const {};
    for (var i = 0; i < lines.length; i++) {
      final line = i + 1;
      final count = hits[line];
      if (lines[i].endsWith('// covered') && (count == null || count == 0)) {
        problems.add('$path:$line is not covered: ${lines[i].trim()}');
      }
      if (lines[i].endsWith('// uncovered') && count != 0) {
        final found = count ?? 'no entry';
        problems.add('$path:$line should be reported uncovered, has $found');
      }
    }
  }
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n'));
    exit(1);
  }
  stdout.writeln('coverage report matches the fixture');
}

/// Hits by line, by source file.
Map<String, Map<int, int>> _parse(List<String> lcov) {
  final report = <String, Map<int, int>>{};
  Map<int, int>? current;
  for (final line in lcov) {
    if (line.startsWith('SF:')) {
      current = report.putIfAbsent(line.substring(3), () => {});
    } else if (line.startsWith('DA:') && current != null) {
      final [number, count, ...] = line.substring(3).split(',');
      current[int.parse(number)] = int.parse(count);
    } else if (line == 'end_of_record') {
      current = null;
    }
  }
  return report;
}
