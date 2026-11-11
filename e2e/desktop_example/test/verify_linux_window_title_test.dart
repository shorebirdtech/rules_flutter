/// Verifies the built-in runner was compiled with the `window_title` its
/// BUILD target names: the title is a string literal in the runner binary.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/bytes.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

const _title = 'Desktop Example';

void main() {
  final runner = File(
    requireRunfile(
      'linux_bazel_runner_app/linux_bazel_runner_app',
      what: 'Runner binary',
    ),
  );

  final needle = [...utf8.encode(_title), 0];
  if (!containsBytes(runner.readAsBytesSync(), needle)) {
    stderr.writeln('FAIL: runner binary has no "$_title" string');
    exit(1);
  }
  stdout.writeln('OK: runner binary carries the window title "$_title"');
}
