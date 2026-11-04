/// Where a test finds the artifact it inspects.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// The runfiles key of [workspacePath], the form `package:runfiles` resolves.
///
/// `$(rootpaths ...)` writes a file of the workspace's root package as
/// `./name`, and a runfiles library refuses the `.` segment in `_main/./name`.
String runfileKey(String workspacePath) =>
    '_main/${workspacePath.split('/').where((s) => s != '.').join('/')}';

/// The path of [workspacePath] (as `//:app` would put it, `app`) in the test's
/// runfiles, resolved through `package:runfiles` so it also works where
/// runfiles are a manifest and not a tree (Windows CI).
///
/// Exits 1 if nothing is there.
String requireRunfile(String workspacePath, {String what = 'File'}) {
  final path = Runfiles.create().rlocation(runfileKey(workspacePath));
  if (!FileSystemEntity.isDirectorySync(path) && !File(path).existsSync()) {
    stderr.writeln('$what not found at $path');
    exit(1);
  }
  return path;
}
