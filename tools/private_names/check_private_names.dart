// Keeps the names of private projects out of this public repository.
//
//   bazel run //tools/private_names:check -- --message <file>   (commit-msg hook)
//   bazel run //tools/private_names:check -- --staged           (pre-commit hook)
//   bazel run //tools/private_names:check -- --tree             (release readiness)
//
// The names are not in the repository, because that would publish them. They
// are in a file, one per line, whose path is the git config value
// `rulesflutter.privateNamesFile` (a leading `~` is expanded):
//
//   git config --global rulesflutter.privateNamesFile ~/.config/rules_flutter/private_names
//
// Without that value the checkout has no private names to keep out, which is
// the case for every contributor but the maintainer: the check says so and
// passes. A value that is set but names a missing, unreadable or empty file
// fails, so a typo cannot turn the check off unseen.
import 'dart:convert';
import 'dart:io';

import 'private_names.dart';

const _configKey = 'rulesflutter.privateNamesFile';

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? null : args[0];
  if (!(mode == '--staged' && args.length == 1) &&
      !(mode == '--tree' && args.length == 1) &&
      !(mode == '--message' && args.length == 2)) {
    stderr.writeln('usage: check (--message <file> | --staged | --tree)');
    exit(2);
  }

  final List<String>? names;
  try {
    names = await _loadNames();
  } on _ConfigError catch (e) {
    stderr.writeln('private names: $e');
    exit(2);
  }
  if (names == null) {
    stderr.writeln(
      'private names: not configured ($_configKey is unset), nothing checked',
    );
    exit(0);
  }

  final hits = switch (mode) {
    '--message' => await _messageHits(args[1], names),
    '--staged' => await _stagedHits(names),
    _ => await _treeHits(names),
  };
  hits.forEach(stderr.writeln);
  if (hits.isNotEmpty) {
    stderr.writeln(
      'private names: ${hits.length} found. This repository is public; '
      'describe the behaviour without naming the project.',
    );
  }
  exit(hits.isEmpty ? 0 : 1);
}

class _ConfigError implements Exception {
  _ConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The names to keep out, or null when the checkout is not configured to.
Future<List<String>?> _loadNames() async {
  final result = await Process.run('git', [
    'config',
    '--get',
    '--type=path',
    _configKey,
  ], workingDirectory: _repo);
  // `git config --get` exits 1 for a key that is not set.
  if (result.exitCode == 1) return null;
  if (result.exitCode != 0) {
    throw _ConfigError('git config $_configKey failed: ${result.stderr}');
  }
  final path = (result.stdout as String).trim();
  if (path.isEmpty) {
    throw _ConfigError('$_configKey is set to an empty path');
  }
  final String contents;
  try {
    contents = File(path).readAsStringSync();
  } on FileSystemException catch (e) {
    throw _ConfigError(
      '$_configKey points at $path, which cannot be read: ${e.message}',
    );
  }
  final names = parseNames(contents);
  if (names.isEmpty) {
    throw _ConfigError('$_configKey points at $path, which lists no names');
  }
  return names;
}

Future<String> _git(List<String> args) async {
  final result = await Process.run(
    'git',
    ['-c', 'core.quotepath=off', ...args],
    workingDirectory: _repo,
    stdoutEncoding: utf8,
  );
  if (result.exitCode != 0) {
    stderr.writeln('git ${args.join(' ')} failed: ${result.stderr}');
    exit(2);
  }
  return result.stdout as String;
}

Future<List<Hit>> _messageHits(String path, List<String> names) async {
  final base = Platform.environment['BUILD_WORKING_DIRECTORY'] ?? _repo;
  final file = File(path).isAbsolute ? File(path) : File('$base/$path');
  return scanCommitMessage(file.readAsStringSync(), names);
}

/// What the commit would add: the paths it adds or renames to, and the lines
/// it adds.
Future<List<Hit>> _stagedHits(List<String> names) async {
  const filter = '--diff-filter=ACMR';
  final paths = (await _git([
    'diff',
    '--cached',
    '--name-only',
    filter,
  ])).split('\n').where((p) => p.isNotEmpty);
  final diff = await _git([
    'diff',
    '--cached',
    '-U0',
    '--no-color',
    '--no-ext-diff',
    filter,
  ]);
  return [
    for (final path in paths) ...scanPath(path, names),
    for (final line in addedLines(diff))
      for (final name in findNames(line.text, names))
        Hit(line.path, line.line, name),
  ];
}

/// Every tracked file's path and contents. Binary files are skipped.
Future<List<Hit>> _treeHits(List<String> names) async {
  final listing = await _git(['ls-files', '-z']);
  final hits = <Hit>[];
  for (final path in listing.split('\x00').where((p) => p.isNotEmpty)) {
    hits.addAll(scanPath(path, names));
    final file = File('$_repo/$path');
    // A symlink or submodule has no contents of its own to read, and a file
    // deleted from the working tree is not part of what a release ships.
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    final bytes = file.readAsBytesSync();
    if (bytes.take(8000).contains(0)) continue;
    hits.addAll(
      scanText(
        utf8.decode(bytes, allowMalformed: true),
        names,
        where: path,
      ),
    );
  }
  return hits;
}
