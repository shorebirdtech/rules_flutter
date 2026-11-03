/// What `check_lockfiles.dart` needs to find the e2e workspaces and to run
/// Bazel in one without the developer's own overrides.
library;

import 'dart:io';

/// The directories under [e2e] that are Bazel workspaces: each holds a
/// `MODULE.bazel`. Found by walking, so a workspace added tomorrow is checked
/// tomorrow, whatever its depth (`e2e/_overlay_tests/*` sit one level down).
///
/// The walk stops at a workspace — its subdirectories are the app's own
/// (`ios/`, `macos/`, `lib/`) and a `MODULE.bazel` there would belong to a
/// vendored dependency, not to the e2e suite — and skips Bazel's `bazel-*`
/// output symlinks and `node_modules`. Paths come back relative to [e2e]'s
/// parent, sorted, with `/` separators.
List<String> findWorkspaces(Directory e2e) {
  final root = e2e.parent.path;
  final found = <String>[];
  void walk(Directory dir) {
    if (File('${dir.path}/MODULE.bazel').existsSync()) {
      found.add(_relative(dir.path, root));
      return;
    }
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (name.startsWith('bazel-') ||
          name.startsWith('.') ||
          name == 'node_modules') {
        continue;
      }
      walk(entry);
    }
  }

  walk(e2e);
  found.sort();
  return found;
}

String _relative(String path, String root) =>
    path.substring(root.length + 1).replaceAll(Platform.pathSeparator, '/');

/// The workspace `.bazelrc` without the line that pulls in the developer's
/// gitignored `.bazelrc.user`.
///
/// That file points `--override_module` at a sibling rules_dart checkout and
/// sets `--lockfile_mode=off`: exactly what a lock check must not see. Bazel
/// has no switch for leaving out one imported file (`--ignore_all_rc_files`
/// also drops the committed `.bazelrc`, whose flags decide what resolves), so
/// the check hands Bazel this copy instead.
String withoutUserRc(String bazelrc) => bazelrc
    .split('\n')
    .where((line) => !_userRcImport.hasMatch(line))
    .join('\n');

final _userRcImport = RegExp(r'^\s*(try-)?import\s+\S*\.bazelrc\.user\s*$');

/// Which of the two lock checks a [LockCheck] is. Each catches stale locks the
/// other passes: `mod deps` the module graph (a stale registry entry), a
/// `--nobuild` build the module extensions (a missing extension result).
enum LockCheck {
  modDeps('bazel mod deps', ['mod', 'deps']),
  analysis('bazel build --nobuild //...', [
    'build',
    '--nobuild',
    '--keep_going',
    '//...',
  ]);

  const LockCheck(this.label, this.args);
  final String label;
  final List<String> args;
}

/// The Bazel arguments to run [args] (a command and its flags) in a
/// workspace whose rc file is [rcFile], if it has one, with the lock file
/// handled as [lockfileMode]: `error` requires it complete and leaves it
/// alone.
///
/// `--noworkspace_rc` stops Bazel reading the workspace's own `.bazelrc`, so
/// that [rcFile], the same file without the `.bazelrc.user` import, is the
/// only one.
List<String> bazelArgs(
  List<String> args, {
  String? rcFile,
  String lockfileMode = 'error',
}) => [
  '--noworkspace_rc',
  if (rcFile != null) '--bazelrc=$rcFile',
  args.first,
  '--lockfile_mode=$lockfileMode',
  '--noshow_progress',
  '--curses=no',
  '--color=no',
  ...args.skip(1),
];
