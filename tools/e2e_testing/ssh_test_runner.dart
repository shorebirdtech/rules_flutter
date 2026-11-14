/// Runs a Bazel test's executable on another machine over ssh, as
/// `--run_under=@rules_flutter//tools/e2e_testing:ssh_test_runner`.
///
/// Bazel builds the test and its runfiles here and starts this program in
/// the test's place, with the test's command line and environment. This
/// copies the runfiles tree to a fresh directory on the host named by
/// `RULES_FLUTTER_TEST_HOST` (an ssh destination, passed with `--test_env`),
/// runs the same command there with the same environment, its paths moved
/// into that directory, then copies back what the test wrote to its outputs
/// and removes the directory. The test's output streams to the test log and
/// its exit code is this program's, so `bazel test` reports the remote run
/// as its own.
///
/// It exists for the GUI tests (`verify_macos_app_test` and the like), which
/// open windows: they can run on a Mac set aside for that while building
/// stays on the machine that has the Bazel server. The host must have the
/// same OS and CPU as the build's target platform; nothing is built there.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/remote_runfiles.dart';

const _hostVariable = 'RULES_FLUTTER_TEST_HOST';

/// Variables of this process that are not part of the test's environment:
/// the shell's own bookkeeping, and the host, which is this program's input.
/// `TMPDIR` is set afresh inside the run's directory, so the system temp
/// directory a test unpacks into goes when the run does.
const _notForwarded = {
  _hostVariable,
  '_',
  'OLDPWD',
  'PWD',
  'SHLVL',
  'TMPDIR',
  '__CF_USER_TEXT_ENCODING',
};

Future<void> main(List<String> args) async {
  // Watched from the start: Bazel's timeout sends SIGTERM to this process and
  // its children together, and a signal that killed this process while it
  // copied the runfiles would leave the copy on the host.
  final signals = _Signals();
  try {
    exit(await _run(args, signals));
  } on _Failure catch (failure) {
    stderr.writeln('ssh_test_runner: ${failure.message}');
    final signal = signals.received;
    exit(signal == null ? 1 : 128 + signal.signalNumber);
  }
}

Future<int> _run(List<String> args, _Signals signals) async {
  final env = Platform.environment;
  final host = env[_hostVariable];
  if (host == null || host.isEmpty) {
    _fail(
      '$_hostVariable is not set. Pass the ssh destination to run on with '
      '--test_env=$_hostVariable=<host>.',
    );
  }
  if (args.isEmpty) _fail('No test command: run this as --run_under.');

  final srcdir = _required(env, 'TEST_SRCDIR');
  final tmpdir = _required(env, 'TEST_TMPDIR');
  final xml = _required(env, 'XML_OUTPUT_FILE');
  final testlogs = File(xml).parent.path;
  final ssh = _Ssh(host);

  final probe = await ssh.capture(
    r'uname -sm && mktemp -d "${TMPDIR:-/tmp}/rules_flutter_test.XXXXXX"',
  );
  final [remoteSystem, remoteRoot] = LineSplitter.split(probe).toList();
  final localSystem = (await _capture('uname', ['-sm'])).trim();
  if (remoteSystem != localSystem) {
    _fail(
      '$host is $remoteSystem; this test was built for $localSystem and '
      'cannot run there.',
    );
  }
  final remote = _RemoteLayout(remoteRoot);
  final paths = PathMap({
    srcdir: remote.runfiles,
    tmpdir: remote.tmp,
    testlogs: remote.testlogs,
  });

  stderr.writeln('ssh_test_runner: running on $host in $remoteRoot');
  var exitCode = 1;
  try {
    await _copyRunfiles(ssh, srcdir, remote);

    final testEnv = <String, String>{
      for (final MapEntry(:key, :value) in env.entries)
        if (!_notForwarded.contains(key) && !key.startsWith('BASH_FUNC_'))
          key: paths.map(value),
      'TMPDIR': remote.systemTmp,
    };
    final outputDirs = {
      remote.tmp,
      remote.systemTmp,
      for (final name in [
        'TEST_UNDECLARED_OUTPUTS_DIR',
        'TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR',
      ])
        ?testEnv[name],
      for (final name in [
        'XML_OUTPUT_FILE',
        'TEST_WARNINGS_OUTPUT_FILE',
        'TEST_PREMATURE_EXIT_FILE',
        'TEST_INFRASTRUCTURE_FAILURE_FILE',
        'TEST_UNUSED_RUNFILES_LOG_FILE',
        'TEST_LOGSPLITTER_OUTPUT_FILE',
      ])
        if (testEnv[name] case final file?) _parent(file),
    };
    await ssh.run('mkdir -p ${outputDirs.map(_quote).join(' ')}');

    final command = [
      'echo \$\$ > ${_quote(remote.pidFile)}',
      'cd ${_quote(paths.map(Directory.current.path))}',
      [
        'exec env -i',
        for (final MapEntry(:key, :value) in testEnv.entries)
          _quote('$key=$value'),
        for (final arg in args) _quote(paths.map(arg)),
      ].join(' '),
    ].join(' && ');
    if (signals.received case final signal?) _fail('Stopped by $signal.');
    exitCode = await _runUntilSignalled(ssh, command, remote, signals);

    await _rsync(['${ssh.host}:${remote.testlogs}/', '$testlogs/']);
  } finally {
    // Bazel's outputs are read-only, directories included, and rsync -a keeps
    // their modes: they have to be made writable to be removed.
    final root = _quote(remoteRoot);
    await ssh.run('chmod -R u+w $root && rm -rf $root', check: false);
    await signals.cancel();
  }
  return exitCode;
}

/// Copies the runfiles tree with every link that leaves it replaced by what
/// it points to, and writes a manifest whose targets are the copied files:
/// the copied one names this machine's paths, and the runfiles library reads
/// the manifest before the directory.
Future<void> _copyRunfiles(
  _Ssh ssh,
  String srcdir,
  _RemoteLayout remote,
) async {
  await _rsync([
    '-a',
    '--copy-unsafe-links',
    '--exclude=/MANIFEST',
    '$srcdir/',
    '${ssh.host}:${remote.runfiles}/',
  ]);
  final manifest = File('$srcdir/MANIFEST');
  if (!manifest.existsSync()) return;
  final lines = [
    for (final line in manifest.readAsLinesSync())
      if (rewriteManifestLine(line, remote.runfiles) case final rewritten?)
        rewritten,
  ];
  await ssh.run(
    'cat > ${_quote('${remote.runfiles}/MANIFEST')}',
    stdin: '${lines.join('\n')}\n',
  );
}

/// Runs [command] on the host, and on SIGTERM or SIGINT (Bazel's timeout, or
/// an interrupted build) stops the process group it started there: the ssh
/// client dies of the same signal, and with no terminal on the host that does
/// not stop the test there.
Future<int> _runUntilSignalled(
  _Ssh ssh,
  String command,
  _RemoteLayout remote,
  _Signals signals,
) async {
  final process = await ssh.start(command);
  Future<void>? stopping;
  // TERM, five seconds for the group to go, then KILL, all in one remote
  // shell: the local ssh is gone by now and says nothing about the host.
  final group = '-\$(cat ${_quote(remote.pidFile)})';
  Future<void> stop() => stopping ??= ssh.run(
    'kill -TERM -- $group 2>/dev/null; '
    'for i in 1 2 3 4 5 6 7 8 9 10; do '
    'kill -0 -- $group 2>/dev/null || exit 0; sleep 0.5; done; '
    'kill -KILL -- $group',
    check: false,
  );
  signals.onSignal = (signal) {
    stderr.writeln('ssh_test_runner: $signal, stopping the run on ${ssh.host}');
    return stop();
  };
  final code = await process.exitCode;
  // ssh answers SIGTERM by exiting 255, and that exit can be seen here before
  // the signal reaches this process's own handler.
  if (code == 255 || code < 0 || signals.received != null) await stop();
  if (signals.received case final signal?) return 128 + signal.signalNumber;
  if (code == 255) {
    stderr.writeln('ssh_test_runner: ssh to ${ssh.host} failed (exit 255)');
  }
  return code < 0 ? 128 - code : code;
}

/// SIGTERM and SIGINT, recorded rather than fatal, with what to do about the
/// first one once there is a remote run to stop.
class _Signals {
  _Signals() {
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      _subscriptions.add(signal.watch().listen(_receive));
    }
  }

  final _subscriptions = <StreamSubscription<ProcessSignal>>[];
  ProcessSignal? received;
  Future<void> Function(ProcessSignal)? onSignal;

  void _receive(ProcessSignal signal) {
    if (received != null) return;
    received = signal;
    onSignal?.call(signal);
  }

  Future<void> cancel() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}

class _Ssh {
  _Ssh(this.host);

  final String host;

  static const _options = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10'];

  Future<Process> start(String command) => Process.start('ssh', [
    ..._options,
    host,
    command,
  ], mode: ProcessStartMode.inheritStdio);

  Future<String> capture(String command) =>
      _capture('ssh', [..._options, host, command]);

  Future<void> run(String command, {String? stdin, bool check = true}) async {
    final process = await Process.start('ssh', [..._options, host, command]);
    process.stdout.listen(stdout.add);
    process.stderr.listen(stderr.add);
    if (stdin != null) process.stdin.write(stdin);
    await process.stdin.close();
    final code = await process.exitCode;
    if (check && code != 0) _fail('`$command` on $host exited $code.');
  }
}

class _RemoteLayout {
  _RemoteLayout(this.root);

  final String root;

  String get runfiles => '$root/runfiles';
  String get tmp => '$root/tmp';
  String get systemTmp => '$root/systmp';
  String get testlogs => '$root/testlogs';
  String get pidFile => '$root/pid';
}

Future<void> _rsync(List<String> args) async {
  final result = await Process.run('rsync', args);
  if (result.exitCode != 0) {
    _fail(
      'rsync ${args.join(' ')} exited ${result.exitCode}:\n${result.stderr}',
    );
  }
}

Future<String> _capture(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    _fail(
      '$executable ${args.join(' ')} exited ${result.exitCode}:\n'
      '${result.stderr}',
    );
  }
  return result.stdout as String;
}

String _required(Map<String, String> env, String name) =>
    env[name] ?? _fail('$name is not set: run this as --run_under of a test.');

String _parent(String path) => path.substring(0, path.lastIndexOf('/'));

String _quote(String word) => "'${word.replaceAll("'", r"'\''")}'";

Never _fail(String message) => throw _Failure(message);

class _Failure implements Exception {
  _Failure(this.message);

  final String message;
}
