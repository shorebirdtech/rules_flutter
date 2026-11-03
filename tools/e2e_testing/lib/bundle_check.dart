/// The pass/fail log of a test that inspects a built artifact.
library;

import 'dart:io';

/// Runs checks against a built bundle and keeps going after a failure, so one
/// run names every problem rather than the first.
///
/// Each check prints `OK: ...` to stdout or `FAIL: ...` to stderr. Nothing is
/// thrown: [finish] ends the test, and fails it if any check did.
class BundleCheck {
  /// Starts an empty log. [out], [err] and [exit] default to the process's
  /// stdout, stderr and `exit`; a unit test passes its own.
  BundleCheck({StringSink? out, StringSink? err, void Function(int)? exit})
    : _out = out ?? stdout,
      _err = err ?? stderr,
      _exit = exit ?? _exitProcess;

  final StringSink _out;
  final StringSink _err;
  final void Function(int) _exit;

  /// The message of every failed check, in order.
  final List<String> failures = [];

  /// Whether every check so far passed.
  bool get ok => failures.isEmpty;

  /// Records a passing check.
  void pass(String message) => _out.writeln('OK: $message');

  /// Records a failing check.
  void fail(String message) {
    failures.add(message);
    _err.writeln('FAIL: $message');
  }

  /// Passes if [condition] holds; otherwise fails, adding [detail] when given.
  void expect(String description, {required bool condition, String? detail}) {
    if (condition) {
      pass(description);
    } else {
      fail(detail == null ? description : '$description — $detail');
    }
  }

  /// Passes if a file or directory exists at [path]. With [nonEmpty], a file
  /// of no bytes fails.
  void exists(String description, String path, {bool nonEmpty = false}) {
    final isDir = FileSystemEntity.isDirectorySync(path);
    final file = File(path);
    if (!isDir && !file.existsSync()) {
      fail('$description — not found: $path');
    } else if (nonEmpty && !isDir && file.lengthSync() == 0) {
      fail('$description — file is empty: $path');
    } else {
      pass(isDir ? description : '$description (${file.lengthSync()} bytes)');
    }
  }

  /// Passes if nothing exists at [path]. [subject] says what must be absent,
  /// as in "replaced code asset libcounter_a.so".
  void absent(String subject, String path) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
      pass('$subject is absent');
    } else {
      fail('$subject is present: $path');
    }
  }

  /// Passes if [executable] with [args] exits 0 and [validate] accepts its
  /// trimmed stdout.
  void command(
    String description,
    String executable,
    List<String> args,
    bool Function(String stdout) validate,
  ) {
    final result = Process.runSync(executable, args);
    if (result.exitCode != 0) {
      fail(
        '$description — command failed: $executable ${args.join(' ')}\n'
        '  stderr: ${result.stderr}',
      );
      return;
    }
    final output = result.stdout.toString().trim();
    if (validate(output)) {
      pass(description);
    } else {
      fail('$description — unexpected output: $output');
    }
  }

  /// Ends the test. If every check passed, prints [success]. Otherwise runs
  /// [onFailure] (to list what the bundle held) and exits 1.
  void finish(String success, {void Function()? onFailure}) {
    if (ok) {
      _out.writeln(success);
      return;
    }
    onFailure?.call();
    _exit(1);
  }

  /// Writes the tree under [dir] to stderr, one entry a line, indented by
  /// depth, with the size of each file. [descend] says whether to look inside
  /// a directory; the default looks inside all of them.
  void listTree(Directory dir, {bool Function(Directory)? descend}) {
    _listTree(dir, '', descend ?? (_) => true);
  }

  void _listTree(
    Directory dir,
    String indent,
    bool Function(Directory) descend,
  ) {
    if (!dir.existsSync()) return;
    final entries = dir.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final name = entry.path.split(RegExp(r'[\\/]')).last;
      if (entry is Directory) {
        _err.writeln('$indent$name/');
        if (descend(entry)) _listTree(entry, '$indent  ', descend);
      } else if (entry is File) {
        _err.writeln('$indent$name (${entry.lengthSync()} bytes)');
      } else {
        _err.writeln('$indent$name');
      }
    }
  }
}

void _exitProcess(int code) => exit(code);
