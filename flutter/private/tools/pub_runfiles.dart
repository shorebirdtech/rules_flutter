/// Finds files by their runfiles path (`$(rlocationpath ...)`), for the pub
/// runner, which imports only the Dart libraries.
///
/// Where Bazel builds a runfiles tree, a path is under the tree's directory.
/// Where it does not (Windows' default, or `--noenable_runfiles`), the tree is
/// described by a manifest of `<runfiles path> <real path>` lines, and a path
/// is looked up there. A path may also lie under a directory the manifest
/// lists, which the manifest holds as one entry.
library;

import 'dart:io';

/// The runfiles of the running program.
class Runfiles {
  Runfiles._(this._directory, this._manifest);

  /// Runfiles in the tree at [directory].
  Runfiles.inDirectory(String directory) : this._(directory, null);

  /// Runfiles that the text of a manifest describes.
  Runfiles.fromManifest(String text) : this._(null, _parseManifest(text));

  final String? _directory;
  final Map<String, String>? _manifest;

  /// The runfiles the environment or the location of [executable] names, in
  /// the order the Bazel runfiles libraries probe: `RUNFILES_MANIFEST_FILE`,
  /// `RUNFILES_DIR`, then a manifest or tree beside the executable.
  ///
  /// Throws a [StateError] naming what it looked at when there are none.
  factory Runfiles.discover(
    Map<String, String> environment,
    String executable,
  ) {
    final tried = <String>[];
    String? set(String name) {
      final value = environment[name];
      return value == null || value.isEmpty ? null : value;
    }

    for (final manifest in [
      set('RUNFILES_MANIFEST_FILE'),
      '$executable.runfiles_manifest',
      '$executable.exe.runfiles_manifest',
      '$executable.runfiles/MANIFEST',
      '$executable.exe.runfiles/MANIFEST',
    ]) {
      if (manifest == null) continue;
      tried.add(manifest);
      if (File(manifest).existsSync()) {
        return Runfiles.fromManifest(File(manifest).readAsStringSync());
      }
    }
    for (final directory in [
      set('RUNFILES_DIR'),
      '$executable.runfiles',
      '$executable.exe.runfiles',
    ]) {
      if (directory == null) continue;
      tried.add(directory);
      if (Directory(directory).existsSync()) {
        return Runfiles.inDirectory(directory);
      }
    }
    throw StateError(
      'no runfiles: looked at ${tried.join(', ')}. Use `bazel run`.',
    );
  }

  /// The real path of the runfile [path], or null when there is no such file.
  String? rlocation(String path) {
    final manifest = _manifest;
    if (manifest != null) {
      final exact = manifest[path];
      if (exact != null) return exact;

      // A file under a directory the manifest lists as one entry.
      var parent = path;
      while (true) {
        final cut = parent.lastIndexOf('/');
        if (cut < 0) break;
        parent = parent.substring(0, cut);
        final directory = manifest[parent];
        if (directory != null) return '$directory${path.substring(cut)}';
      }
      return null;
    }
    final file = '$_directory/$path';
    return FileSystemEntity.typeSync(file) == FileSystemEntityType.notFound
        ? null
        : file;
  }
}

Map<String, String> _parseManifest(String text) {
  final entries = <String, String>{};
  for (final line in text.split('\n')) {
    final trimmed = line.endsWith('\r')
        ? line.substring(0, line.length - 1)
        : line;
    if (trimmed.isEmpty) continue;
    // A path with a space is written with the escapes Bazel documents: the
    // line starts with a space, and `\s`, `\n` and `\b` stand for a space, a
    // newline and a backslash.
    if (trimmed.startsWith(' ')) {
      final cut = trimmed.indexOf(' ', 1);
      if (cut < 0) continue;
      entries[_unescape(trimmed.substring(1, cut))] = _unescape(
        trimmed.substring(cut + 1),
      );
      continue;
    }
    final cut = trimmed.indexOf(' ');
    if (cut < 0) {
      // A directory with no target is an empty entry, and has no file.
      continue;
    }
    entries[trimmed.substring(0, cut)] = trimmed.substring(cut + 1);
  }
  return entries;
}

String _unescape(String text) =>
    text.replaceAll(r'\s', ' ').replaceAll(r'\n', '\n').replaceAll(r'\b', r'\');
