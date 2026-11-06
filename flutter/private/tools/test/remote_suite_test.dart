// The host half of the `RemoteListener` protocol, driven against an in-memory
// program that answers it. No process, socket or Bazel: the protocol is the
// thing under test, and a fake transport can lose the program at the exact
// message a real one is hard to catch at.
//
// Tagged `runfiles`: `fake_async` reaches this test through Bazel's hub, not
// this package's pubspec, so a bare `dart test` cannot load the file.
@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_rule_tools/remote_suite.dart';
import 'package:test/test.dart';

/// How a fake test behaves when asked to run.
enum _Behaviour { passes, fails, hangs, skipped }

/// A program that answers the protocol: a suite of named tests, each behaving
/// as told, behind a [SuiteTransport] the driver cannot tell from a real one.
class _FakeProgram implements SuiteTransport {
  _FakeProgram(Map<String, _Behaviour> tests, {this.diesDuring, this.lose}) {
    var channel = 2;
    for (final MapEntry(:key, :value) in tests.entries) {
      _tests.add((
        name: key,
        behaviour: value,
        channel: channel,
      ));
      channel += 2;
    }
  }

  /// The test during which the program disappears, with the reason it gives.
  final String? diesDuring;
  final String? lose;

  final _tests = <({String name, _Behaviour behaviour, int channel})>[];
  final _incoming = StreamController<String>();
  final _lost = Completer<String?>();

  /// Every message the driver sent, decoded.
  final sent = <List<Object?>>[];

  /// The names of the tests the driver asked to run, in order.
  final ran = <String>[];

  /// What [abandon] was told.
  final abandoned = <String>[];
  var closed = false;

  /// What the program answers the handshake with; null for a suite of [_tests].
  Map<String, Object?>? handshakeReply;

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<String?> get lostReason => _lost.future;

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> abandon(String why) async => abandoned.add(why);

  void _reply(int channel, Object? data) =>
      scheduleMicrotask(() => _incoming.add(json.encode([channel, data])));

  @override
  void send(String raw) {
    final message = json.decode(raw) as List;
    sent.add(message);
    final id = message[0] as int;
    final data = message.length > 1 ? message[1] : null;
    if (id == 0 && data is Map && data['type'] == 'initial') {
      _reply(0, handshakeReply ?? {'type': 'success', 'root': _root()});
    } else if (data is Map && data['command'] == 'run') {
      final test = _tests.firstWhere((t) => t.channel + 1 == id);
      ran.add(test.name);
      final reply = (data['channel'] as int) + 1;
      if (test.name == diesDuring) {
        scheduleMicrotask(() => _lost.complete(lose));
        return;
      }
      switch (test.behaviour) {
        case _Behaviour.passes:
          _reply(reply, {
            'type': 'message',
            'message-type': 'print',
            'text': 'hi',
          });
          _reply(reply, {'type': 'complete'});
        case _Behaviour.fails:
          _reply(reply, {
            'type': 'error',
            'error': {
              'message': 'Expected: <1>\n  Actual: <2>',
              'type': 'TestFailure',
              'stackChain': 'frame 1\n',
            },
          });
          _reply(reply, {'type': 'complete'});
        case _Behaviour.hangs:
        case _Behaviour.skipped:
          break;
      }
    }
  }

  Map<String, Object?> _root() => {
    'type': 'group',
    'name': '',
    'entries': [
      for (final t in _tests)
        {
          'type': 'test',
          'name': t.name,
          'channel': t.channel,
          if (t.behaviour == _Behaviour.skipped)
            'metadata': {'skip': true, 'skipReason': 'not here'},
        },
    ],
  };
}

RemoteSuiteDriver _driver(
  _FakeProgram program, {
  StringBuffer? err,
}) => RemoteSuiteDriver(
  program,
  suitePath: 'integration_test/x_test.dart',
  out: StringBuffer(),
  err: err ?? StringBuffer(),
  asciiGlyphs: true,
);

const _ceiling = Duration(minutes: 1);

void main() {
  group('a suite of three tests, one of them failing', () {
    late _FakeProgram program;
    late SuiteOutcome outcome;
    late String xml;

    setUp(() async {
      program = _FakeProgram({
        'a passes': _Behaviour.passes,
        'b fails': _Behaviour.fails,
        'c passes': _Behaviour.passes,
      });
      final dir = Directory.systemTemp.createTempSync('remote_suite_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      outcome = await _driver(
        program,
      ).run(ceiling: _ceiling, xmlOutput: '${dir.path}/out.xml');
      xml = File('${dir.path}/out.xml').readAsStringSync();
    });

    test('reports two passed and one failed, and asks for a failing exit', () {
      expect(outcome.passed, 2);
      expect(outcome.failed, 1);
      expect(outcome.exitCode, isNonZero);
      expect(outcome.summary(), contains('2 passed, 1 failed'));
    });

    test('writes JUnit with all three cases, the failing one a <failure>', () {
      expect('<testcase '.allMatches(xml), hasLength(3));
      expect(
        xml,
        contains(
          '<testsuite name="integration_test/x_test.dart" tests="3" failures="1"',
        ),
      );
      expect(
        xml,
        matches(
          RegExp(
            r'<testcase name="b fails"[^>]*><failure message="Expected: &lt;1&gt;"',
          ),
        ),
      );
    });

    test('runs every test, in order, and then closes the suite', () {
      expect(program.ran, ['a passes', 'b fails', 'c passes']);
      expect(program.sent.last, [
        0,
        {'type': 'close'},
      ]);
      expect(program.closed, isTrue);
    });
  });

  test('the host speaks first: nothing is sent before the handshake, and the '
      'handshake carries the suite path and Bazel\'s timeout', () async {
    final program = _FakeProgram({'a': _Behaviour.passes});
    await RemoteSuiteDriver(
      program,
      suitePath: 'p/x_test.dart',
      timeout: suiteTimeout('120'),
      out: StringBuffer(),
      err: StringBuffer(),
      asciiGlyphs: true,
    ).run(ceiling: _ceiling);

    final initial = program.sent.first;
    expect(initial[0], 0);
    final data = initial[1] as Map;
    expect(data['type'], 'initial');
    expect(data['path'], 'p/x_test.dart');
    expect((data['metadata'] as Map)['timeout'], suiteTimeout('120'));
  });

  group('selection', () {
    test('--test_filter runs only the tests whose full name matches', () async {
      final program = _FakeProgram({
        'counter increments': _Behaviour.passes,
        'counter resets': _Behaviour.passes,
        'other': _Behaviour.passes,
      });

      final outcome = await _driver(program).run(
        ceiling: _ceiling,
        selection: TestSelection(filter: RegExp('counter')),
      );

      expect(program.ran, ['counter increments', 'counter resets']);
      expect(outcome.passed, 2);
    });

    test('a shard runs its contiguous share of the tests, as before', () async {
      final tests = {for (final n in 'abcd'.split('')) n: _Behaviour.passes};
      final first = _FakeProgram(tests);
      final second = _FakeProgram(tests);

      await _driver(first).run(
        ceiling: _ceiling,
        selection: TestSelection(totalShards: 2, shardIndex: 0),
      );
      await _driver(second).run(
        ceiling: _ceiling,
        selection: TestSelection(totalShards: 2, shardIndex: 1),
      );

      expect(first.ran, ['a', 'b']);
      expect(second.ran, ['c', 'd']);
    });

    test('a filter that matches nothing passes, since --test_filter must pass '
        'every target it does not touch', () async {
      final outcome = await _driver(_FakeProgram({'a': _Behaviour.passes})).run(
        ceiling: _ceiling,
        selection: TestSelection(filter: RegExp('nothing')),
      );

      expect(outcome.exitCode, 0);
    });

    test('a skipped test is reported as skipped and never run', () async {
      final program = _FakeProgram({'a': _Behaviour.skipped});

      final outcome = await _driver(program).run(ceiling: _ceiling);

      expect(outcome.skipped, 1);
      expect(program.ran, isEmpty);
      expect(outcome.exitCode, 0);
    });
  });

  group('a transport lost', () {
    test('mid-test fails that test with the transport\'s reason and the rest '
        'before they run, instead of hanging', () async {
      final program = _FakeProgram(
        {
          'a passes': _Behaviour.passes,
          'b dies': _Behaviour.passes,
          'c never runs': _Behaviour.passes,
        },
        diesDuring: 'b dies',
        lose: 'the app exited with 3',
      );
      final dir = Directory.systemTemp.createTempSync('remote_suite_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final outcome = await _driver(
        program,
      ).run(ceiling: _ceiling, xmlOutput: '${dir.path}/out.xml');

      expect(outcome.passed, 1);
      expect(outcome.failed, 2);
      expect(outcome.exitCode, isNonZero);
      final xml = File('${dir.path}/out.xml').readAsStringSync();
      expect(xml, contains('the app exited with 3 mid-test'));
      expect(xml, contains('the app exited with 3 before this test ran'));
      expect(program.ran, ['a passes', 'b dies']);
    });

    test('before the suite loaded is a suite error saying why', () async {
      final program = _FakeProgram({'a': _Behaviour.passes})
        ..handshakeReply = {'type': 'loadException', 'message': 'no such file'};
      final err = StringBuffer();

      final outcome = await _driver(program, err: err).run(ceiling: _ceiling);

      expect(outcome.exitCode, isNonZero);
      expect(err.toString(), contains('load failure — no such file'));
      expect(err.toString(), contains('suite did not load'));
    });
  });

  group('a suite that registers no tests', () {
    test('fails when the run was not narrowed', () async {
      final err = StringBuffer();

      final outcome = await _driver(
        _FakeProgram({}),
        err: err,
      ).run(ceiling: _ceiling);

      expect(outcome.exitCode, isNonZero);
      expect(err.toString(), contains('the suite registered no tests'));
    });

    test('passes when a filter or shard narrowed the run', () async {
      final outcome = await _driver(
        _FakeProgram({}),
      ).run(ceiling: _ceiling, selection: TestSelection(totalShards: 2));

      expect(outcome.exitCode, 0);
    });
  });

  test('a test that never finishes is named at the ceiling and the program is '
      'abandoned, instead of the target running out Bazel\'s clock', () {
    fakeAsync((async) {
      final program = _FakeProgram({
        'a passes': _Behaviour.passes,
        'b hangs': _Behaviour.hangs,
        'c later': _Behaviour.passes,
      });
      final err = StringBuffer();
      SuiteOutcome? outcome;
      _driver(
        program,
        err: err,
      ).run(ceiling: const Duration(seconds: 60)).then((o) => outcome = o);

      async.elapse(const Duration(seconds: 59));
      expect(outcome, isNull, reason: 'still inside the ceiling');
      expect(program.abandoned, isEmpty);

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();

      expect(program.abandoned, hasLength(1));
      expect(program.abandoned.single, contains('"b hangs"'));
      expect(program.abandoned.single, contains('60s'));
      expect(err.toString(), contains('"b hangs" did not finish within 60s'));
      expect(outcome!.passed, 1);
      expect(outcome!.failed, 2);
      expect(program.ran, ['a passes', 'b hangs']);
    });
  });

  group('suiteTimeout', () {
    test('is Bazel\'s TEST_TIMEOUT, not package:test\'s 30 seconds', () {
      expect(suiteTimeout('300'), {
        'duration': const Duration(seconds: 300).inMicroseconds,
        'scaleFactor': null,
      });
    });

    test('is never none under Bazel, so a test\'s own timeout still fires', () {
      // `Timeout.merge` lets `none` on either side win.
      expect(suiteTimeout('60'), isNot('none'));
    });

    test('is none outside bazel test, where there is no limit to state', () {
      expect(suiteTimeout(null), 'none');
      expect(suiteTimeout(''), 'none');
    });
  });

  group('testCeiling', () {
    test("derives the wedged-test backstop from Bazel's TEST_TIMEOUT, so a "
        'test given --test_timeout=1200 runs its full length', () {
      expect(testCeiling('1200').inSeconds, greaterThan(600));
    });

    test('stays inside the Bazel budget, so a wedged test is reported here '
        'rather than killed from outside with no diagnostic', () {
      expect(testCeiling('1200').inSeconds, lessThan(1200));
      expect(testCeiling('60').inSeconds, lessThan(60));
    });

    test('falls back to five minutes with no TEST_TIMEOUT — a direct run '
        'outside `bazel test` has no budget to derive one from', () {
      expect(testCeiling(null), const Duration(minutes: 5));
      expect(testCeiling(''), const Duration(minutes: 5));
      expect(testCeiling('not-a-number'), const Duration(minutes: 5));
      expect(testCeiling('0'), const Duration(minutes: 5));
    });
  });
}
