/// Unpacking a built `.zip` or `.ipa` to look inside it.
library;

import 'dart:io';

import 'runfiles_paths.dart';

/// A built archive extracted into a fresh temporary directory.
class ExtractedArchive {
  ExtractedArchive._(this.dir);

  /// Extracts the archive at [workspacePath] in the test's runfiles
  /// (`app.zip`, `ios/app.ipa`). [prefix] names the temporary directory.
  ///
  /// Extracts with `unzip`, or with `ditto` if [preserveSignature]: a signed
  /// bundle's symlinks and extended attributes have to survive for `codesign`
  /// to verify it.
  ///
  /// Exits 1 if the archive is missing or extracting fails.
  factory ExtractedArchive.fromRunfiles(
    String workspacePath, {
    String prefix = 'archive_test',
    bool preserveSignature = false,
  }) {
    final archive = requireRunfile(workspacePath, what: 'Archive');
    final dir = Directory.systemTemp.createTempSync(prefix);
    final result = preserveSignature
        ? Process.runSync('ditto', ['-x', '-k', archive, dir.path])
        : Process.runSync('unzip', ['-q', archive, '-d', dir.path]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to extract $archive: ${result.stderr}');
      dir.deleteSync(recursive: true);
      exit(1);
    }
    return ExtractedArchive._(dir);
  }

  /// The directory the archive was extracted into.
  final Directory dir;

  /// [dir]'s path.
  String get path => dir.path;

  /// Deletes the extracted files. Call it in a `finally`.
  void dispose() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}
