/// Runs the dev_tool e2e suite and refuses to call a run that did not happen a
/// pass.
///
/// ```sh
/// bazel run //tools/dev_tool:e2e                         # the whole suite
/// bazel run //tools/dev_tool:e2e -- --plain-name="macOS" # scoped
/// bazel run //tools/dev_tool:e2e -- test/e2e/agent_e2e_test.dart
/// ```
///
/// Arguments are forwarded to `dart test`; any positional one replaces the
/// default `test/e2e/` path.
///
/// ## Why this exists rather than a bare `dart test`
///
/// `dart test` has three ways to finish without running the suite, and only two
/// of them are loud:
///
/// | condition                                     | exit | verdict    |
/// |---|---|---|
/// | version solving fails (a dep cannot resolve)  | 65   | loud       |
/// | nothing selected (`--tags`/`-n` match none)   | 79   | loud       |
/// | **every selected test skipped**               | **0**| **silent** |
///
/// The third is the hole. `dart test` prints `All tests skipped.` and exits 0,
/// so a suite that ran nothing is indistinguishable — to CI, to a sweep script,
/// to an agent — from one that passed. It is reachable rather than theoretical:
/// most of the e2e files are `skip:`-gated on `Platform.isMacOS`, so the whole
/// of each one "passes" having executed nothing on any other host.
///
/// This runner closes the hole by reading the machine-readable result stream
/// rather than the exit code: it counts the tests that actually *ran* and fails
/// when that count is zero, when any test failed, or when the runner never
/// reached its own verdict.
///
/// It also removes the reason the exit code gets lost in the first place. The
/// documented recipes are long pipelines (`caffeinate -d dart test … | tee`),
/// and a shell reports the *tail* of a pipeline: `dart test … | head -3` after
/// either loud failure leaves `$?` at 0 with `PIPESTATUS` at `65 0`. A reader
/// who judges by what scrolled past sees no failing test names and calls it
/// green. Here the verdict is the last thing printed, in words.
///
/// ## The toolchain's `dart` runs it, through `bazel run`
///
/// `//tools/dev_tool:e2e` is this file as a `kernel` `dart_binary`, so the VM
/// that runs it is the resolved toolchain's `dart`, the one the build compiles
/// with; its target lists `@rules_dart//dart` in `data` so the rest of that SDK,
/// which `dart test` needs, is declared too. The suite runs on
/// [Platform.resolvedExecutable], this very VM, so `PATH` is never consulted
/// and the banner below names the `dart` that ran.
///
/// The runner resolves the pub workspace with `dart pub get` before the suite
/// starts (see [_resolve] for why `dart test` is not left to do it), and that
/// workspace has packages that depend on `sdk: flutter`. A bare Dart SDK cannot
/// resolve those ("the Flutter SDK is not available", exit 65), so the suite
/// gets `FLUTTER_ROOT` pointing at `@flutter_dev_root`, the tree
/// `@rules_flutter//flutter/pub` resolves the lock against, from the same
/// Flutter tag the toolchain pins.
///
/// The suite runs `bazel` itself, in this workspace among others, while it is
/// running. That does not deadlock on the outer `bazel run`: its server builds
/// the target and releases the workspace lock before the client starts the
/// binary.
///
/// What `bazel run` hands this process is not the suite's. The package is found
/// through `BUILD_WORKSPACE_DIRECTORY`, because [Platform.script] is a kernel in
/// a runfiles tree. And the suite starts without `bazel run`'s variables: the
/// dev tool it drives reads `BUILD_WORKSPACE_DIRECTORY` before anything else, so
/// an inherited one would point every session at this workspace instead of the
/// e2e workspace the test chose, and the runfiles variables would point the
/// tool's own runfiles lookups at this runner's tree.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// The leading argument the target's `args` supplies: the runfiles path of
/// `bin/cache/flutter.version.json`, three levels below the `FLUTTER_ROOT` it
/// anchors.
const _manifestFlag = '--flutter-version-manifest=';

/// The second: the runfiles path of the Android SDK's `adb` for this host,
/// which the suite's Android cases ask which device to run on.
const _adbFlag = '--adb=';

/// What the suite reads that `adb` from.
const _adbVariable = 'FLUTTER_BAZEL_E2E_ADB';

/// The path used when the caller names none.
const _defaultPath = 'test/e2e/';

/// Flags the suite always needs. `--concurrency=1` because every test drives
/// real builds, devices and windows; `--tags=e2e` because those are the only
/// tagged files and the unit tests already have Bazel targets.
const _alwaysArgs = ['--tags=e2e', '--concurrency=1'];

Future<void> main(List<String> runArgs) async {
  if (runArgs.isEmpty || !runArgs.first.startsWith(_manifestFlag)) {
    _fail(
      'started without $_manifestFlag, so not by its Bazel target. Run the '
      'suite with `bazel run //tools/dev_tool:e2e`.',
    );
  }
  final flutterRoot = _flutterRoot(
    runArgs.first.substring(_manifestFlag.length),
  );
  if (runArgs.length < 2 || !runArgs[1].startsWith(_adbFlag)) {
    _fail(
      'started without $_adbFlag, so not by its Bazel target. Run the suite '
      'with `bazel run //tools/dev_tool:e2e`.',
    );
  }
  final adb = _runfile(runArgs[1].substring(_adbFlag.length), 'adb');
  final args = runArgs.sublist(2);
  final packageDir = _packageDir();
  // Forwarded verbatim and in order — splitting flags from positionals would
  // tear `--plain-name occluded` in half, since the value carries no leading
  // dash. The default path is supplied only when the caller named nothing that
  // could be one; when they did, `dart test` resolves it, and when they passed
  // a flag value that merely looks positional it falls back to `test/`, where
  // `--tags=e2e` still selects these files and nothing else.
  final testArgs = [
    'test',
    if (!args.any((a) => !a.startsWith('-'))) _defaultPath,
    ..._alwaysArgs,
    ...args,
  ];

  // `Platform.version` is `<semver> (<channel>) (<date>) on "<os>"`; the
  // banner wants the semver.
  final runner = Platform.version.split(' ').first;
  stderr.writeln('e2e: ${Platform.resolvedExecutable} ($runner)');
  stderr.writeln('e2e: FLUTTER_ROOT=$flutterRoot');
  stderr.writeln('e2e: ${packageDir.path}\$ dart ${testArgs.join(' ')}');

  final environment = _suiteEnvironment(flutterRoot, adb);
  await _resolve(packageDir, environment);
  final outcome = await _runSuite(packageDir, environment, testArgs);
  outcome.report();
  exit(outcome.ok ? 0 : 1);
}

/// The source directory holding `pubspec.yaml`: `tools/dev_tool` in the
/// workspace `bazel run` was invoked in, so the runner works from any cwd.
Directory _packageDir() {
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null || workspace.isEmpty) {
    _fail(
      'BUILD_WORKSPACE_DIRECTORY is unset, so this was not started by '
      '`bazel run`. Run the suite with `bazel run //tools/dev_tool:e2e`.',
    );
  }
  final dir = Directory('$workspace/tools/dev_tool');
  final pubspec = File('${dir.path}/pubspec.yaml');
  if (!pubspec.existsSync()) {
    _fail('expected ${pubspec.path} to exist.');
  }
  return dir;
}

/// The `FLUTTER_ROOT` the suite's pub resolution reads: the root above the
/// version manifest at the runfiles path [manifestPath].
String _flutterRoot(String manifestPath) =>
    File(_runfile(manifestPath, 'the Flutter version manifest'))
        .absolute
        .parent
        .parent
        .parent
        .path;

/// The absolute path of the runfile at [path], [what] naming it if it is not
/// there.
String _runfile(String path, String what) {
  final Runfiles runfiles;
  try {
    runfiles = Runfiles.create();
  } on StateError catch (e) {
    _fail('cannot find this runner\'s runfiles: ${e.message}');
  }
  final file = File(runfiles.rlocation(path));
  if (!file.existsSync()) {
    _fail('cannot find $what: its runfile $path resolves to ${file.path}.');
  }
  return file.absolute.path;
}

/// This process's environment without what `bazel run` added for it, and with
/// [flutterRoot] and [adb]. See the library comment for what each would break.
Map<String, String> _suiteEnvironment(String flutterRoot, String adb) => {
  for (final MapEntry(:key, :value) in Platform.environment.entries)
    if (key != 'BUILD_WORKSPACE_DIRECTORY' &&
        key != 'BUILD_WORKING_DIRECTORY' &&
        key != 'JAVA_RUNFILES' &&
        !key.startsWith('RUNFILES_'))
      key: value,
  'FLUTTER_ROOT': flutterRoot,
  _adbVariable: adb,
};

/// Resolves the pub workspace with `dart pub get`, in a process of its own,
/// before `dart test` starts.
///
/// `dart test` can resolve on its own, but with Dart 3.13's pub it can do so
/// only once per process: the first resolution closes pub's HTTP client, and
/// a second one dies on `Bad state: Attempting to send request on closed
/// client`. A second one comes whenever `dart test` finds no
/// `.dart_tool/package_config.json` and some workspace member's `pubspec.yaml`
/// is newer than `pubspec.lock`, as in every fresh checkout that writes
/// `tools/` after the root lock: it resolves, and then pub's up-to-date check,
/// which counts the other workspace members as packages missing from the lock,
/// calls that resolution stale and starts another. Resolved here first,
/// `dart test` finds the package config and resolves at most once.
Future<void> _resolve(
  Directory packageDir,
  Map<String, String> environment,
) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['pub', 'get'],
    workingDirectory: packageDir.path,
    environment: environment,
    includeParentEnvironment: false,
  );
  // To stderr, both: this runner's stdout carries only what it says itself.
  await Future.wait([
    process.stdout.transform(utf8.decoder).forEach(stderr.write),
    process.stderr.transform(utf8.decoder).forEach(stderr.write),
  ]);
  final code = await process.exitCode;
  if (code != 0) {
    _fail('`dart pub get` exited $code, so the suite did not run.');
  }
}

Future<Outcome> _runSuite(
  Directory packageDir,
  Map<String, String> environment,
  List<String> testArgs,
) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [...testArgs, '--reporter', 'json'],
    workingDirectory: packageDir.path,
    environment: environment,
    includeParentEnvironment: false,
  );
  // The runner's own diagnostics — version solving, load errors, a test's own
  // prints — arrive here, and when the JSON stream stops early this is the only
  // place that says why. Relayed line by line rather than with `addStream`,
  // which would bind `stderr` and make this runner's own writes throw
  // `StreamSink is bound to a stream` the moment a test reported anything.
  final outcome = Outcome();
  await Future.wait([
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(stderr.writeln),
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(outcome.consume),
  ]);
  outcome.runnerExitCode = await process.exitCode;
  return outcome;
}

/// Accumulates the `package:test` JSON event stream into a verdict.
///
/// The contract used here, from `package:test`'s json reporter: every test
/// emits `testStart` then `testDone`; `testDone` carries
/// `result` (`success` / `failure` / `error`), `skipped` (true for both a
/// declaration-time `skip:` and a runtime `markTestSkipped`), and `hidden`
/// (true for the synthetic "loading <file>" entries, which are not tests). A
/// `done` event closes a run that reached its own end — note it reports
/// `success: true` for both of the run-nothing cases, which is exactly why the
/// counts below, and not `done`, decide the verdict.
class Outcome {
  final _names = <int, String>{};
  final _errors = <String, List<String>>{};

  /// Why each test skipped, keyed by test id while the run is in flight and
  /// re-keyed by name once it finishes.
  ///
  /// The reporter says this twice and in two shapes, so both are read: a
  /// declaration-time `skip: '<reason>'` arrives on `testStart` as
  /// `test.metadata.skipReason`, and both that and a runtime
  /// `markTestSkipped` arrive as a `print` event carrying
  /// `messageType: "skip"`. Metadata wins where there is one, because the
  /// print prefixes it with `Skip: `.
  final _skipReasons = <int, String>{};
  final _skipReasonByName = <String, String>{};

  /// Tests that executed and reported success. **Not** "tests that ran" — a
  /// test that ran and failed is in [failed], and the two together are
  /// [executed]. The distinction is not cosmetic: reading this list as
  /// "everything that ran" makes a run whose only test failed report itself as
  /// a selection mistake.
  final passed = <String>[];
  final skipped = <String>[];
  final failed = <String>[];

  /// Null when the runner never emitted its terminal `done` event — it died,
  /// or never started, partway through. That is a failure whatever the counts
  /// say, because the counts are then a prefix of an unknown whole.
  bool? runnerVerdict;
  int runnerExitCode = -1;

  void consume(String line) {
    if (!line.startsWith('{')) {
      // Not JSON: the runner is talking to a human — a version-solving wall, a
      // load error. Relay it; the stream is usually about to stop and this text
      // is the only reason given.
      if (line.trim().isNotEmpty) stderr.writeln(line);
      return;
    }
    final Object? decoded;
    try {
      decoded = json.decode(line);
    } on FormatException {
      stderr.writeln(line);
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    switch (decoded['type']) {
      case 'testStart':
        final test = decoded['test'] as Map<String, dynamic>;
        final id = test['id'] as int;
        _names[id] = test['name'] as String;
        final metadata = test['metadata'];
        if (metadata is Map<String, dynamic>) {
          final reason = metadata['skipReason'];
          if (reason is String) _skipReasons[id] = reason;
        }
      case 'testDone':
        if (decoded['hidden'] == true) return;
        final id = decoded['testID'] as int;
        final name = _names[id] ?? '<unnamed>';
        if (decoded['skipped'] == true) {
          skipped.add(name);
          final reason = _skipReasons[id];
          if (reason != null) _skipReasonByName[name] = reason;
          stderr.writeln('  ~ $name');
        } else if (decoded['result'] == 'success') {
          passed.add(name);
          stderr.writeln('  + $name');
        } else {
          failed.add(name);
          stderr.writeln('  ! $name (${decoded['result']})');
        }
      case 'print':
        // A test's own `print` is zone-captured by the runner and delivered
        // here, not on the child's stderr, so it is invisible unless relayed.
        // These are the lines that explain a long silent stretch between two
        // `+`s, which on a suite whose tests take minutes each is most of what
        // there is to watch.
        //
        // A `markTestSkipped` reason arrives only here — there is no metadata
        // for it, because the test was not declared skipped — so it is picked
        // up on the way past.
        final printedFor = decoded['testID'];
        if (decoded['messageType'] == 'skip' && printedFor is int) {
          final said = decoded['message'];
          if (said is String) _skipReasons.putIfAbsent(printedFor, () => said);
        }
        stderr.writeln('    ${decoded['message']}');
      case 'error':
        // What a failure actually *said*. The `testDone` event carries only a
        // verdict, so without this a failing test reduces to its name — less
        // than the default reporter gives.
        final name = _names[decoded['testID'] as int] ?? '<unnamed>';
        _errors
            .putIfAbsent(name, () => [])
            .add(
              '${decoded['error']}\n${decoded['stackTrace']}'.trimRight(),
            );
      case 'done':
        runnerVerdict = decoded['success'] as bool?;
    }
  }

  /// How many tests actually executed, whatever they then reported.
  ///
  /// This — not [passed] — is what says whether the suite *ran*. A failing
  /// test executed just as much as a passing one; only a skip did not.
  int get executed => passed.length + failed.length;

  /// A run counts only when the runner reached its own verdict, nothing failed,
  /// and at least one test passed.
  ///
  /// That last clause matters: `dart test` exits 0 when every
  /// selected test skipped, so "no failures" alone cannot tell a pass from a
  /// suite that never ran.
  bool get ok => runnerVerdict == true && failed.isEmpty && passed.isNotEmpty;

  /// Each name followed by whatever it reported, indented under it.
  String _indented(Iterable<String> names) => names
      .map(
        (n) =>
            '  $n\n'
            '${(_errors[n] ?? const <String>[]).map((e) => '${e.split('\n').map((l) => '    $l').join('\n')}\n').join()}',
      )
      .join();

  /// The one count line, always printed.
  String get summary =>
      'e2e: ${passed.length} passed, ${skipped.length} '
      'skipped, ${failed.length} failed (dart test exited $runnerExitCode)';

  /// Why this run is not a pass, or null when it is one — exactly the negation
  /// of [ok], so the two can never disagree.
  ///
  /// Separate from [report] so the verdict can be asserted on: a branch ending
  /// in `exit(1)` would kill the process asserting it.
  ///
  /// The branch order is load-bearing. The two "did anything happen" questions
  /// are asked against [executed] rather than [passed], because a run whose
  /// only test failed has `passed.isEmpty` — and asking those questions of
  /// [passed] answers "nothing was selected to run … Check the paths, --tags
  /// and -n you passed", with the failure it has just printed sitting directly
  /// above. `1 failed + 2 skipped` reaches the same defect by the other branch,
  /// reporting "all 2 of them skipped".
  String? get diagnosis {
    if (ok) return null;

    if (runnerVerdict == null) {
      return 'the test runner never reported a verdict; it exited '
          '$runnerExitCode partway through. Read its output above — the '
          '$executed test(s) that did run are a prefix of an unknown '
          'whole, and none of this is a pass.';
    }
    if (executed == 0 && skipped.isEmpty) {
      return 'nothing was selected to run (dart test exited '
          '$runnerExitCode). Check the paths, --tags and -n you passed.';
    }
    if (executed == 0) {
      return 'not one test actually ran — all ${skipped.length} of them '
          'skipped. `dart test` exits 0 for this, which is why it needs '
          'saying: this is not a pass, it is a suite that never executed. '
          'The skip reasons are above; on macOS the usual cause is a missing '
          'Screen Recording or Accessibility permission, and off macOS it is '
          'that most of this suite is macOS-only.';
    }
    if (failed.isEmpty) {
      // The runner declared failure without any test carrying it. A test that
      // throws *after* its own `testDone` — a stray async error, a late
      // teardown — arrives exactly this way: an error event and a failing
      // `done`, with nothing to attribute it to.
      return 'the run failed without a failing test — something threw outside '
          'a test\'s own lifetime:\n${_indented(_errors.keys)}';
    }
    return '${failed.length} test(s) failed:\n${_indented(failed)}';
  }

  /// One line per skipped test, each carrying why it skipped.
  ///
  /// The reason is the whole content of a skip. Without it the summary says a
  /// platform's tests did not run and nothing about whether that was a bench
  /// with nothing plugged into it or a detector that had stopped working. The
  /// reasons do appear in the live stream as `Skip:` lines, but on a suite
  /// whose tests take minutes each those are thousands of lines above the
  /// summary, which is the part anyone reads.
  ///
  /// A getter rather than writes inside [report] so it can be asserted on,
  /// for the same reason [diagnosis] is one.
  Iterable<String> get skipReport => skipped.map((name) {
    final why = _skipReasonByName[name];
    return 'e2e: skipped — $name${why == null ? '' : ' — $why'}';
  });

  void report() {
    stderr.writeln('');
    for (final line in skipReport) {
      stderr.writeln(line);
    }
    stderr.writeln(summary);
    final why = diagnosis;
    if (why != null) _fail(why);
  }
}

Never _fail(String message) {
  stderr.writeln('');
  stderr.writeln('e2e: $message');
  exit(1);
}
