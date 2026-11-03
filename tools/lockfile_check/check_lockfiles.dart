// Checks that every e2e workspace's committed MODULE.bazel.lock is complete.
//
//   bazel run //tools/lockfile_check                       check every workspace
//   bazel run //tools/lockfile_check -- --refresh e2e/smoke  regenerate one lock
//
// Each workspace gets both `bazel mod deps` and `bazel build --nobuild
// //...`, with `--lockfile_mode=error`: they catch different stale locks (the
// first a stale module-graph entry, the second a module extension the lock
// never recorded), and each passes locks the other rejects.
//
// Bazel runs with the workspace's committed `.bazelrc` but not its gitignored
// `.bazelrc.user`, which overrides rules_dart with a sibling checkout and
// turns the lock check off. See `withoutUserRc`.
//
// Analysing `//...` needs every platform's toolchain, so run this on macOS.
import 'dart:io';

import 'lockfile_check.dart';

const _target = '//tools/lockfile_check';

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

Future<void> main(List<String> args) async {
  final workspaces = findWorkspaces(Directory('$_repo/e2e'));
  if (workspaces.isEmpty) {
    stderr.writeln(
      'lockfile check: no workspace with a MODULE.bazel under $_repo/e2e',
    );
    exit(2);
  }

  final refresh = args.isNotEmpty && args.first == '--refresh';
  final named = refresh ? args.skip(1).toList() : args;
  final unknown = named.where((w) => !workspaces.contains(w)).toList();
  if ((refresh && named.isEmpty) || unknown.isNotEmpty) {
    if (unknown.isNotEmpty) {
      stderr.writeln('lockfile check: not a workspace: ${unknown.join(', ')}');
    }
    stderr.writeln('usage: lockfile_check [--refresh] <workspace>...');
    stderr.writeln('workspaces:\n  ${workspaces.join('\n  ')}');
    exit(2);
  }

  final scratch = await Directory.systemTemp.createTemp('lockfile_check');
  try {
    final targets = named.isEmpty ? workspaces : named;
    final failed = <String>[];
    for (final workspace in targets) {
      final runner = _Runner(workspace, scratch);
      if (refresh) {
        stdout.writeln('== $workspace: refreshing');
        if (!await runner.refresh()) {
          exit(1);
        }
      }
      if (!await runner.checkAll(workspace)) failed.add(workspace);
    }
    if (failed.isEmpty) {
      stdout.writeln('lockfile check: ${targets.length} workspace(s) ok');
      return;
    }
    stderr.writeln(
      '\nlockfile check: ${failed.length} of ${targets.length} failed',
    );
    for (final workspace in failed) {
      stderr.writeln('  $workspace');
    }
    stderr.writeln(
      '\nWhere the output above says the lock file is out of date or lacks an '
      'entry, regenerate it:',
    );
    for (final workspace in failed) {
      stderr.writeln('  bazel run $_target -- --refresh $workspace');
    }
    stderr.writeln(
      'Any other error (a missing ANDROID_HOME or ANDROID_NDK_HOME, say) is the '
      'environment, not the lock.',
    );
    exit(1);
  } finally {
    await scratch.delete(recursive: true);
  }
}

/// Runs Bazel in one workspace, without its `.bazelrc.user`.
class _Runner {
  _Runner(String workspace, Directory scratch)
    : dir = '$_repo/$workspace',
      rcFile = _writeRc('$_repo/$workspace', workspace, scratch);

  final String dir;
  final String? rcFile;

  static String? _writeRc(String dir, String workspace, Directory scratch) {
    final committed = File('$dir/.bazelrc');
    if (!committed.existsSync()) return null;
    final copy = File(
      '${scratch.path}/${workspace.replaceAll('/', '_')}.bazelrc',
    );
    copy.writeAsStringSync(withoutUserRc(committed.readAsStringSync()));
    return copy.path;
  }

  Future<ProcessResult> _bazel(List<String> bazelArgs) => Process.run(
    'bazel',
    bazelArgs,
    workingDirectory: dir,
  );

  /// Both lock checks; prints each outcome and returns whether all passed.
  Future<bool> checkAll(String workspace) async {
    var ok = true;
    for (final check in LockCheck.values) {
      final watch = Stopwatch()..start();
      final result = await _bazel(
        bazelArgs(check.args, rcFile: rcFile),
      );
      final seconds = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      if (result.exitCode == 0) {
        stdout.writeln('ok     $workspace: ${check.label} (${seconds}s)');
        continue;
      }
      ok = false;
      stderr.writeln(
        'FAILED $workspace: ${check.label} exited ${result.exitCode}',
      );
      stderr.writeln(_tail('${result.stdout}\n${result.stderr}'));
    }
    return ok;
  }

  /// Regenerates the lock: `mod tidy` settles the module graph but evaluates
  /// only the extensions it needs, and the `update` build forces the rest in.
  Future<bool> refresh() async {
    final steps = [
      ['mod', 'tidy'],
      ['build', '--nobuild', '--keep_going', '//...'],
    ];
    final modes = ['refresh', 'update'];
    for (var i = 0; i < steps.length; i++) {
      final result = await _bazel(
        bazelArgs(steps[i], rcFile: rcFile, lockfileMode: modes[i]),
      );
      if (result.exitCode != 0) {
        stderr.writeln(
          'refresh: bazel ${steps[i].join(' ')} exited ${result.exitCode}',
        );
        stderr.writeln(_tail('${result.stdout}\n${result.stderr}'));
        return false;
      }
    }
    return true;
  }
}

/// The last lines of Bazel's output, where it says what is wrong.
String _tail(String output, {int lines = 25}) {
  final all = output.trimRight().split('\n');
  final kept = all.length <= lines ? all : all.sublist(all.length - lines);
  return kept.map((l) => '    $l').join('\n');
}
