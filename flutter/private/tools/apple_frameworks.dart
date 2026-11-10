/// Assembles Apple frameworks and xcframeworks as directory artifacts.
///
/// Builds `--output` from what it is given, in the order given:
///
/// * `--add <name> <file>` copies `<file>` to `<name>`.
/// * `--add-tree <name> <dir>` copies the contents of `<dir>` into `<name>`,
///   following symlinks.
/// * `--add-bundle <name> <dir>` copies `<dir>`, a framework, an xcframework
///   or a directory holding them, into `<name>`, and gives every versioned
///   framework in it the symlinks a versioned framework has.
/// * `--link-versions <name>` gives the framework at `<name>`, whose contents
///   are already under `Versions/<version>/`, those symlinks.
///
/// A versioned (macOS) framework keeps its contents in `Versions/A/` and has
/// `Versions/Current -> A` and, at its top, a link to each entry of
/// `Versions/Current/` but `_CodeSignature`. A Bazel action sees the
/// directory artifacts it reads with their links followed, so a framework read
/// that way has copies, not links, at those places. `--add-bundle` copies only
/// the version directories and makes the links again, so the bundle it writes
/// has the layout that the framework's signature and Xcode expect.
///
/// The tool has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart apple_frameworks.dart --output <dir>
///       [--add <name> <file> | --add-tree <name> <dir>
///        | --add-bundle <name> <dir> | --link-versions <name>]...
import 'dart:io';

import 'assemble_directory.dart' show copyFile, copyTree;

const _usage =
    'usage: apple_frameworks.dart --output <dir> '
    '[--add <name> <file> | --add-tree <name> <dir> '
    '| --add-bundle <name> <dir> | --link-versions <name>]...';

String _base(String path) =>
    path.split(Platform.pathSeparator).lastWhere((s) => s.isNotEmpty);

/// The version directories of [versions], a framework's `Versions` directory:
/// every entry but `Current`.
List<Directory> _versionDirectories(Directory versions) => [
  for (final entry in versions.listSync(followLinks: true))
    if (entry is Directory && _base(entry.path) != 'Current') entry,
]..sort((a, b) => a.path.compareTo(b.path));

/// Copies [source] into [destination], recreating the links of each versioned
/// framework in it.
void copyBundle(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  final versions = Directory('${source.path}/Versions');
  if (source.path.endsWith('.framework') && versions.existsSync()) {
    for (final version in _versionDirectories(versions)) {
      copyTree(
        version,
        Directory('${destination.path}/Versions/${_base(version.path)}'),
      );
    }
    linkVersions(destination);
    return;
  }
  for (final entry in source.listSync(followLinks: false)) {
    final name = _base(entry.path);
    final target = '${destination.path}/$name';
    switch (FileSystemEntity.typeSync(entry.path)) {
      case FileSystemEntityType.directory:
        copyBundle(Directory(entry.path), Directory(target));
      case FileSystemEntityType.file:
        copyFile(File(entry.path), target);
      case _:
        throw FileSystemException('cannot copy', entry.path);
    }
  }
}

/// Makes the links of the versioned framework [framework], whose contents
/// are under `Versions/<version>/`.
void linkVersions(Directory framework) {
  final versions = Directory('${framework.path}/Versions');
  final found = versions.existsSync()
      ? _versionDirectories(versions)
      : const <Directory>[];
  if (found.length != 1) {
    throw FileSystemException(
      'a versioned framework has one version directory, and this has '
      '${found.length}',
      framework.path,
    );
  }
  final version = _base(found.single.path);
  Link('${versions.path}/Current').createSync(version);
  for (final entry in found.single.listSync(followLinks: false)) {
    final name = _base(entry.path);
    if (name == '_CodeSignature') continue;
    Link('${framework.path}/$name').createSync('Versions/Current/$name');
  }
}

/// Runs the tool over [args] (the command line) and returns the exit code.
///
/// A single argument `@<file>` stands for the arguments in `<file>`, one per
/// line, as Bazel writes a parameter file.
int run(List<String> args) {
  if (args.length == 1 && args.single.startsWith('@')) {
    args = File(args.single.substring(1)).readAsLinesSync();
  }
  String? output;
  final steps = <(String, List<String>)>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--output':
        output = args[++i];
      case '--add' || '--add-tree' || '--add-bundle':
        steps.add((args[i], [args[++i], args[++i]]));
      case '--link-versions':
        steps.add((args[i], [args[++i]]));
      default:
        stderr.writeln('unexpected argument: ${args[i]}\n$_usage');
        return 64;
    }
  }
  if (output == null) {
    stderr.writeln(_usage);
    return 64;
  }
  final root = Directory(output)..createSync(recursive: true);
  String at(String name) => name == '.' ? root.path : '${root.path}/$name';
  for (final (kind, values) in steps) {
    switch (kind) {
      case '--add':
        copyFile(File(values[1]), at(values[0]));
      case '--add-tree':
        copyTree(Directory(values[1]), Directory(at(values[0])));
      case '--add-bundle':
        copyBundle(Directory(values[1]), Directory(at(values[0])));
      case '--link-versions':
        linkVersions(Directory(at(values[0])));
    }
  }
  return 0;
}

void main(List<String> args) {
  exitCode = run(args);
}
