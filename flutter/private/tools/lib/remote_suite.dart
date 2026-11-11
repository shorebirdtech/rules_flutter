/// The host half of `package:test`'s `RemoteListener` protocol, for a suite that
/// runs in another process and is driven from here.
///
/// A test program that has called `RemoteListener.start` answers this protocol
/// whatever carries it: `flutter_test_runner.dart` carries it over a WebSocket
/// the `flutter_tester` bootstrap dials, and an integration test carries it
/// over the app's VM service. [RemoteSuiteDriver] owns what is the same for
/// both: framing, the channel multiplexing, the handshake, walking the suite
/// tree, selecting tests, one test's lifetime, the failure summary and the
/// JUnit report. A [SuiteTransport] owns what differs.
///
/// Wire protocol (mirrors `package:test`'s `flutter_platform.dart`):
///   - A transport carries JSON text of `[id, data]` lists, plus `[id]` for
///     channel-close. id 0 is the default channel.
///   - We send `{type: 'initial', metadata, platform, ...}` on id 0. The host
///     speaks first: a bootstrap answers, it does not announce itself.
///   - The bootstrap responds `{type: 'success', root: <groupTree>}` on id 0;
///     each test in the tree carries a `channel` id (bootstrap-created).
///   - To run a test, we allocate our own outputId and send
///     `{command: 'run', channel: outputId}` on `testChannel + 1`. The
///     bootstrap replies with `state-change`/`error`/`message`/`complete`
///     events on `outputId + 1`, which we deliver back to our test handler.
///   - When the suite is exhausted we send `{type: 'close'}` on id 0.
///
/// Bazel's test protocol wins wherever it has one: the suite's default timeout
/// is Bazel's own (`TEST_TIMEOUT`), not `package:test`'s 30 seconds (see
/// `suite_annotations.dart`), and `--test_filter`, sharding, tag selection (`DART_TEST_TAGS`) and the per-case
/// XML report follow `bazel_test_protocol.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bazel_test_protocol.dart';

export 'bazel_test_protocol.dart'
    show TagSelection, TestSelection, parseUpdateGoldens;

/// How a suite's messages travel between this host and the program running it.
abstract interface class SuiteTransport {
  /// Each message the program sent, as the JSON text it was sent as.
  Stream<String> get incoming;

  /// Sends [json], an already encoded message, to the program. A transport that
  /// has been lost drops it.
  void send(String json);

  /// Ends the conversation politely, once the suite has been told to close.
  Future<void> close();

  /// Completes, once, when the program can no longer be reached, with why
  /// (null when the transport has no better word than that it closed). Never
  /// completes while the program is reachable.
  Future<String?> get lostReason;

  /// Stops a program that has stopped answering ([why] says how), for a run
  /// that is giving up on it: what [close] asks politely, done by force.
  Future<void> abandon(String why);
}

/// How the per-test ceiling the wedged-test backstop waits out is derived.
///
/// Bazel exports the target's timeout in `TEST_TIMEOUT` (seconds), so honour it
/// and stay a beat inside: the backstop exists to name a wedged test here
/// rather than let it run out Bazel's clock, and a flat bound silently overrode
/// whatever `--test_timeout` a longer-running test was given. Outside
/// `bazel test` there is no budget to derive one from, so five minutes stands.
///
/// Public because the test reaches it directly.
Duration testCeiling(String? bazelTestTimeout) {
  final seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) return const Duration(minutes: 5);
  final margin = seconds ~/ 20;
  return Duration(seconds: seconds - (margin < 10 ? 10 : margin));
}

/// Passes a suite that is not run on this host, as `package:test` does for a
/// suite whose `@TestOn` does not match: the program is never started, [note]
/// says why, and the report holds no case. Returns the exit status, zero.
///
/// This is not the failure of a suite that registers no test: that is a
/// program that ran and declared nothing, and this suite was never asked to
/// run.
Future<int> reportSuiteNotRun({
  required String suitePath,
  required String note,
  required String logPrefix,
  String? xmlOutput,
  StringSink? out,
}) async {
  (out ?? stdout).writeln('$logPrefix: $suitePath is not run: $note');
  if (xmlOutput != null) {
    await File(xmlOutput)
        .writeAsString(junitXml(const [], suiteName: suitePath));
  }
  return 0;
}

/// What a suite run came to.
class SuiteOutcome {
  SuiteOutcome._();

  int passed = 0;
  int failed = 0;
  int skipped = 0;
  bool _suiteError = false;

  /// Every case in the order it ran, for the JUnit report.
  final List<TestCaseResult> cases = [];

  /// Whether any test failed, or the suite itself could not run.
  bool get hasFailure => failed > 0 || _suiteError;

  /// The process exit status this outcome asks for.
  int get exitCode => hasFailure ? 1 : 0;

  /// One line saying how many tests passed, failed and were skipped.
  String summary() {
    final pieces = <String>[
      if (passed > 0) '$passed passed',
      if (failed > 0) '$failed failed',
      if (skipped > 0) '$skipped skipped',
    ];
    final body = pieces.isEmpty ? 'no tests' : pieces.join(', ');
    return '\n$body${_suiteError ? ' (suite error)' : ''}';
  }
}

/// Drives one suite over [transport], once.
class RemoteSuiteDriver {
  /// [suitePath] names the suite in the handshake and the JUnit report.
  /// [metadata] is the suite's `Metadata`, serialized, which the handshake
  /// carries and `RemoteListener` applies to every group and test: the file's
  /// annotations with Bazel's timeout merged in (`SuiteAnnotations`). Without
  /// one the suite has no annotations and no timeout.
  /// [logPrefix] starts the lines this writes to [err], and [out] and [err]
  /// default to the process's own streams.
  ///
  /// A suite that registers no test at all is a failure when the selection did
  /// not narrow it: a program that ran to its end without declaring a test has
  /// not been tested, and a green result would say it had.
  RemoteSuiteDriver(
    this.transport, {
    required this.suitePath,
    Map<String, Object?>? metadata,
    this.logPrefix = 'flutter_test',
    StringSink? out,
    StringSink? err,
    bool? asciiGlyphs,
  }) : metadata = metadata ?? _defaultMetadata(),
       _out = out ?? stdout,
       _err = err ?? stderr,
       _asciiGlyphs = asciiGlyphs ?? !stdout.supportsAnsiEscapes;

  final SuiteTransport transport;
  final String suitePath;
  final Map<String, Object?> metadata;
  final String logPrefix;
  final StringSink _out;
  final StringSink _err;
  final bool _asciiGlyphs;

  /// Per-channel inbound dispatchers, keyed by inputId.
  final Map<int, void Function(Object?)> _inbound = {};

  /// Pending test completers indexed by their reply-channel inputId. When the
  /// transport is lost mid-suite, that surfaces as a failure on every
  /// outstanding test so a `complete` event that will never arrive cannot hang
  /// the run.
  final Map<int, Completer<void>> _pendingTests = {};

  /// MultiChannel-compatible counter for our locally-allocated channels.
  /// `package:stream_channel`'s MultiChannel allocates outputId = nextId,
  /// inputId = nextId+1, then increments by 2.
  int _nextId = 1;

  bool _lost = false;
  String? _lostWhy;

  /// Allocates a virtual channel pair for our side.
  ({int outputId, int inputId}) _allocChannel() {
    final out = _nextId;
    final inp = _nextId + 1;
    _nextId += 2;
    return (outputId: out, inputId: inp);
  }

  void _send(int outputId, Object? data) {
    if (_lost) return;
    transport.send(json.encode([outputId, data]));
  }

  /// Runs the suite: handshake, every test [selection] keeps, the JUnit report
  /// at [xmlOutput] if given, then [afterSuite], then the close message and
  /// the transport's own [SuiteTransport.close].
  ///
  /// [afterSuite] runs while the program is still alive, which is what
  /// anything that inspects it (coverage) needs. [ceiling] bounds the
  /// handshake and each test, inside Bazel's own budget, so a wedged one is
  /// named here instead of the whole target being killed with no word of which.
  Future<SuiteOutcome> run({
    TestSelection? selection,
    String? xmlOutput,
    required Duration ceiling,
    Future<void> Function()? afterSuite,
  }) async {
    selection ??= TestSelection();
    final outcome = SuiteOutcome._();
    if (selection.orderingSeed case final seed?) {
      // As package:test prints it, `random`'s seed too, so the test's log
      // says how to repeat the order.
      _out.writeln(
        'Shuffling test order with --test-randomize-ordering-seed=$seed',
      );
    }

    // Default channel handler: the suite tree, plus print/error events. Resolves
    // `suiteReady` once the program finishes registering tests (or surfaces a
    // load failure).
    final suiteReady = Completer<Map<String, dynamic>?>();
    _inbound[0] = (data) {
      final msg = (data as Map).cast<String, dynamic>();
      switch (msg['type']) {
        case 'success':
          if (!suiteReady.isCompleted) {
            suiteReady.complete((msg['root'] as Map).cast<String, dynamic>());
          }
        case 'loadException':
          _err.writeln('$logPrefix: load failure — ${msg['message']}');
          if (!suiteReady.isCompleted) suiteReady.complete(null);
        case 'error':
          final err = (msg['error'] as Map).cast<String, dynamic>();
          _err.writeln(
            '$logPrefix: top-level error — ${err['message']}\n'
            '${err['stackChain']}',
          );
          if (!suiteReady.isCompleted) suiteReady.complete(null);
        case 'print':
          _out.writeln(msg['line']);
      }
    };

    final incoming = transport.incoming.listen(_onMessage);
    unawaited(
      transport.lostReason.then((why) {
        _lost = true;
        _lostWhy ??= why;
        if (!suiteReady.isCompleted) suiteReady.complete(null);
        for (final c in _pendingTests.values) {
          if (!c.isCompleted) c.complete();
        }
        _pendingTests.clear();
      }),
    );

    try {
      _send(0, _initialMessage());

      final root = await suiteReady.future.timeout(
        ceiling,
        onTimeout: () => null,
      );

      if (root != null) {
        switch (selection.select(root, program: logPrefix)) {
          case RunThese(:final tree):
            await _runGroup(tree, outcome, ceiling);
          case NoneRegistered():
            _record(outcome, 'the suite registered no tests');
          case FixedSelectionEmpty(:final message):
            outcome._suiteError = true;
            _err.writeln(message);
          case NarrowedToNothing(:final note):
            _out.writeln(note);
        }
      } else {
        _record(
          outcome,
          _lost
              ? 'suite did not load: ${_lostWhy ?? 'the connection closed'}'
              : 'suite did not load',
        );
      }
      if (xmlOutput != null) {
        await File(
          xmlOutput,
        ).writeAsString(junitXml(outcome.cases, suiteName: suitePath));
      }

      if (afterSuite != null) await afterSuite();

      // Politely shut down: tell RemoteListener to close, then close the
      // transport, which drains the program so that it can exit on its own.
      _send(0, {'type': 'close'});
      try {
        await transport.close();
      } catch (_) {
        // The transport is going away either way; what it throws is "already
        // closed", the state this asked for.
      }
    } finally {
      // Not awaited: the transport's own [SuiteTransport.close] has ended the
      // conversation, so this only detaches our listener, and what it returns
      // is a future of nothing.
      unawaited(incoming.cancel());
    }
    return outcome;
  }

  void _onMessage(String raw) {
    final list = json.decode(raw) as List;
    final id = (list[0] as num).toInt();
    if (list.length == 1) {
      // Channel closed by remote — drop the handler so we stop dispatching.
      _inbound.remove(id);
      return;
    }
    _inbound[id]?.call(list[1]);
  }

  void _record(SuiteOutcome outcome, String message) {
    outcome._suiteError = true;
    _err.writeln('$logPrefix: $message');
  }

  Future<void> _runGroup(
    Map<String, dynamic> group,
    SuiteOutcome outcome,
    Duration ceiling,
  ) async {
    final setUpAll = group['setUpAll'] as Map?;
    if (setUpAll != null) {
      await _runTest(
        setUpAll.cast<String, dynamic>(),
        outcome,
        ceiling,
        fixture: true,
      );
    }

    final entries = group['entries'] as List? ?? const [];
    for (final entry in entries) {
      final m = (entry as Map).cast<String, dynamic>();
      if (m['type'] == 'group') {
        await _runGroup(m, outcome, ceiling);
      } else {
        await _runTest(m, outcome, ceiling);
      }
    }

    final tearDownAll = group['tearDownAll'] as Map?;
    if (tearDownAll != null) {
      await _runTest(
        tearDownAll.cast<String, dynamic>(),
        outcome,
        ceiling,
        fixture: true,
      );
    }
  }

  /// Runs one test, or one `setUpAll`/`tearDownAll` when [fixture] is set: a
  /// fixture is reported only when it fails, as `package:test` hides it.
  ///
  /// `test['name']` is already the full name, enclosing groups included —
  /// `package:test` names a test that way when it is declared.
  Future<void> _runTest(
    Map<String, dynamic> test,
    SuiteOutcome outcome,
    Duration ceiling, {
    bool fixture = false,
  }) async {
    final testChannelId = (test['channel'] as num).toInt();
    final reportName = test['name'] as String? ?? '';

    final metadata = test['metadata'] as Map?;
    final skipReason = metadata == null ? null : metadata['skipReason'];
    final skipFlag = metadata == null
        ? false
        : (metadata['skip'] as bool? ?? false);
    if (!fixture && skipFlag) {
      _recordSkipped(outcome, reportName, skipReason as String?);
      return;
    }

    if (_lost) {
      _recordFailure(
        outcome,
        reportName,
        _FailureSummary(
          message:
              '${_lostWhy ?? 'the connection closed'} before this test ran',
          type: 'TestDeviceException',
          stackChain: '',
        ),
        Duration.zero,
        '',
      );
      return;
    }

    final ch = _allocChannel();
    final completer = Completer<void>();
    final started = Stopwatch()..start();
    final output = StringBuffer();
    _pendingTests[ch.inputId] = completer;
    _FailureSummary? failure;

    _inbound[ch.inputId] = (data) {
      final msg = (data as Map).cast<String, dynamic>();
      switch (msg['type']) {
        case 'state-change':
          // We rely on the explicit error events for failure tracking; state
          // changes alone don't tell us the difference between "still
          // running" and "failed and continuing".
          break;
        case 'error':
          final err = (msg['error'] as Map).cast<String, dynamic>();
          failure ??= _FailureSummary(
            message:
                err['message'] as String? ?? err['toString'] as String? ?? '',
            type: err['type'] as String? ?? 'TestFailure',
            stackChain: err['stackChain'] as String? ?? '',
          );
        case 'message':
          final mtype = msg['message-type'] as String? ?? 'print';
          final text = msg['text'] as String? ?? '';
          final line = mtype == 'print' ? text : '[$mtype] $text';
          _out.writeln(line);
          output.writeln(line);
        case 'complete':
          if (!completer.isCompleted) completer.complete();
      }
    };

    // Send "run" to the test channel. testChannelId is the bootstrap's
    // outputId for the test's virtual channel; per MultiChannel framing we send
    // back on testChannelId+1.
    _send(testChannelId + 1, {'command': 'run', 'channel': ch.outputId});

    // `test_api` enforces the timeout from the metadata we sent — Bazel's own,
    // or the test's — but that's a Timer: a test that spins synchronously
    // without yielding never lets it fire. This ceiling stays just inside
    // Bazel's limit, so a wedged test is named as a failure here instead of the
    // whole target being killed with no word on which test hung. The program
    // is stopped and the transport treated as gone, so the remaining tests
    // bail out fast.
    String? wedged;
    await completer.future.timeout(
      ceiling,
      onTimeout: () {
        wedged =
            'test "$reportName" did not finish within ${ceiling.inSeconds}s';
        _err.writeln('$logPrefix: $wedged.');
        _lost = true;
        _lostWhy = wedged;
        unawaited(transport.abandon(wedged!));
      },
    );
    _pendingTests.remove(ch.inputId);
    _inbound.remove(ch.inputId);

    if (_lost && failure == null) {
      failure = _FailureSummary(
        message: wedged ?? '${_lostWhy ?? 'the connection closed'} mid-test',
        type: 'TestDeviceException',
        stackChain: '',
      );
    }

    started.stop();
    if (failure != null) {
      _recordFailure(
        outcome,
        reportName,
        failure!,
        started.elapsed,
        output.toString(),
      );
    } else if (!fixture) {
      _recordSuccess(outcome, reportName, started.elapsed, output.toString());
    }
  }

  void _recordSuccess(
    SuiteOutcome outcome,
    String name,
    Duration elapsed,
    String output,
  ) {
    outcome.passed++;
    outcome.cases.add(TestCaseResult.passed(name, elapsed, output));
    _out.writeln('  PASS  $name');
  }

  void _recordFailure(
    SuiteOutcome outcome,
    String name,
    _FailureSummary summary,
    Duration elapsed,
    String output,
  ) {
    outcome.failed++;
    outcome.cases.add(
      TestCaseResult.failed(
        name,
        elapsed,
        output,
        failureType: summary.type,
        message: summary.message,
        detail: summary.toString(),
      ),
    );
    _out.writeln('  FAIL  $name');
    _out.writeln(_indent(summary.toString(), '        '));
  }

  void _recordSkipped(SuiteOutcome outcome, String name, String? reason) {
    outcome.skipped++;
    outcome.cases.add(TestCaseResult.skipped(name));
    _out.writeln(
      reason == null ? '  SKIP  $name' : '  SKIP  $name (${reason.trim()})',
    );
  }

  Map<String, dynamic> _initialMessage() {
    return {
      'type': 'initial',
      'metadata': metadata,
      'platform': suitePlatform(),
      'platformVariables': const <String>[],
      'collectTraces': true,
      'noRetry': true,
      'allowDuplicateTestNames': true,
      'foldTraceExcept': const <String>[],
      'foldTraceOnly': const <String>[],
      'path': suitePath,
      'asciiGlyphs': _asciiGlyphs,
      'ignoreTimeouts': false,
    };
  }

  /// A `Metadata.serialize` payload that says nothing: no annotations, no
  /// timeout.
  static Map<String, Object?> _defaultMetadata() {
    return {
      'testOn': null,
      'timeout': 'none',
      'skip': null,
      'skipReason': null,
      'verboseTrace': null,
      'chainStackTraces': null,
      'retry': null,
      'tags': const <String>[],
      'onPlatform': const <List<Object>>[],
      'forTag': const <String, Object?>{},
      'languageVersionComment': null,
    };
  }
}

/// The platform every suite runs as, serialized as `SuitePlatform` carries it:
/// runtime `vm`, compiler `kernel` and the host's operating system, which is
/// what `flutter test` reports for widget tests and integration tests alike,
/// whatever device runs them. Built-in `Runtime.vm` and `Compiler.kernel`
/// serialize as plain identifiers.
Map<String, Object?> suitePlatform() {
  return {
    'runtime': 'vm',
    'compiler': 'kernel',
    'os': _osIdentifier(),
    'inGoogle': false,
  };
}

String _osIdentifier() {
  if (Platform.isMacOS) return 'mac-os';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return 'none';
}

class _FailureSummary {
  _FailureSummary({
    required this.message,
    required this.type,
    required this.stackChain,
  });

  final String message;
  final String type;
  final String stackChain;

  @override
  String toString() {
    final buf = StringBuffer()
      ..writeln('$type: $message')
      ..write(stackChain);
    return buf.toString();
  }
}

String _indent(String body, String prefix) {
  return body.split('\n').map((l) => l.isEmpty ? l : '$prefix$l').join('\n');
}
