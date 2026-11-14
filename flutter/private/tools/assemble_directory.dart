/// Assembles a directory from trees and files, each placed at a name.
///
/// Builds `--output` from what it is given, in the order given:
///
/// * `--add-tree <name> <dir>` copies the contents of `<dir>`, following
///   symlinks, into `<name>` under `--output` (`.` is `--output` itself).
/// * `--add <name> <file>` copies `<file>` to `<name>`, replacing a file of
///   that name an earlier argument put there.
///
/// Directories in a `<name>` are created. A Bazel tree artifact cannot be
/// extended in place, and an action can only name its contents by running
/// something over them, so this is that something.
///
/// The tool has no package dependencies and runs with the bare Dart SDK, so it
/// runs on any host.
///
/// Usage:
///   dart assemble_directory.dart --output <dir>
///       [--add-tree <name> <dir> | --add <name> <file>]...
import 'dart:io';

/// Copies the contents of [source] into [destination], following symlinks.
void copyTree(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entry in source.listSync(followLinks: false)) {
    final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    final target = '${destination.path}/$name';
    switch (FileSystemEntity.typeSync(entry.path)) {
      case FileSystemEntityType.directory:
        copyTree(Directory(entry.path), Directory(target));
      case FileSystemEntityType.file:
        copyFile(File(entry.path), target);
      case _:
        throw FileSystemException('cannot copy', entry.path);
    }
  }
}

/// Copies [source] to [target], replacing a file already there.
void copyFile(File source, String target) {
  File(target).parent.createSync(recursive: true);
  final existing = File(target);
  if (existing.existsSync()) {
    existing.deleteSync();
  }
  // Resolved first: on Windows, `File.copySync` of a symlink to a file fails
  // with "file not found" instead of copying what it points to.
  File(source.resolveSymbolicLinksSync()).copySync(target);
}

/// Runs the tool over [args] (the command line) and returns the exit code.
int run(List<String> args) {
  String? output;
  // Each step is (isTree, name, source).
  final steps = <(bool, String, String)>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--output':
        output = args[++i];
      case '--add-tree':
        steps.add((true, args[++i], args[++i]));
      case '--add':
        steps.add((false, args[++i], args[++i]));
      default:
        stderr.writeln('unexpected argument: ${args[i]}');
        return 64;
    }
  }
  if (output == null) {
    stderr.writeln(
      'usage: assemble_directory.dart --output <dir> '
      '[--add-tree <name> <dir> | --add <name> <file>]...',
    );
    return 64;
  }
  final destination = Directory(output)..createSync(recursive: true);
  for (final (isTree, name, source) in steps) {
    final target = name == '.' ? destination.path : '${destination.path}/$name';
    if (isTree) {
      copyTree(Directory(source), Directory(target));
    } else {
      copyFile(File(source), target);
    }
  }
  return 0;
}

void main(List<String> args) {
  exitCode = run(args);
}
