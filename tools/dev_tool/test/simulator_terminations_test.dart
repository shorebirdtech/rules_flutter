/// The iOS Simulator's record of how an app's process ended tells a close
/// from a crash. The messages here are RunningBoard's, as `log stream` printed
/// them on an iOS 27.2 simulator for each way of ending an app; the two not
/// seen there (a close the app resisted, a watchdog kill) are written to the
/// same format.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_bazel_dev_tool/simulator_terminations.dart';
import 'package:test/test.dart';

String _line(String message) =>
    json.encode({'processID': 74401, 'eventMessage': message});

String _record(String tuple, {String bundleId = 'com.example.app'}) => _line(
  '[app<$bundleId((null))>:4242] termination reported by launchd $tuple',
);

void main() {
  test('reads the pid, bundle and launchd report out of a record', () {
    final t = SimulatorTermination.parse(
      _record('(10, 4227595259, 9)', bundleId: 'com.apple.Preferences'),
    )!;

    expect(t.bundleId, 'com.apple.Preferences');
    expect(t.pid, 4242);
    expect(t.namespace, 10);
    expect(t.code, 0xfbfbfbfb);
    expect(t.status, 9);
  });

  test('is not misled by other lines, or the banner quoting the predicate', () {
    expect(
      SimulatorTermination.parse(
        'Filtering the log data using "${simulatorTerminationPredicate('com.example.app')}"',
      ),
      isNull,
    );
    expect(
      SimulatorTermination.parse(
        _line(
          '[app<com.example.app((null))>:4242] Terminating with context: ...',
        ),
      ),
      isNull,
    );
    expect(SimulatorTermination.parse('{not json'), isNull);
  });

  group('closed, not crashed:', () {
    test('the app ending itself with code 0', () {
      final t = SimulatorTermination.parse(_record('(0, 0, 0)'))!;
      expect(t.closed, isTrue);
      expect(t.how, 'exited with code 0');
    });

    test(
      'a close from the app switcher, which the app takes gracefully: '
      'RunningBoard says what it meant before the app exits with 0',
      () async {
        final lines = StreamController<String>();
        final records = SimulatorTerminations(lines.stream);
        lines
          ..add(
            _line(
              'Setting intended exit status on [app<com.example.app((null))>'
              ':4242] to <RBSProcessExitStatus| domain:frontboard(10) '
              'code:user-quit(0xdeadfa11)>',
            ),
          )
          ..add(_record('(0, 0, 0)'));

        final t = await records.of(4242);
        expect(t.closed, isTrue);
        expect(t.how, 'was closed from the app switcher');
        await records.close();
        await lines.close();
      },
    );

    test('a close from the app switcher the app did not take gracefully', () {
      final t = SimulatorTermination.parse(_record('(10, 3735943697, 9)'))!;
      expect(t.closed, isTrue);
      expect(t.how, 'was closed from the app switcher');
    });

    test('xcrun simctl terminate', () {
      final t = SimulatorTermination.parse(_record('(10, 4227595259, 9)'))!;
      expect(t.closed, isTrue);
      expect(t.how, contains('simctl terminate'));
    });
  });

  group('crashed:', () {
    test('a segmentation fault', () {
      final t = SimulatorTermination.parse(_record('(2, 11, 11)'))!;
      expect(t.closed, isFalse);
      expect(t.how, 'was killed by signal 11 (SIGSEGV)');
    });

    test('SIGKILL', () {
      final t = SimulatorTermination.parse(_record('(2, 9, 9)'))!;
      expect(t.closed, isFalse);
      expect(t.how, 'was killed by signal 9 (SIGKILL)');
    });

    test('an exit with a failing code', () {
      final t = SimulatorTermination.parse(_record('(0, 0, 768)'))!;
      expect(t.closed, isFalse);
      expect(t.how, 'exited with code 3');
    });

    test("FrontBoard's watchdog, naming its code", () {
      final t = SimulatorTermination.parse(_record('(10, 2343432205, 9)'))!;
      expect(t.closed, isFalse);
      expect(
        t.how,
        'was killed by signal 9 (SIGKILL) (launchd reason namespace 10, '
        'code 0x8badf00d)',
      );
    });
  });

  test('a record is found by pid, whether it came before or after the '
      'question', () async {
    final lines = StreamController<String>();
    final records = SimulatorTerminations(lines.stream);

    lines.add(_record('(2, 11, 11)'));
    final early = records.of(4242);
    final late = records.of(4343);
    lines.add(
      _line(
        '[app<com.example.app((null))>:4343] termination reported by '
        'launchd (0, 0, 0)',
      ),
    );

    expect((await early).status, 11);
    expect((await late).closed, isTrue);
    await records.close();
    await lines.close();
  });
}
