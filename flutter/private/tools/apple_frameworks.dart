/// Assembles Apple frameworks and xcframeworks as directory artifacts.
///
/// Builds `--output` from what it is given, in the order given:
///
/// * `--add <name> <file>` copies `<file>` to `<name>`.
/// * `--add-tree <name> <dir>` copies the contents of `<dir>` into `<name>`,
///   following symlinks.
/// * `--add-bundle <name> <dir>` copies `<dir>`, a framework, an xcframework
///   or a directory holding them, into `<name>`, each versioned framework in
///   it as its version directory alone (see below).
/// * `--add-replacing <name> <file> <from> <to>` copies `<file>` to `<name>`
///   with each `<from>` in it replaced by `<to>`.
/// * `--add-interface <name> <file> <module> <rename>` copies the Swift module
///   interface `<file>` to `<name>` as the interface of a framework module
///   `<module>` that has a C-family half: it imports that half, as Xcode's
///   interface of a mixed framework does, and calls `<rename>`, the name the
///   half had when the Swift was compiled, `<module>` (`-` for none).
///
/// A versioned (macOS) framework keeps its contents in `Versions/A/` and has
/// `Versions/Current -> A` and, at its top, a link to each entry of
/// `Versions/Current/` but `_CodeSignature`. Bazel does not keep a link to a
/// directory in a directory artifact: an action reading the artifact sees a
/// copy, and staging it for a test can turn the output into copies. So in
/// Bazel's outputs a versioned framework is its `Versions/<version>/` alone,
/// and [linkVersions] makes the links when the frameworks leave Bazel
/// (`apple_xcframeworks_export.dart`). They are the links the framework had
/// when it was signed, so its signature holds.
///
/// The tool has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart apple_frameworks.dart --output <dir>
///       [--add <name> <file> | --add-tree <name> <dir>
///        | --add-bundle <name> <dir>
///        | --add-replacing <name> <file> <from> <to>
///        | --add-interface <name> <file> <module> <rename>]...
import 'dart:io';

import 'assemble_directory.dart' show copyFile, copyTree;

const _usage =
    'usage: apple_frameworks.dart --output <dir> '
    '[--add <name> <file> | --add-tree <name> <dir> '
    '| --add-bundle <name> <dir> '
    '| --add-replacing <name> <file> <from> <to> '
    '| --add-interface <name> <file> <module> <rename>]...';

String _base(String path) =>
    path.split(Platform.pathSeparator).lastWhere((s) => s.isNotEmpty);

/// The version directories of [versions], a framework's `Versions` directory:
/// every entry but `Current`.
List<Directory> _versionDirectories(Directory versions) => [
  for (final entry in versions.listSync(followLinks: true))
    if (entry is Directory && _base(entry.path) != 'Current') entry,
]..sort((a, b) => a.path.compareTo(b.path));

/// Copies [source] into [destination], each versioned framework in it as its
/// version directory alone, with its links when [link].
void copyBundle(Directory source, Directory destination, {bool link = false}) {
  destination.createSync(recursive: true);
  final versions = Directory('${source.path}/Versions');
  if (source.path.endsWith('.framework') && versions.existsSync()) {
    for (final version in _versionDirectories(versions)) {
      copyTree(
        version,
        Directory('${destination.path}/Versions/${_base(version.path)}'),
      );
    }
    if (link) linkVersions(destination);
    return;
  }
  for (final entry in source.listSync(followLinks: false)) {
    final name = _base(entry.path);
    final target = '${destination.path}/$name';
    switch (FileSystemEntity.typeSync(entry.path)) {
      case FileSystemEntityType.directory:
        copyBundle(Directory(entry.path), Directory(target), link: link);
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

/// The Swift module interface [text] of module [module], made the interface
/// of a framework whose C-family half is module [module] too.
///
/// Its header comments come first, then `@_exported import <module>`, which
/// makes the C-family half visible to the Swift module's importers. A module
/// [rename] the Swift was compiled against, the C-family half under another
/// name, is called [module].
String frameworkInterface(String text, String module, String? rename) {
  if (rename != null) {
    text = text.replaceAll(RegExp('\\b${RegExp.escape(rename)}\\b'), module);
  }
  final lines = text.split('\n');
  final header = lines.takeWhile((l) => l.startsWith('//')).length;
  return [
    ...lines.take(header),
    '@_exported import $module',
    ...lines.skip(header),
  ].join('\n');
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
      case '--add-replacing' || '--add-interface':
        steps.add((args[i], [args[++i], args[++i], args[++i], args[++i]]));
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
      case '--add-replacing':
        final text = File(values[1]).readAsStringSync();
        File(at(values[0]))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text.replaceAll(values[2], values[3]));
      case '--add-interface':
        final text = File(values[1]).readAsStringSync();
        File(at(values[0]))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            frameworkInterface(
              text,
              values[2],
              values[3] == '-' ? null : values[3],
            ),
          );
    }
  }
  return 0;
}

void main(List<String> args) {
  exitCode = run(args);
}
