/// Bazel-side driver for `flutter_test` rule.
///
/// Spawns `flutter_tester` with the kernel `.dill` produced by the rule, hosts
/// a localhost WebSocket harness, and drives the per-test
/// `package:test_api/backend.dart` `RemoteListener` protocol. Reports per-test
/// pass/fail to stdout and exits non-zero on the first failure (or on
/// flutter_tester crash).
///
/// The protocol itself is `remote_suite.dart`'s; this file carries it over a
/// WebSocket the bootstrap dials back on.
///
/// Coverage: when `bazel coverage` sets `COVERAGE_OUTPUT_FILE`, the spawn
/// switches to `--vm-service-port=0`. The runner pulls the VM service URI from
/// flutter_tester's stdout and, once the suite has run and before it is told to
/// close, collects source reports over the VM service JSON-RPC and writes LCOV.
///
/// Goldens: `--update-goldens` (upstream's spelling) sets
/// `FLUTTER_TEST_UPDATE_GOLDENS` in the tester's environment, which the
/// comparator in the bootstrap reads. It is accepted only under `bazel run`,
/// where `BUILD_WORKSPACE_DIRECTORY` names a source tree to write to.
///
/// Bazel's test protocol wins wherever it has one. The suite's default timeout
/// is Bazel's own (`TEST_TIMEOUT`), not `package:test`'s 30 seconds; a test's
/// own `timeout:` still applies — see [suiteTimeout].
/// `--test_filter`, sharding and the per-case XML report follow
/// `lib/bazel_test_protocol.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rule_tools/remote_suite.dart';
import 'package:runfiles/runfiles.dart';

/// Whether this run should regenerate goldens instead of comparing them.
///
/// Pure so it can be tested without a Bazel invocation to produce each case;
/// [workspaceDir] is `BUILD_WORKSPACE_DIRECTORY`, which `bazel run` sets and
/// `bazel test` does not. That variable is the discriminator rather than
/// anything about the arguments, because it is the actual constraint: update
/// mode writes to the source tree, and a test action has no source tree.
///
/// Throws [FormatException] for an unrecognised argument. Nothing passes argv
/// to a `flutter_test` today — not `bazel test`, not `bazel coverage` — so an
/// unrecognised one came from a person, and silently ignoring a mistyped
/// `--update-golden` would report a green run that regenerated nothing.
bool parseUpdateGoldens(List<String> args, String? workspaceDir) {
  var update = false;
  for (final arg in args) {
    if (arg != '--update-goldens') {
      throw FormatException(
        'flutter_test runner: unrecognised argument "$arg". The only '
        'supported argument is --update-goldens.',
      );
    }
    update = true;
  }
  if (update && (workspaceDir == null || workspaceDir.isEmpty)) {
    throw FormatException(
      'flutter_test runner: --update-goldens rewrites goldens in the source '
      'tree, which a test action cannot do. Regenerate with '
      '`bazel run //<pkg>:<target> -- --update-goldens`.',
    );
  }
  return update;
}

/// The runfiles of the program started as [executable], or null.
///
/// Unlike `Runfiles.create`, which trusts `RUNFILES_DIR` first, this looks
/// only beside [executable]: a `RUNFILES_DIR` inherited from a caller names
/// the caller's tree, not this program's. `<executable>.runfiles` and
/// `<executable>.runfiles_manifest` are both read when both exist, with the
/// manifest answering first: where Bazel makes no symlink tree, as on Windows
/// by default, the directory is still there, holding only a `MANIFEST` and
/// empty directories. `.exe` is spelled both ways as on Windows.
///
/// Public, like [testCeiling], because the test reaches it directly.
Runfiles? runfilesBeside(String executable) {
  final withoutExe = executable.endsWith('.exe')
      ? executable.substring(0, executable.length - 4)
      : executable;
  final names = {executable, withoutExe, '$withoutExe.exe'};
  for (final name in names) {
    final dir = Directory('$name.runfiles');
    final file = File('$name.runfiles_manifest');
    final hasDir = dir.existsSync();
    final hasManifest = file.existsSync();
    if (!hasDir && !hasManifest) continue;
    final root = hasDir ? dir.resolveSymbolicLinksSync() : null;
    final manifest = hasManifest
        ? parseRunfilesManifest(file.readAsLinesSync())
        : null;
    final mappingFile = root != null && File('$root/_repo_mapping').existsSync()
        ? '$root/_repo_mapping'
        : manifest?['_repo_mapping'];
    return Runfiles.fromState(
      directory: root,
      manifest: manifest,
      repoMapping: mappingFile == null
          ? null
          : Runfiles.parseRepoMapping(File(mappingFile).readAsStringSync()),
    );
  }
  return null;
}

/// A runfiles manifest's `<runfiles path> <real path>` lines as a map.
///
/// Public, like [testCeiling], because the test reaches it directly.
Map<String, String> parseRunfilesManifest(Iterable<String> lines) {
  final result = <String, String>{};
  for (final line in lines) {
    final space = line.indexOf(' ');
    if (space < 0) continue;
    result[line.substring(0, space)] = line.substring(space + 1);
  }
  return result;
}

/// The start-up settings a `flutter_tester_binary` carries as
/// `<name>.launch.json` at the root of its own runfiles: a JSON object of
/// environment variables.
///
/// Public, like [testCeiling], because the test reaches it directly.
Map<String, String> readLaunchEnvironment(
  Runfiles runfiles,
  String executable,
) {
  var name = executable.split(RegExp(r'[/\\]')).last;
  if (name.endsWith('.exe')) name = name.substring(0, name.length - 4);
  final path = runfiles.rlocation('$name.launch.json');
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('flutter_test runner: no launch data at $path');
  }
  return (json.decode(file.readAsStringSync()) as Map<String, dynamic>)
      .cast<String, String>();
}

/// The directories holding the runfiles [keys], each listed once and in order.
///
/// A manifest lists files, not directories, so a directory is found through
/// a file known to be under it. A library that cannot be found is an error
/// naming it: it is missing from the manifest, or listed but absent on disk.
///
/// Public, like [testCeiling], because the test reaches it directly.
List<String> nativeLibraryDirectories(
  Runfiles runfiles,
  Iterable<String> keys,
) {
  final directories = <String>{};
  for (final key in keys) {
    final String path;
    try {
      path = runfiles.rlocation(key);
    } on StateError {
      throw StateError(
        'flutter_test runner: native library $key is not in the runfiles.',
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError(
        'flutter_test runner: native library $key resolves to $path, which '
        'does not exist.',
      );
    }
    directories.add(file.absolute.parent.path);
  }
  return directories.toList();
}

void main(List<String> args) async {
  // A flutter_test is handed its settings by Bazel's test environment. A
  // flutter_tester_binary carries them in its own runfiles, because the
  // build action that runs it as a tool has no environment for it.
  final Map<String, String> settings;
  final Runfiles r;
  if (Platform.environment['FLUTTER_TEST_DILL'] != null) {
    settings = Platform.environment;
    r = Runfiles.create();
  } else {
    final own = runfilesBeside(Platform.executable);
    if (own == null) {
      stderr.writeln(
        'flutter_test runner: no runfiles beside ${Platform.executable}, and '
        'no FLUTTER_TEST_DILL in the environment.',
      );
      exit(64);
    }
    r = own;
    settings = {
      ...Platform.environment,
      ...readLaunchEnvironment(r, Platform.executable),
    };
  }
  final launched = identical(settings, Platform.environment)
      ? const <String, String>{}
      : settings;

  final bool updateGoldens;
  try {
    updateGoldens = parseUpdateGoldens(
      args,
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    );
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }

  final testerKey = settings['FLUTTER_TEST_TESTER'];
  final icuKey = settings['FLUTTER_TEST_ICU'];
  final dillKey = settings['FLUTTER_TEST_DILL'];
  final assetsKey = settings['FLUTTER_TEST_ASSETS'];
  if (testerKey == null || icuKey == null || dillKey == null) {
    stderr.writeln(
      'flutter_test runner: FLUTTER_TEST_TESTER, FLUTTER_TEST_ICU, and '
      'FLUTTER_TEST_DILL must be set.',
    );
    exit(64);
  }

  final tester = r.rlocation(testerKey);
  final icu = r.rlocation(icuKey);
  final dill = r.rlocation(dillKey);
  final assetsDir = assetsKey == null ? null : r.rlocation(assetsKey);
  final nativeFiles = settings['FLUTTER_TEST_NATIVE_FILES'];
  final Map<String, String> loader;
  try {
    loader = libraryPathEnvironment(
      nativeFiles == null
          ? const []
          : nativeLibraryDirectories(r, nativeFiles.split('\n')),
      Platform.environment,
      Platform.operatingSystem,
    );
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }
  final testPath = settings['FLUTTER_TEST_PATH'] ?? 'test.dart';
  final coverageOutput = Platform.environment['COVERAGE_OUTPUT_FILE'];
  final coverageLibraries =
      settings['FLUTTER_TEST_COVERAGE_LIBRARIES']?.split('\n') ??
      const <String>[];

  final TestSelection selection;
  try {
    selection = TestSelection.fromEnvironment(settings);
  } on FormatException catch (e) {
    stderr.writeln('flutter_test runner: ${e.message}');
    exit(64);
  }
  // Touched before the run, as Bazel asks: it is how a runner says it supports
  // sharding at all, and Bazel 9 fails a sharded test whose runner never does.
  final shardStatus = Platform.environment['TEST_SHARD_STATUS_FILE'];
  if (shardStatus != null) File(shardStatus).writeAsStringSync('');

  exitCode = await _runOnce(
    tester: tester,
    icu: icu,
    dill: dill,
    assetsDir: assetsDir,
    testPath: testPath,
    coverageOutput: coverageOutput,
    coverageLibraries: coverageLibraries,
    updateGoldens: updateGoldens,
    selection: selection,
    xmlOutput: Platform.environment['XML_OUTPUT_FILE'],
    impeller: settings['FLUTTER_TEST_IMPELLER'] == '1',
    loader: {...launched, ...loader},
  );
}

/// The loader's search path for a `flutter_tester_binary`'s Native Assets.
///
/// Its kernel names each bundled library by filename alone, so the program
/// may run from any working directory; this puts [nativeDirs], where they are
/// staged, ahead of the search path [environment] already has. Empty when
/// there are no such directories, as for every `flutter_test`, whose libraries
/// are named by their paths under the runfiles root it runs in.
///
/// Windows has no variable for the purpose: `LoadLibrary` of a bare name
/// looks in the application's directory, the system directories, the working
/// directory and then `PATH`, and only `PATH` can be set for a child. Its
/// directories are joined with `;` and spelled with `\`, and its variable is
/// found without regard to case, as Windows does, so the child is not given
/// `Path` and `PATH` both.
///
/// Public, like [testCeiling], because the test reaches it directly.
Map<String, String> libraryPathEnvironment(
  List<String> nativeDirs,
  Map<String, String> environment,
  String os,
) {
  if (nativeDirs.isEmpty) return const {};
  final windows = os == 'windows';
  final String variable;
  switch (os) {
    case 'macos':
      variable = 'DYLD_LIBRARY_PATH';
    case 'linux':
      variable = 'LD_LIBRARY_PATH';
    case 'windows':
      variable = environment.keys.firstWhere(
        (k) => k.toUpperCase() == 'PATH',
        orElse: () => 'PATH',
      );
    default:
      throw UnsupportedError('flutter_tester_binary: no loader path on $os');
  }
  final separator = windows ? ';' : ':';
  final dirs = [
    for (final dir in nativeDirs) windows ? dir.replaceAll('/', r'\') : dir,
    if (environment[variable] case final existing? when existing.isNotEmpty)
      existing,
  ];
  return {variable: dirs.join(separator)};
}

Future<int> _runOnce({
  required String tester,
  required String icu,
  required String dill,
  required String? assetsDir,
  required String testPath,
  required String? coverageOutput,
  required List<String> coverageLibraries,
  required bool updateGoldens,
  required TestSelection selection,
  required String? xmlOutput,
  required bool impeller,
  required Map<String, String> loader,
}) async {
  final harness = await _Harness.bind();
  try {
    return await harness.run(
      tester: tester,
      icu: icu,
      dill: dill,
      assetsDir: assetsDir,
      testPath: testPath,
      coverageOutput: coverageOutput,
      coverageLibraries: coverageLibraries,
      updateGoldens: updateGoldens,
      selection: selection,
      xmlOutput: xmlOutput,
      impeller: impeller,
      loader: loader,
    );
  } finally {
    await harness.dispose();
  }
}

/// The `flutter_tester` bootstrap's WebSocket, as a [SuiteTransport].
class _TesterTransport implements SuiteTransport {
  _TesterTransport(this._ws, this._process) {
    _ws.listen(
      (raw) => _incoming.add(raw as String),
      onDone: () {
        unawaited(_incoming.close());
        if (!_lost.isCompleted) _lost.complete('flutter_tester disconnected');
      },
    );
  }

  final WebSocket _ws;
  final Process _process;
  final _incoming = StreamController<String>();
  final _lost = Completer<String?>();

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  void send(String json) {
    if (_lost.isCompleted) return;
    _ws.add(json);
  }

  @override
  Future<String?> get lostReason => _lost.future;

  @override
  Future<void> close() => _ws.close();

  @override
  Future<void> abandon(String why) async {
    stderr.writeln('flutter_test: killing flutter_tester.');
    _process.kill(ProcessSignal.sigkill);
  }
}

/// Harness state: server, tester process, WebSocket.
class _Harness {
  _Harness._(this._server);

  final HttpServer _server;
  Process? _process;
  WebSocket? _ws;

  /// Binds the socket the test bootstrap dials back on.
  ///
  /// The IPv4 loopback specifically, and the bootstrap dials
  /// `ws://127.0.0.1:$port` for it — one family at both ends, deliberately.
  /// Only a port number crosses to the tester process
  /// (`FLUTTER_TEST_HARNESS_PORT`), so nothing here publishes a *name* for a
  /// client to choose a family from. That is what makes this unlike the
  /// control channel and the web dev server, which bind both loopbacks
  /// because their URLs say `localhost`: a client resolving that name picks a
  /// family itself, so half of such a URL would reach whatever else holds the
  /// port on the family the server left free. A specific-address bind is also
  /// refused outright by the kernel when the port is already held, so nothing
  /// can be reached here in place of this server.
  ///
  /// The one host this cannot run on is one with no assignable 127.0.0.1 — an
  /// IPv6-only loopback. Never tested, and accepted as untested rather than
  /// coded around, because a Flutter test cannot work there for reasons above
  /// this file. The engine binds its VM service to 127.0.0.1 unless launched
  /// with `--ipv6` (`engine/src/flutter/shell/common/switches.cc`, read at all
  /// five engine revisions `versions.bzl` pins), nothing in this repo passes
  /// that flag, the only VM-service host it does name is the IPv4 wildcard
  /// `0.0.0.0` for a wireless iOS device, and the `adb`/`iproxy` forwards a
  /// device run is dialed through listen on 127.0.0.1. Widening this bind
  /// alone would buy nothing.
  ///
  /// So do not change it without a failure reproduced on such a host — and
  /// never without the dial in `flutter/private/flutter_test.bzl`, which has
  /// to name the same family.
  static Future<_Harness> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _Harness._(server);
  }

  /// Closes all three of the harness's resources, independently.
  ///
  /// Separate `try`s because none of the three depends on the one before it,
  /// and this runs on the failure paths too — a socket that will not close
  /// must not leave the tester process alive or the port bound. They stay
  /// broad and quiet because what they throw is "already closed", which is
  /// the state the call was asking for.
  ///
  /// [Process.kill] is not one of them and is no longer wrapped. It answers
  /// with a bool and does not throw for a dead process — dart-sdk
  /// `lib/io/process.dart`: "Returns `true` if the signal is successfully
  /// delivered... Otherwise the signal could not be sent, usually meaning that
  /// the process is already dead." The `try` around it was guarding a failure
  /// that cannot happen, while the value that does report it went unread.
  Future<void> dispose() async {
    try {
      await _ws?.close();
    } catch (_) {}
    _process?.kill(ProcessSignal.sigkill);
    try {
      await _server.close(force: true);
    } catch (_) {}
  }

  Future<int> run({
    required String tester,
    required String icu,
    required String dill,
    required String? assetsDir,
    required String testPath,
    required String? coverageOutput,
    required List<String> coverageLibraries,
    required bool updateGoldens,
    required TestSelection selection,
    required String? xmlOutput,
    required bool impeller,
    required Map<String, String> loader,
  }) async {
    final enableVmService = coverageOutput != null;
    // Coverage does not start the tester paused, and `flutter test --coverage`
    // does not either. Nothing needs holding: the VM records coverage from
    // the first line `main()` runs, and collection happens before the suite
    // is told to close, while the isolate is still alive. Starting paused and
    // resuming over the VM service hung one run in ten, measured on
    // `:hello_coverage_test`: the resumed isolate sat idle inside the
    // bootstrap, never dialling the harness, until an unrelated VM service
    // request woke it. Unpaused, 80 runs in a row passed with identical
    // covered lines.
    final command = <String>[
      tester,
      if (enableVmService) '--vm-service-port=0' else '--disable-vm-service',
      '--icu-data-file-path=$icu',
      '--enable-checked-mode',
      '--verify-entry-points',
      // `flutter test --enable-impeller`'s choice: Impeller, or software
      // Skia rendered deterministically.
      if (impeller)
        '--enable-impeller'
      else ...[
        '--enable-software-rendering',
        '--skia-deterministic-rendering',
      ],
      '--enable-dart-profiling',
      '--non-interactive',
      '--use-test-fonts',
      '--disable-asset-fonts',
      if (assetsDir != null) '--flutter-assets-dir=$assetsDir',
      dill,
    ];

    _process = await Process.start(
      command.first,
      command.sublist(1),
      environment: {
        'FLUTTER_TEST': 'true',
        'FLUTTER_TEST_HARNESS_PORT': '${_server.port}',
        // `flutter test` bakes `autoUpdateGoldenFiles = true` into a bootstrap
        // it regenerates for every run. Here the bootstrap is a build artifact
        // shared by every run of the target, so update mode has to reach the
        // tester at runtime instead. The parent environment comes along by
        // default, which is how the comparator also sees
        // BUILD_WORKSPACE_DIRECTORY and TEST_UNDECLARED_OUTPUTS_DIR.
        if (updateGoldens) 'FLUTTER_TEST_UPDATE_GOLDENS': '1',
        ...loader,
      },
    );

    // Capture flutter_tester output so engine errors are visible. In coverage
    // mode we also need to scan stdout for the VM service URI.
    final vmServiceUriCompleter = Completer<Uri>();
    final vmServicePattern = RegExp(
      r'(?:Observatory|The Dart VM service is) (?:listening on|listening on) (http\S+)',
    );

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderr.writeln('[flutter_tester] $line');
          if (enableVmService && !vmServiceUriCompleter.isCompleted) {
            final m = vmServicePattern.firstMatch(line);
            if (m != null) {
              vmServiceUriCompleter.complete(Uri.parse(m.group(1)!));
            }
          }
        });
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderr.writeln('[flutter_tester] $line');
        });

    // A coverage run that cannot reach the VM service cannot produce what it
    // exists for, so it ends here rather than running the whole suite first
    // and failing at collection.
    Uri? coverageVmServiceUri;
    if (enableVmService) {
      try {
        coverageVmServiceUri = await vmServiceUriCompleter.future.timeout(
          const Duration(seconds: 30),
        );
      } catch (e) {
        stderr.writeln(
          'flutter_test (coverage): failed to bring up the VM service: $e',
        );
        return 1;
      }
    }

    // Wait for the bootstrap to dial back.
    switch (await _awaitDialBack()) {
      case _TesterExited(:final exitCode):
        stderr.writeln(
          'flutter_test: flutter_tester exited with code $exitCode before '
          'connecting to the harness.',
        );
        return exitCode == 0 ? 1 : exitCode;
      case _DialBackTimedOut():
        stderr.writeln(
          'flutter_test: flutter_tester did not connect to the harness within '
          '${_dialBackBound.inMinutes} minutes and is still running; killing '
          'it.',
        );
        return 1;
      case _BootstrapConnected(:final request):
        _ws = await WebSocketTransformer.upgrade(request);
    }

    // Collect coverage before the driver tells the tester to close — the
    // isolate must still be alive when we fetch source reports.
    String? coverageError;
    Future<void> collect() async {
      if (!enableVmService || coverageVmServiceUri == null) return;
      try {
        // Bounded inside Bazel's own budget, like the suite and each test: a
        // VM service that stops answering mid-collection would otherwise park
        // here until Bazel kills the target with no reason given. Not a fixed
        // bound: on a starved machine the tester gets a few percent of a core
        // and a collection that takes seconds idle takes minutes.
        final lcov = await collectCoverage(
          coverageVmServiceUri,
          coverageLibraries,
        ).timeout(testCeiling(Platform.environment['TEST_TIMEOUT']));
        // Every healthy run yields at least the test's own `main` file, which
        // is always in scope, so an empty report means collection reached no
        // source at all. Writing it
        // would produce exactly the green-test-with-empty-LCOV outcome the
        // exit below exists to prevent.
        if (lcov.isEmpty) {
          coverageError = 'collected no coverage records';
        } else {
          await File(coverageOutput).writeAsString(lcov);
        }
      } catch (e) {
        coverageError = 'failed to collect coverage: $e';
      }
      if (coverageError != null) {
        stderr.writeln('flutter_test (coverage): $coverageError');
      }
    }

    // The driver ends the suite politely: it tells RemoteListener to close,
    // then closes the WebSocket. The bootstrap's `socket.map(...).pipe(sink)`
    // and `socket.addStream(...)` both terminate on socket close, draining the
    // isolate so flutter_tester exits on its own. Without the explicit
    // close, the bootstrap's main isolate keeps the engine alive and
    // we'd block on the tester-exit timeout for every test run.
    final ceiling = testCeiling(Platform.environment['TEST_TIMEOUT']);
    final outcome =
        await RemoteSuiteDriver(
          _TesterTransport(_ws!, _process!),
          suitePath: testPath,
          timeout: suiteTimeout(Platform.environment['TEST_TIMEOUT']),
        ).run(
          selection: selection,
          xmlOutput: xmlOutput,
          ceiling: ceiling,
          afterSuite: collect,
        );

    // `-1` can't double as a "we killed it" sentinel here: on POSIX a
    // signal-killed process reports `-signum`, and SIGHUP is signal 1, so
    // `-1` is a real exit value. Track the timeout kill explicitly instead.
    var killedAfterTimeout = false;
    final testerExit = await _process!.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        killedAfterTimeout = true;
        _process!.kill(ProcessSignal.sigkill);
        return 0;
      },
    );
    if (killedAfterTimeout) {
      stderr.writeln(
        'flutter_test: flutter_tester did not exit within 30s after the '
        'suite finished; killed it.',
      );
    }

    stdout.writeln(outcome.summary());

    if (outcome.hasFailure) return 1;
    // A requested coverage run that produced no data is a failure — Bazel
    // would otherwise record a green test with an empty/absent LCOV file.
    if (coverageError != null) return 1;
    if (!killedAfterTimeout && testerExit != 0) {
      stderr.writeln('flutter_test: flutter_tester exited with $testerExit');
      return testerExit;
    }
    return 0;
  }

  /// How long flutter_tester gets to open its socket back to us.
  static const _dialBackBound = Duration(minutes: 2);

  /// Waits for the bootstrap's dial-back, reporting which of the three
  /// possible outcomes happened.
  ///
  /// The distinction is load-bearing rather than tidiness. A single nullable
  /// `HttpRequest?` collapses "flutter_tester died" and "flutter_tester is
  /// alive and silent" into one `null`, and only the first of those has an
  /// exit code worth awaiting — awaiting it on the second blocks forever, and
  /// a paused coverage run then reaches Bazel's outer test timeout with no
  /// diagnostic of its own.
  Future<_DialBack> _awaitDialBack() async {
    final outcome = await Future.any([
      _server.first.then<_DialBack?>(_BootstrapConnected.new),
      _process!.exitCode.then<_DialBack?>(_TesterExited.new),
    ]).timeout(_dialBackBound, onTimeout: () => null);
    return outcome ?? const _DialBackTimedOut();
  }
}

/// The outcome of waiting for flutter_tester's bootstrap to connect back.
sealed class _DialBack {
  const _DialBack();
}

/// The bootstrap connected; [request] is the HTTP request to upgrade.
final class _BootstrapConnected extends _DialBack {
  const _BootstrapConnected(this.request);

  final HttpRequest request;
}

/// flutter_tester exited before connecting, with [exitCode].
final class _TesterExited extends _DialBack {
  const _TesterExited(this.exitCode);

  final int exitCode;
}

/// Nothing happened within the bound: flutter_tester is alive and has not
/// connected. There is no exit code to wait for.
final class _DialBackTimedOut extends _DialBack {
  const _DialBackTimedOut();
}

// ---------------------------------------------------------------------------
// Coverage support — reuse the same VM service JSON-RPC scaffolding the old
// `dart`-based runner had, but pointed at flutter_tester instead of the Dart
// SDK binary.

/// Collects an LCOV report from every isolate the VM service lists, over the
/// libraries whose URIs start with one of [libraryFilters].
///
/// Scoped, as `flutter test --coverage` scopes to the test's own package by
/// default: `forceCompile` compiles every library in scope and each script
/// costs a round trip for its token table, so an unscoped report over the
/// whole Flutter framework (some 1,000 scripts) costs seconds of CPU even
/// for a test that touches none of it.
///
/// Public so `flutter_test_runner_test.dart` can drive it against a fake VM
/// service; nothing else in this script calls it from outside [main].
///
/// Every failure propagates. The caller turns one into `failed to collect
/// coverage: …` and exits non-zero, which is the only honest answer available:
/// a report missing an isolate — or missing one file within an isolate — is
/// indistinguishable from a complete one once written, so a run that drops
/// part of its coverage reads as a run that simply exercised less code. That
/// sends someone to write tests that already exist, or passes a coverage bar
/// that was never actually met.
///
/// Per-isolate failures must not be swallowed. A bare catch cannot tell an
/// exited isolate from anything else, so it equally hides every RPC error and
/// every `TypeError` thrown by
/// [_formatLcov] casting a malformed report. And the scenario it named does
/// not arise here: collection runs before the suite is told to close, so the
/// isolates `getVM` just listed are alive by construction — measured at one
/// isolate, collected without error, on the `hello_coverage_test` path that is
/// the only coverage run in the repo.
Future<String> collectCoverage(Uri httpUri, List<String> libraryFilters) async {
  final ws = await _connectVmServiceWebSocket(httpUri);
  try {
    final rpc = _VmServiceRpc(ws);
    final vm = await rpc.call('getVM');
    final isolates = (vm['isolates'] as List?) ?? const [];
    final lines = <String>[];
    for (final iso in isolates) {
      final id = (iso as Map)['id'] as String;
      final report = await rpc.call('getSourceReport', {
        'isolateId': id,
        'reports': const ['Coverage'],
        'forceCompile': true,
        'libraryFilters': libraryFilters,
      });
      await _formatLcov(report, lines, rpc, id);
    }
    return lines.join('\n');
  } finally {
    await ws.close();
  }
}

Future<WebSocket> _connectVmServiceWebSocket(Uri httpUri) {
  final wsUri = httpUri.replace(
    scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    path: '${httpUri.path}ws',
  );
  return WebSocket.connect(wsUri.toString());
}

class _VmServiceRpc {
  _VmServiceRpc(this._ws) {
    _sub = _ws.listen(_onMessage);
  }

  final WebSocket _ws;
  late final StreamSubscription<dynamic> _sub;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  int _id = 1;

  void _onMessage(dynamic raw) {
    final m = json.decode(raw as String) as Map<String, dynamic>;
    final id = m['id']?.toString();
    if (id != null && _pending.containsKey(id)) {
      _pending[id]!.complete(m);
    }
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final id = '${_id++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws.add(
      json.encode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    );
    return c.future.then((response) {
      _pending.remove(id);
      if (response.containsKey('error')) {
        throw StateError('VM service error on $method: ${response['error']}');
      }
      return response['result'] as Map<String, dynamic>;
    });
  }

  Future<void> close() async {
    await _sub.cancel();
  }
}

Map<int, int> _buildTokenToLineMap(List<dynamic> tokenPosTable) {
  final map = <int, int>{};
  for (final entry in tokenPosTable) {
    final row = entry as List;
    if (row.isEmpty) continue;
    final line = row[0] as int;
    for (var i = 1; i < row.length; i += 2) {
      map[row[i] as int] = line;
    }
  }
  return map;
}

Future<void> _formatLcov(
  Map<String, dynamic> report,
  List<String> lines,
  _VmServiceRpc rpc,
  String isolateId,
) async {
  final scripts = (report['scripts'] as List?) ?? const [];
  final ranges = (report['ranges'] as List?) ?? const [];

  final scriptInfo = <int, ({String id, String uri})>{};
  for (var i = 0; i < scripts.length; i++) {
    final s = (scripts[i] as Map).cast<String, dynamic>();
    scriptInfo[i] = (id: s['id'] as String, uri: s['uri'] as String);
  }

  final perScript = <int, ({List<int> hits, List<int> misses})>{};
  for (final range in ranges) {
    final scriptIndex = (range as Map)['scriptIndex'] as int?;
    if (scriptIndex == null) continue;
    final info = scriptInfo[scriptIndex];
    if (info == null) continue;
    if (info.uri.startsWith('dart:')) continue;
    final coverage = (range['coverage'] as Map?)?.cast<String, dynamic>();
    if (coverage == null) continue;
    final entry = perScript.putIfAbsent(
      scriptIndex,
      () => (hits: <int>[], misses: <int>[]),
    );
    entry.hits.addAll((coverage['hits'] as List?)?.cast<int>() ?? const []);
    entry.misses.addAll((coverage['misses'] as List?)?.cast<int>() ?? const []);
  }

  for (final entry in perScript.entries) {
    final info = scriptInfo[entry.key]!;
    final tokens = entry.value;

    // Not guarded: a `getObject` that fails drops this script's every line
    // from the report while the surrounding records still look complete, so
    // the loss has to reach the caller. `tokenPosTable` being absent is the
    // one silent skip left, and it is a documented-optional field rather than
    // a failure — a script that reports no token table has no line numbers to
    // attribute hits to.
    final script = await rpc.call('getObject', {
      'isolateId': isolateId,
      'objectId': info.id,
    });
    final table = script['tokenPosTable'] as List?;
    if (table == null) continue;
    final tokenToLine = _buildTokenToLineMap(table);

    final lineHits = <int, int>{};
    for (final t in tokens.hits) {
      final line = tokenToLine[t];
      if (line != null) lineHits[line] = (lineHits[line] ?? 0) + 1;
    }
    for (final t in tokens.misses) {
      final line = tokenToLine[t];
      if (line != null) lineHits.putIfAbsent(line, () => 0);
    }

    if (lineHits.isEmpty) continue;

    var path = info.uri;
    if (path.startsWith('file://')) path = Uri.parse(path).toFilePath();

    lines.add('SF:$path');
    final sorted = lineHits.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final lh in sorted) {
      lines.add('DA:${lh.key},${lh.value}');
    }
    lines.add('end_of_record');
  }
}
