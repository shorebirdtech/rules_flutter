/// Runs the rules_flutter e2e suites on a remote VM over SSH.
///
/// Usage:
///   dart run tools/vm/run_e2e.dart <vm-name> [--windows] \
///       [--folders=.,e2e/hello_world] [--keep-going] \
///       [--rules-dart=../rules_dart]
///
/// Transfers the committed working tree to the VM, extracts it, then runs
/// in each folder what `.github/workflows/ci.yaml` runs there, which
/// `tools/ci_matrix/e2e_matrix.dart` says: the workspaces that run on the VM's
/// system, each with its Bazel command and targets (`bazel test //...` for most).
/// With `--rules-dart`, that checkout's committed HEAD goes over too and every
/// folder builds against it (`--override_module`, for rules_dart and, in the
/// root, its `overhead`), as a local `.bazelrc.user` does; without it, the
/// pinned release. Exit code 4
/// ("no test targets") counts as a pass. Prints a per-folder PASS/FAIL summary
/// and exits non-zero if any folder failed.
///
/// On Windows each folder gets a short `--output_base` (`C:/b/<n>`) so deeply
/// nested runfiles (e.g. the hermetic Python interpreter's `_socket.pyd`) and
/// the paths aapt2 reads stay under the 260-char MAX_PATH limit, as the Windows
/// CI job's `output-base` does. (`--output_user_root` would add a hash
/// directory; docs/TESTING.md, "Windows and MAX_PATH".)
library;

import 'dart:async';
import 'dart:io';

import '../ci_matrix/e2e_matrix.dart';
import 'gcloud.dart';

/// What to run in one folder: the Bazel [command] on [targets].
class _Folder {
  const _Folder(this.path, {this.command = 'test', this.targets = '//...'});

  /// The repository-relative path; `.` is the root module (Starlark unit
  /// tests).
  final String path;
  final String command;
  final String targets;
}

/// The default folders: the root module, then every workspace the e2e matrix
/// (`tools/ci_matrix/e2e_matrix.dart`, the one table the `e2e` job in
/// `.github/workflows/ci.yaml` is built from) runs on [os], each with the
/// command and targets CI gives it there. Override with `--folders=` to scope a
/// run.
List<_Folder> _ciFolders(Os os, String repoRoot) => [
  const _Folder('.'),
  for (final workspace in e2eWorkspaces)
    if (workspace.runs.containsKey(os)) _matrixFolder(workspace, os, repoRoot),
];

_Folder _matrixFolder(E2eWorkspace workspace, Os os, String repoRoot) {
  final build = File('$repoRoot/e2e/${workspace.name}/BUILD.bazel');
  return _Folder(
    'e2e/${workspace.name}',
    command: workspace.commandOn(os),
    targets: workspace
        .targetsOn(os, build.existsSync() ? build.readAsStringSync() : '')
        .join(' '),
  );
}

/// The folder a `--folders=` entry names: the matrix's command and targets
/// when it is a workspace that runs on [os], and `bazel test //...` otherwise.
_Folder _namedFolder(String path, Os os, String repoRoot) {
  for (final workspace in e2eWorkspaces) {
    if (path == 'e2e/${workspace.name}' && workspace.runs.containsKey(os)) {
      return _matrixFolder(workspace, os, repoRoot);
    }
  }
  return _Folder(path);
}

/// Per-folder timeout. The first folder pays for the hermetic Flutter SDK +
/// engine download; later folders re-fetch (separate output bases).
const _folderTimeout = Duration(minutes: 30);

/// Short Windows output bases, one per folder (a Bazel output base serves one
/// workspace) — keeps generated paths under MAX_PATH (260).
const _winOutputRoot = 'C:/b';

class _FolderResult {
  _FolderResult(this.folder, this.exitCode, this.pass, this.tail);
  final String folder;
  final int exitCode;
  final bool pass;
  final String tail;
}

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: dart run tools/vm/run_e2e.dart <vm-name> [--windows] '
      '[--folders=a,b,c] [--keep-going]',
    );
    exit(2);
  }
  final vmName = positional.first;
  final isWindows = args.contains('--windows');
  final keepGoing = args.contains('--keep-going');
  final foldersArg = args
      .firstWhere((a) => a.startsWith('--folders='), orElse: () => '')
      .replaceFirst('--folders=', '');
  final rulesDartArg = args
      .firstWhere((a) => a.startsWith('--rules-dart='), orElse: () => '')
      .replaceFirst('--rules-dart=', '');
  final repoRoot = _repoRoot();
  final os = isWindows ? Os.windows : Os.linux;
  final folders = foldersArg.isEmpty
      ? _ciFolders(os, repoRoot)
      : [
          for (final path in foldersArg.split(','))
            _namedFolder(path.trim(), os, repoRoot),
        ];
  _warnIfDirty(repoRoot);

  // 1. Package the committed tree.
  //
  // Deliberately not `git archive`: it honours `export-ignore`, and
  // `.gitattributes` marks `e2e/` as one so release tarballs stay small. An
  // archive built that way arrives on the VM with every workspace this tool
  // exists to run stripped out, and the run fails on a missing directory.
  // `git ls-files` names the same committed tree without consulting
  // export-ignore.
  final tgz = '${Directory.systemTemp.path}/rules_flutter_src.tgz';
  print('Packaging committed HEAD -> $tgz');
  final listing = File('${Directory.systemTemp.path}/rules_flutter_files.txt');
  // NUL-separated so paths with spaces survive; read as bytes because the
  // separator is not representable in the system text encoding.
  final lsFiles = Process.runSync(
    'git',
    ['-C', repoRoot, 'ls-files', '-z'],
    stdoutEncoding: null,
  );
  if (lsFiles.exitCode != 0) {
    throw Exception('git ls-files failed:\n${lsFiles.stderr}');
  }
  listing.writeAsBytesSync(lsFiles.stdout as List<int>);
  // No path-rewriting flag: `--transform` is GNU-only and `-s` is bsd-only, so
  // the archive stores bare repo-relative paths and the VM extracts into a
  // directory it names itself. COPYFILE_DISABLE stops macOS bsdtar emitting
  // AppleDouble `._name` sidecars, which would land beside real sources where
  // Bazel's `glob(["lib/**"])` reads `._main.dart` as a Dart file, and
  // `--no-xattrs` (bsdtar and GNU tar both take it) keeps macOS attributes
  // such as `com.apple.provenance` out of the pax headers.
  _run(
    'tar',
    ['-C', repoRoot, '--no-xattrs', '-czf', tgz, '--null', '-T', listing.path],
    environment: {'COPYFILE_DISABLE': '1'},
  );

  // The rules_dart checkout to build against, as a bundle of its HEAD: git on
  // the VM checks it out with its own path handling, and the bundle carries
  // commits the remote may not have yet.
  String? rulesDartBundle;
  if (rulesDartArg.isNotEmpty) {
    rulesDartBundle = '${Directory.systemTemp.path}/rules_dart_src.bundle';
    _warnIfDirty(rulesDartArg);
    _run('git', [
      '-C',
      rulesDartArg,
      'bundle',
      'create',
      rulesDartBundle,
      'HEAD',
    ]);
  }

  // 2. Wait for the toolchain, then transfer + extract + clone rules_dart.
  await _waitForToolchain(vmName, isWindows: isWindows);
  print('Transferring source tree to $vmName ...');
  if (isWindows) {
    await scpToVm(vmName, tgz, 'C:/rf_src.tgz', compress: true);
    // Separate, simple commands. A compound `cmd /c "... & ... & ..."` mangles
    // through gcloud ssh -> Windows cmd and can silently no-op.
    await sshExec(vmName, 'rmdir /s /q C:\\rf'); // tolerate "not found"
    await sshRun(vmName, 'mkdir C:\\rf\\rules_flutter');
    // Git for Windows' GNU tar, not Windows' own tar.exe: that one cannot
    // decode a UTF-8 path from a pax header ("empty or unreadable filename")
    // and reads a bare ustar name in the OEM code page, so the e2e assets
    // named `日本語.png` are skipped or arrive misnamed. GNU tar reads a path
    // given as `C:/...` as a remote host, hence the MSYS `/c/` form.
    await sshRun(
      vmName,
      '"C:\\Program Files\\Git\\usr\\bin\\tar.exe" '
      '-xzf /c/rf_src.tgz -C /c/rf/rules_flutter',
    );
    if (rulesDartBundle != null) {
      await scpToVm(vmName, rulesDartBundle, 'C:/rules_dart.bundle');
      await sshExec(vmName, 'rmdir /s /q C:\\rules_dart');
      // autocrlf off: the build must see the committed bytes.
      await sshRun(
        vmName,
        'git -c core.autocrlf=false clone C:\\rules_dart.bundle C:\\rules_dart',
      );
    }
  } else {
    await scpToVm(vmName, tgz, '~/rules_flutter_src.tgz', compress: true);
    await sshRun(
      vmName,
      "bash -lc 'rm -rf ~/rf && mkdir -p ~/rf/rules_flutter && "
      "tar xzf ~/rules_flutter_src.tgz -C ~/rf/rules_flutter'",
    );
    if (rulesDartBundle != null) {
      await scpToVm(vmName, rulesDartBundle, '~/rules_dart.bundle');
      await sshRun(
        vmName,
        "bash -lc 'rm -rf ~/rules_dart && "
        "git clone ~/rules_dart.bundle ~/rules_dart'",
      );
    }
  }

  // 3. Run each folder.
  final results = <_FolderResult>[];
  for (final folder in folders) {
    stdout.writeln('\n=== ${folder.path} ===');
    final result = await _runFolder(
      vmName,
      folder,
      index: results.length,
      isWindows: isWindows,
      overrideRulesDart: rulesDartBundle != null,
    );
    results.add(result);
    stdout.writeln(
      '${result.pass ? "PASS" : "FAIL"} ${folder.path} '
      '(exit ${result.exitCode})',
    );
    if (!result.pass && !keepGoing) {
      stdout.writeln('Stopping (use --keep-going to run the rest).');
      break;
    }
  }

  // 4. Summary.
  stdout.writeln(
    '\n========== SUMMARY (${isWindows ? "windows" : "linux"}) ==========',
  );
  for (final r in results) {
    stdout.writeln('  ${r.pass ? "PASS" : "FAIL"}  ${r.folder}');
  }
  final failed = results.where((r) => !r.pass).toList();
  if (failed.isEmpty) {
    stdout.writeln('\nAll ${results.length} folders passed.');
    exit(0);
  }
  stdout.writeln('\n${failed.length} folder(s) FAILED:');
  for (final r in failed) {
    stdout.writeln('\n----- ${r.folder} (exit ${r.exitCode}) -----');
    stdout.writeln(r.tail);
  }
  exit(1);
}

/// Runs [folder]'s Bazel command and maps the exit code: 0 (success) and 4 (no
/// test targets) pass; anything else fails.
Future<_FolderResult> _runFolder(
  String vmName,
  _Folder folder, {
  required int index,
  required bool isWindows,
  required bool overrideRulesDart,
}) async {
  // The overrides a local `.bazelrc.user` carries, on the command line. The
  // lock stays as committed; only the root depends on overhead.
  final rulesDart = isWindows ? 'C:/rules_dart' : '\$HOME/rules_dart';
  final overrides = overrideRulesDart
      ? '--override_module=rules_dart=$rulesDart '
            '${folder.path == '.' ? '--override_module=overhead=$rulesDart/overhead ' : ''}'
            '--lockfile_mode=off '
      : '';
  // `build` takes no test flags.
  final testFlags = folder.command == 'test' ? '--test_output=errors ' : '';
  final String command;
  if (isWindows) {
    final winFolder = folder.path == '.'
        ? 'C:\\rf\\rules_flutter'
        : 'C:\\rf\\rules_flutter\\${folder.path.replaceAll('/', '\\')}';
    // /v:on enables delayed expansion so !errorlevel! is bazel's real exit, not
    // the parse-time value. --output_base keeps paths under MAX_PATH.
    command =
        'cmd /v:on /c "cd /d $winFolder && '
        'bazel --output_base=$_winOutputRoot/$index '
        '${folder.command} $testFlags$overrides${folder.targets} & '
        'echo RF_EXIT=!errorlevel!"';
  } else {
    final dir = folder.path == '.'
        ? '\$HOME/rf/rules_flutter'
        : '\$HOME/rf/rules_flutter/${folder.path}';
    command =
        "bash -lc 'cd $dir && "
        "bazel ${folder.command} $testFlags$overrides${folder.targets}; "
        "echo RF_EXIT=\$?'";
  }

  final ProcessResult result;
  try {
    result = await sshExec(vmName, command).timeout(_folderTimeout);
  } on TimeoutException {
    return _FolderResult(
      folder.path,
      -2,
      false,
      'TIMEOUT after $_folderTimeout',
    );
  }

  final combined = '${result.stdout}\n${result.stderr}';
  final exitCode = _parseRfExit(result.stdout.toString());
  final pass = exitCode == 0 || exitCode == 4;
  return _FolderResult(folder.path, exitCode, pass, _tail(combined));
}

/// Waits until the VM's toolchain (bazel + C compiler) is installed.
Future<void> _waitForToolchain(String vmName, {required bool isWindows}) async {
  print('Verifying toolchain on $vmName ...');
  // Generous: a fresh Windows VM may need ~15 min before SSH, then ~15 min to
  // finish installing MSVC + bazelisk via the startup script.
  final deadline = DateTime.now().add(const Duration(minutes: 40));
  while (DateTime.now().isBefore(deadline)) {
    final ProcessResult r;
    if (isWindows) {
      r = await sshExec(
        vmName,
        'cmd /c "type C:\\startup_complete.txt && where bazel"',
      );
      if (r.exitCode == 0 && r.stdout.toString().contains('STARTUP_COMPLETE')) {
        return;
      }
      if (r.stdout.toString().contains('STARTUP_FAILED')) {
        throw Exception('$vmName: the startup script failed: ${r.stdout}');
      }
    } else {
      r = await sshExec(
        vmName,
        'bash -lc "command -v bazel && command -v cc"',
      );
      if (r.exitCode == 0) return;
    }
    stdout.writeln('  toolchain not ready yet; waiting ...');
    await Future<void>.delayed(const Duration(seconds: 20));
  }
  throw Exception('Timed out waiting for toolchain on $vmName');
}

int _parseRfExit(String stdout) {
  final m = RegExp(r'RF_EXIT=(-?\d+)').firstMatch(stdout);
  return m == null ? -1 : int.parse(m.group(1)!);
}

String _tail(String s, {int lines = 60}) {
  final all = s.split('\n');
  return all.length <= lines ? s : all.sublist(all.length - lines).join('\n');
}

String _repoRoot() {
  final r = Process.runSync('git', ['rev-parse', '--show-toplevel']);
  if (r.exitCode != 0) {
    throw Exception('Not in a git repo: ${r.stderr}');
  }
  return r.stdout.toString().trim();
}

void _warnIfDirty(String repoRoot) {
  final r = Process.runSync('git', [
    '-C',
    repoRoot,
    'status',
    '--porcelain',
    '--untracked-files=no',
  ]);
  if (r.stdout.toString().trim().isNotEmpty) {
    stderr.writeln(
      'WARNING: tracked working-tree changes are NOT included — '
      'run_e2e tests committed HEAD only. Commit first to test them.',
    );
  }
}

void _run(String exe, List<String> args, {Map<String, String>? environment}) {
  final r = Process.runSync(exe, args, environment: environment);
  if (r.exitCode != 0) {
    throw Exception('$exe ${args.join(' ')} failed:\n${r.stderr}');
  }
}
