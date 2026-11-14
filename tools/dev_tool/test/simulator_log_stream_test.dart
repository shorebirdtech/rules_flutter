import 'dart:async';
import 'dart:convert';

import 'package:flutter_bazel_dev_tool/simulator_log_stream.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _marker = 'flutter_bazel log stream listening 0123';

String _record(String message) => jsonEncode({
  'eventType': 'logEvent',
  'processID': 7,
  'eventMessage': message,
});

SimulatorLogStream _stream(FakeProcess helper) => SimulatorLogStream(
  helper,
  marker: _marker,
  messageOf: ndjsonEventMessage,
);

void main() {
  test('the predicate admits the marker alongside what it selected', () {
    expect(
      listeningPredicate('a == 1 AND b == 2', _marker),
      '(a == 1 AND b == 2) OR eventMessage == "$_marker"',
    );
  });

  test('a marker is new for every launch', () {
    expect(newListeningMarker(), isNot(newListeningMarker()));
  });

  group('SimulatorLogStream', () {
    test('passes on everything but the marker, and is listening once the '
        'marker arrives', () async {
      final helper = FakeProcess();
      final stream = _stream(helper);
      final read = stream.process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();
      var listening = false;
      unawaited(stream.listening.then((_) => listening = true));

      helper.emitStdout('Filtering the log data using "... == "$_marker""');
      helper.emitStdout(_record('before'));
      await pumpEventQueue();
      expect(listening, isFalse, reason: 'the banner quotes the marker');

      helper.emitStdout(_record(_marker));
      helper.emitStdout(_record('after'));
      await pumpEventQueue();
      expect(listening, isTrue);

      helper.complete(0);
      expect(await read, [
        'Filtering the log data using "... == "$_marker""',
        _record('before'),
        _record('after'),
      ]);
    });

    test('a helper that exits first is not listening, and says so', () async {
      final helper = FakeProcess();
      final stream = _stream(helper);
      helper.complete(1);
      await expectLater(
        stream.listening,
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('1')),
        ),
      );
    });
  });

  group('waitUntilListening', () {
    test('logs the marker only once every stream has started', () async {
      final a = FakeProcess();
      final b = FakeProcess();
      final streams = [_stream(a), _stream(b)];
      var logged = 0;
      final done = waitUntilListening(streams, () async {
        logged++;
        a.emitStdout(_record(_marker));
        b.emitStdout(_record(_marker));
      });

      a.emitStdout('Filtering the log data using "..."');
      await pumpEventQueue();
      expect(logged, 0, reason: 'b has not started');

      b.emitStdout('Filtering the log data using "..."');
      await done;
      expect(logged, greaterThanOrEqualTo(1));
    });

    // The banner comes at about the moment a stream attaches, not provably
    // after it: a stream that was not yet attached misses the marker, which
    // is logged again until it has arrived.
    test('logs the marker again for a stream that missed it', () async {
      final a = FakeProcess();
      final b = FakeProcess();
      final streams = [_stream(a), _stream(b)];
      var logged = 0;
      final done = waitUntilListening(streams, () async {
        logged++;
        a.emitStdout(_record(_marker));
        // b is attached only from the third.
        if (logged >= 3) b.emitStdout(_record(_marker));
      });
      a.emitStdout('banner');
      b.emitStdout('banner');

      await done;
      expect(logged, greaterThanOrEqualTo(3));
    });

    test('ends with the helper\'s exit when one exits first', () async {
      final a = FakeProcess();
      final b = FakeProcess();
      final done = waitUntilListening([_stream(a), _stream(b)], () async {});
      a.emitStdout('banner');
      b.complete(64);
      await expectLater(done, throwsStateError);
    });

    test('ends with the failure to log the marker', () async {
      final a = FakeProcess();
      final done = waitUntilListening([
        _stream(a),
      ], () async => throw StateError('syslog: not found'));
      a.emitStdout('banner');
      await expectLater(
        done,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'syslog: not found',
          ),
        ),
      );
    });
  });
}
