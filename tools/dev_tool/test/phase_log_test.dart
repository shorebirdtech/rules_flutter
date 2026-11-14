import 'dart:async';

import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/phase_log.dart';
import 'package:test/test.dart';

/// The `reload_phase` records [records] holds, as their structured fields.
List<Map<String, dynamic>> phaseRecords(Iterable<LogRecord> records) => [
  for (final r in records)
    if (r.object is Map && (r.object as Map)['message'] == 'reload_phase')
      Map<String, dynamic>.from(r.object as Map),
];

void main() {
  late List<LogRecord> records;

  setUp(() {
    records = [];
    final sub = Logger.root.onRecord.listen(records.add);
    addTearDown(sub.cancel);
  });

  test('formatElapsed reads in the unit a person uses', () {
    expect(formatElapsed(const Duration(milliseconds: 340)), '340ms');
    expect(formatElapsed(const Duration(milliseconds: 1200)), '1.2s');
    expect(formatElapsed(const Duration(seconds: 125)), '2m 05s');
  });

  test('a phase says it finished, with its name and a timing', () async {
    final log = PhaseLog('Hot reload');

    final value = await log.run('compile', () async => 7);

    expect(value, 7, reason: 'the body\'s own result is passed through');
    final line = phaseRecords(records).single;
    expect(line['phase'], 'compile');
    expect(line['event'], 'finished');
    expect(line['text'], matches(r'^Hot reload: compile finished in \d+ms$'));
    expect(line['ms'], isA<int>());
  });

  test('a phase that throws says it failed, and still throws', () async {
    final log = PhaseLog('Restart');

    await expectLater(
      log.run('apply', () async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );

    final line = phaseRecords(records).single;
    expect(line['event'], 'failed');
    expect(line['text'], contains('Restart: apply failed after'));
    expect(line['text'], contains('boom'));
  });

  test('the line is written before the caller continues', () async {
    final log = PhaseLog('Hot reload');
    final seenByCaller = <int>[];

    await log.run('compile', () async {});
    seenByCaller.add(phaseRecords(records).length);

    expect(seenByCaller, [1]);
  });

  test('finish says the command ended, and tells a mirror it is the last '
      'line', () async {
    final mirrored = <(String, bool)>[];
    final log = PhaseLog(
      'Hot reload',
      mirror: (text, {required finished}) => mirrored.add((text, finished)),
    );

    await log.run('compile', () async {});
    log.finish();

    expect(phaseRecords(records).map((r) => r['phase']), ['compile', 'total']);
    expect(mirrored.map((m) => m.$2), [false, true]);
    expect(mirrored.last.$1, startsWith('Hot reload finished in '));
  });

  test(
    'a phase that runs long says it is still running, until it ends',
    () async {
      final stillRunning = Completer<void>();
      final log = PhaseLog(
        'Hot reload',
        stillRunningAfter: const Duration(milliseconds: 1),
        mirror: (text, {required finished}) {
          if (text.contains('still running') && !stillRunning.isCompleted) {
            stillRunning.complete();
          }
        },
      );
      final release = Completer<void>();

      final running = log.run('bazel build', () => release.future);
      await stillRunning.future;
      release.complete();
      await running;

      final events = phaseRecords(records).map((r) => r['event']).toList();
      expect(events.first, 'running');
      expect(events.last, 'finished');
    },
  );
}
