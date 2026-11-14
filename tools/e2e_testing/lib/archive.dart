/// Unpacking a built `.zip` or `.ipa` to look inside it.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'runfiles_paths.dart';

/// The environment variable a test is told Bazel's zipper by: its runfiles
/// path, which a `dart_test` that extracts with [Extractor.zipper] sets as
///
/// ```
/// data = ["@bazel_tools//tools/zip:zipper", ...],
/// env = {"ZIPPER_RUNFILE": "$(rlocationpath @bazel_tools//tools/zip:zipper)"},
/// ```
const zipperRunfileEnv = 'ZIPPER_RUNFILE';

/// The tool that unpacks an archive.
enum Extractor {
  /// `unzip` from `PATH`. Keeps symlinks, which an app bundle zip has.
  unzip,

  /// `ditto`, which keeps a signed bundle's symlinks and extended attributes
  /// so `codesign` can verify it.
  ditto,

  /// Bazel's zipper, from the test's runfiles: what an archive with no
  /// symlinks (an APK) is unpacked with on any host, Windows included, where
  /// `PATH` has no `unzip`.
  zipper,
}

/// A built archive extracted into a fresh temporary directory.
class ExtractedArchive {
  ExtractedArchive._(this.dir);

  /// Extracts the archive at [workspacePath] in the test's runfiles
  /// (`app.zip`, `ios/app.ipa`). [prefix] names the temporary directory.
  ///
  /// Extracts with [extractor]; `ditto` if [preserveSignature].
  ///
  /// Exits 1 if the archive is missing or extracting fails.
  factory ExtractedArchive.fromRunfiles(
    String workspacePath, {
    String prefix = 'archive_test',
    bool preserveSignature = false,
    Extractor extractor = Extractor.unzip,
  }) => ExtractedArchive.fromPath(
    requireRunfile(workspacePath, what: 'Archive'),
    prefix: prefix,
    preserveSignature: preserveSignature,
    extractor: extractor,
  );

  /// Extracts the archive at [archive], a path the test made or found, as
  /// [ExtractedArchive.fromRunfiles] does.
  factory ExtractedArchive.fromPath(
    String archive, {
    String prefix = 'archive_test',
    bool preserveSignature = false,
    Extractor extractor = Extractor.unzip,
  }) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    final result = switch (preserveSignature ? Extractor.ditto : extractor) {
      Extractor.ditto => Process.runSync('ditto', [
        '-x',
        '-k',
        archive,
        dir.path,
      ]),
      Extractor.unzip => Process.runSync('unzip', [
        '-q',
        archive,
        '-d',
        dir.path,
      ]),
      // zipper extracts into its working directory.
      Extractor.zipper => Process.runSync(_zipperFromRunfiles(), [
        'x',
        File(archive).absolute.path,
      ], workingDirectory: dir.path),
    };
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

/// The zipper at the runfiles path [zipperRunfileEnv] holds. Exits 1 if the
/// test was not given one or nothing is there, naming what to set.
String _zipperFromRunfiles() {
  final rlocationPath = Platform.environment[zipperRunfileEnv];
  if (rlocationPath == null || rlocationPath.isEmpty) {
    stderr.writeln(
      '\$$zipperRunfileEnv is not set: the test target needs '
      '`data = ["@bazel_tools//tools/zip:zipper"]` and '
      '`env = {"$zipperRunfileEnv": '
      '"\$(rlocationpath @bazel_tools//tools/zip:zipper)"}`',
    );
    exit(1);
  }
  final path = Runfiles.create().rlocation(rlocationPath);
  if (!File(path).existsSync()) {
    stderr.writeln('zipper not found at $path (from \$$zipperRunfileEnv)');
    exit(1);
  }
  return path;
}
