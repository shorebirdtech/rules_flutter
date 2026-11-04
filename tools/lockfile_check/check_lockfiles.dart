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
// Every `maven.install` in the root and e2e MODULE.bazel files must name a
// `lock_file`, so its jars are fetched by checksum and land in Bazel's
// repository cache. A stale one fails the `--nobuild` build (rules_jvm_external
// compares the lock with the declared artifacts when it loads the repo);
// `--refresh` re-pins it with `bazel run @repo//:pin`, which needs Maven access.
//
// Bazel runs with the workspace's committed `.bazelrc` but not its gitignored
// `.bazelrc.user`, which overrides rules_dart with a sibling checkout and
// turns the lock check off. See `withoutUserRc`.
//
// Analysing `//...` needs every platform's toolchain, so run this on macOS.
import 'dart:io';

import '../e2e_workspaces/e2e_workspaces.dart';
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

  if (!_allMavenInstallsPinned(['.', ...workspaces])) exit(1);

  final scratch = await Directory.systemTemp.createTemp('lockfile_check');
  try {
    final targets = named.isEmpty ? workspaces : named;
    final failed = <String>[];
    // The root's own Maven locks are checked with a full run only.
    final checkRoot = named.isEmpty;
    if (checkRoot) {
      final root = _Runner('.', scratch);
      if (!await root.checkRootMaven() || !await root.checkMavenNoise('.')) {
        failed.add('.');
      }
    }
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
      stdout.writeln(
        'lockfile check: ${targets.length} workspace(s)'
        '${checkRoot ? ' and the root Maven locks' : ''} ok',
      );
      return;
    }
    stderr.writeln(
      '\nlockfile check: ${failed.length} of '
      '${targets.length + (checkRoot ? 1 : 0)} failed',
    );
    for (final workspace in failed) {
      stderr.writeln('  $workspace');
    }
    stderr.writeln(
      '\nWhere the output above says the lock file is out of date or lacks an '
      'entry, or that a *_install.json must be regenerated, regenerate it:',
    );
    for (final workspace in failed) {
      stderr.writeln(
        workspace == '.'
            ? '  REPIN=1 bazel run @<repo>//:pin   (in the repository root; the '
                  'repo is named above)'
            : '  bazel run $_target -- --refresh $workspace',
      );
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

  Future<ProcessResult> _bazel(List<String> bazelArgs) => Process.run(
    'bazel',
    bazelArgs,
    workingDirectory: dir,
  );

  /// Both lock checks; prints each outcome and returns whether all passed.
  Future<bool> checkAll(String workspace) async {
    var ok = true;
    if (!await checkMavenNoise(workspace)) ok = false;
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
      final output = '${result.stdout}\n${result.stderr}';
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
    final names = pinnedMavenInstalls(
      File('$dir/MODULE.bazel').readAsStringSync(),
    );
    if (names.isEmpty) return true;
    await Process.run('bazel', [
      '--noworkspace_rc',
      'shutdown',
    ], workingDirectory: dir);
    final result = await Process.run(
      'bazel',
      bazelArgs(['fetch', '--repo=@${names.first}'], lockfileMode: 'off'),
      workingDirectory: dir,
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

  /// Whether the Maven lock files of the repository root's own `maven.install`
  /// tags are current. Those ship to every user of the ruleset; no e2e
  /// workspace pins them (each pins its own, merged, copy), so a stale one
  /// would reach consumers unseen. Fetching the repo compares the lock with
  /// the declared artifacts and fails when they differ.
  Future<bool> checkRootMaven() async {
    final names = pinnedMavenInstalls(
      File('$dir/MODULE.bazel').readAsStringSync(),
    );
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

  /// Regenerates the locks: `mod tidy` settles the module graph but evaluates
  /// only the extensions it needs, and the `update` build forces the rest in.
  /// That build also fails on a stale rules_jvm_external lock and names the
  /// `@repo//:pin` target that regenerates it; those are run (with `REPIN=1`,
  /// which pins even where the lock still looks current) and the build again.
  Future<bool> refresh() async {
    if (!await _run(['mod', 'tidy'], 'refresh')) return false;
    final pinned = <String>{};
    while (true) {
      final result = await _bazel(
        bazelArgs(_analysis, rcFile: rcFile, lockfileMode: 'update'),
      );
      if (result.exitCode == 0) return true;
      final output = '${result.stdout}\n${result.stderr}';
      final stale = repinTargets(output).where(pinned.add).toList();
      if (stale.isEmpty) {
        stderr.writeln(
          'refresh: bazel ${_analysis.join(' ')} exited ${result.exitCode}',
        );
        stderr.writeln(_tail(output));
        return false;
      }
      for (final target in stale) {
        stdout.writeln('   re-pinning $target');
        if (!await _run(['run', target], 'update', repin: true)) return false;
      }
    }
  }

  static const _analysis = ['build', '--nobuild', '--keep_going', '//...'];

  Future<bool> _run(
    List<String> args,
    String lockfileMode, {
    bool repin = false,
  }) async {
    final result = await Process.run(
      'bazel',
      bazelArgs(args, rcFile: rcFile, lockfileMode: lockfileMode),
      workingDirectory: dir,
      environment: repin ? {'REPIN': '1'} : null,
    );
    if (result.exitCode == 0) return true;
    stderr.writeln(
      'refresh: bazel ${args.join(' ')} exited ${result.exitCode}',
    );
    stderr.writeln(_tail('${result.stdout}\n${result.stderr}'));
    return false;
  }
}

/// The last lines of Bazel's output, where it says what is wrong.
String _tail(String output, {int lines = 25}) {
  final all = output.trimRight().split('\n');
  final kept = all.length <= lines ? all : all.sublist(all.length - lines);
  return kept.map((l) => '    $l').join('\n');
}
