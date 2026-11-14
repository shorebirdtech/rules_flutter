// Checks the Maven lock files of the root and the e2e workspaces: the part of
// lock checking that is rules_flutter's own. `bazel run @overhead//locks:check`
// checks every MODULE.bazel.lock; this checks what that cannot know about
// `rules_jvm_external`.
//
//   bazel run //tools/maven_locks                        check
//   bazel run //tools/maven_locks -- --refresh e2e/smoke  re-pin one workspace
//   bazel run //tools/maven_locks -- --refresh .          re-pin the root's
//
// Every `maven.install` in the root and e2e MODULE.bazel files must name a
// `lock_file`, so its jars are fetched by checksum and land in Bazel's
// repository cache. The root's own locks ship to every consumer of the
// ruleset, which no e2e workspace re-pins, so fetching each root install's
// repo (rules_jvm_external compares the lock with the declared artifacts when
// it loads the repo) is what finds a stale one. Every workspace's installs
// are also evaluated afresh, to print the warnings a lock file lets Bazel
// skip (see `checkMavenNoise`).
//
// `--refresh` re-pins a stale lock with `REPIN=1 bazel run @repo//:pin`, which
// needs Maven access, then
// `bazel run --lockfile_mode=off @overhead//locks:refresh` records what the
// new lock changes in MODULE.bazel.lock.
//
// Bazel runs with the workspace's committed `.bazelrc` but not its gitignored
// `.bazelrc.user`, which overrides rules_dart with a sibling checkout and
// turns the lock check off. See `withoutUserRc`.
import 'dart:io';

import '../e2e_workspaces/e2e_workspaces.dart';
import 'maven_locks.dart';

const _target = '//tools/maven_locks';

final _repo =
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path;

Future<void> main(List<String> args) async {
  final workspaces = ['.', ...findWorkspaces(Directory('$_repo/e2e'))];
  final refresh = args.isNotEmpty && args.first == '--refresh';
  final named = refresh ? args.skip(1).toList() : args;
  final unknown = named.where((w) => !workspaces.contains(w)).toList();
  if ((refresh && named.isEmpty) || unknown.isNotEmpty) {
    if (unknown.isNotEmpty) {
      stderr.writeln('maven locks: not a workspace: ${unknown.join(', ')}');
    }
    stderr.writeln('usage: maven_locks [--refresh <workspace>...]');
    stderr.writeln('workspaces:\n  ${workspaces.join('\n  ')}');
    exit(2);
  }

  if (!_allMavenInstallsPinned(workspaces)) exit(1);

  final scratch = await Directory.systemTemp.createTemp('maven_locks');
  try {
    final targets = named.isEmpty ? workspaces : named;
    final failed = <String>[];
    for (final workspace in targets) {
      final runner = _Runner(workspace, scratch);
      if (refresh) {
        stdout.writeln('== $workspace: re-pinning stale locks');
        if (!await runner.refresh()) exit(1);
      }
      // The root's installs ship to consumers: that is the one fetch check.
      final ok =
          (workspace != '.' || await runner.checkRootMaven()) &&
          await runner.checkMavenNoise(workspace);
      if (!ok) failed.add(workspace);
    }
    if (failed.isEmpty) {
      stdout.writeln('maven locks: ${targets.length} workspace(s) ok');
      return;
    }
    stderr.writeln(
      '\nmaven locks: ${failed.length} of ${targets.length} failed',
    );
    for (final workspace in failed) {
      stderr.writeln('  $workspace');
    }
    stderr.writeln(
      '\nWhere the output above says a *_install.json must be regenerated, '
      're-pin it:',
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

/// Whether every `maven.install` in the MODULE.bazel of each of [dirs]
/// (relative to the repository root) names a `lock_file`; prints each that
/// does not.
bool _allMavenInstallsPinned(List<String> dirs) {
  var ok = true;
  for (final dir in dirs) {
    final module = File('$_repo/$dir/MODULE.bazel');
    if (!module.existsSync()) continue;
    for (final name in unpinnedMavenInstalls(module.readAsStringSync())) {
      ok = false;
      stderr.writeln(
        'FAILED $dir/MODULE.bazel: maven.install(name = "$name") has no '
        'lock_file. Add lock_file = "//:${name}_install.json", create the '
        'file, and run `bazel run @$name//:pin` in $dir.',
      );
    }
  }
  return ok;
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

  Future<ProcessResult> _bazel(
    List<String> bazelArgs, {
    Map<String, String>? environment,
  }) => Process.run(
    'bazel',
    bazelArgs,
    workingDirectory: dir,
    environment: environment,
  );

  List<String> get _installs =>
      pinnedMavenInstalls(File('$dir/MODULE.bazel').readAsStringSync());

  /// Whether evaluating the workspace's `maven.install` tags prints nothing
  /// that says a declaration is wrong or noisy (see [mavenWarnings]).
  ///
  /// A lock file lets Bazel replay the extension's last result, and the
  /// warnings are printed only when it runs, so this evaluates it afresh: on a
  /// new server, with the lock ignored, and with `REPIN=1`, which turns on the
  /// warning for a root version a dependency overrides. Fetching one of the
  /// repositories downloads nothing new when the lock is current. Passes for a
  /// workspace with no pinned install. The workspace's `.bazelrc` is left out
  /// altogether: evaluating an extension reads none of it, and its flags name
  /// settings of rules_flutter, which this must not need to load.
  Future<bool> checkMavenNoise(String workspace) async {
    final names = _installs;
    if (names.isEmpty) return true;
    await Process.run('bazel', [
      '--noworkspace_rc',
      'shutdown',
    ], workingDirectory: dir);
    final result = await _bazel(
      bazelArgs(['fetch', '--repo=@${names.first}'], lockfileMode: 'off'),
      environment: {'REPIN': '1'},
    );
    final output = '${result.stdout}\n${result.stderr}';
    if (result.exitCode != 0) {
      stderr.writeln(
        'FAILED $workspace: bazel fetch --repo=@${names.first} exited '
        '${result.exitCode}',
      );
      stderr.writeln(_tail(output));
      return false;
    }
    final warnings = mavenWarnings(output);
    if (warnings.isEmpty) {
      stdout.writeln('ok     $workspace: no Maven declaration warnings');
      return true;
    }
    stderr.writeln('FAILED $workspace: Maven declarations warn');
    for (final warning in warnings) {
      stderr.writeln('    $warning');
    }
    return false;
  }

  /// Fetches the repo of each of the workspace's pinned installs with the lock
  /// required current, which fails when the lock and the declared artifacts
  /// differ. Returns the outputs of those that failed, empty when all are
  /// current.
  Future<List<String>> _staleOutputs() async {
    final stale = <String>[];
    for (final name in _installs) {
      final result = await _bazel(
        bazelArgs(['fetch', '--repo=@$name'], rcFile: rcFile),
      );
      if (result.exitCode == 0) continue;
      stale.add('${result.stdout}\n${result.stderr}');
    }
    return stale;
  }

  /// Whether the Maven lock files of the repository root's own `maven.install`
  /// tags are current. Those ship to every user of the ruleset, and an e2e
  /// workspace that adds artifacts pins its own merged copy instead, so a
  /// stale one would reach consumers unseen.
  Future<bool> checkRootMaven() async {
    final names = _installs;
    var ok = true;
    for (final name in names) {
      final result = await _bazel(
        bazelArgs(['fetch', '--repo=@$name'], rcFile: rcFile),
      );
      if (result.exitCode == 0) {
        stdout.writeln('ok     .: Maven lock of @$name is current');
        continue;
      }
      ok = false;
      final output = '${result.stdout}\n${result.stderr}';
      stderr.writeln(
        'FAILED .: bazel fetch --repo=@$name exited ${result.exitCode}',
      );
      for (final target in repinTargets(output)) {
        stderr.writeln(
          '    A Maven lock file is stale: the artifacts declared in '
          'MODULE.bazel no longer match it ($target).',
        );
      }
      stderr.writeln(_tail(output));
    }
    return ok;
  }

  /// Re-pins each lock that [_staleOutputs] finds stale, by running the
  /// `@repo//:pin` target Bazel names (with `REPIN=1`, which pins even where
  /// the lock still looks current), then requires every one current.
  Future<bool> refresh() async {
    final targets = {
      for (final output in await _staleOutputs()) ...repinTargets(output),
    };
    for (final target in targets) {
      stdout.writeln('   re-pinning $target');
      final result = await _bazel(
        bazelArgs(['run', target], rcFile: rcFile, lockfileMode: 'update'),
        environment: {'REPIN': '1'},
      );
      if (result.exitCode != 0) {
        stderr.writeln('refresh: bazel run $target exited ${result.exitCode}');
        stderr.writeln(_tail('${result.stdout}\n${result.stderr}'));
        return false;
      }
    }
    final stillStale = await _staleOutputs();
    for (final output in stillStale) {
      stderr.writeln(_tail(output));
    }
    return stillStale.isEmpty;
  }
}

/// The last lines of Bazel's output, where it says what is wrong.
String _tail(String output, {int lines = 25}) {
  final all = output.trimRight().split('\n');
  final kept = all.length <= lines ? all : all.sublist(all.length - lines);
  return kept.map((l) => '    $l').join('\n');
}
