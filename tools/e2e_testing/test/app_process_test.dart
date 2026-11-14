import 'dart:io';

import 'package:rules_flutter_e2e_testing/app_process.dart';
import 'package:test/test.dart';

/// The app is a shell script, and Windows has no `sh`.
final _noSh = Platform.isWindows ? 'needs sh' : null;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('app_process_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String script(String body) {
    final file = File('${tmp.path}/app.sh')
      ..writeAsStringSync('#!/bin/sh\n$body');
    Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  group('AppProcess', () {
    test('waitForLine finds a line from either stream', () async {
      final app = await AppProcess.start(
        script('echo booting\necho "ready x=1" >&2\nsleep 30'),
      );
      try {
        final line = await app.waitForLine(
          'ready',
          timeout: const Duration(seconds: 10),
        );
        expect(line, 'ready x=1');
        expect(app.output, contains('booting'));
      } finally {
        await app.stop();
      }
    }, skip: _noSh);

    test('waitForLine sees a line printed before the call', () async {
      final app = await AppProcess.start(script('echo early\nsleep 30'));
      try {
        // Let the line arrive before asking for it.
        await app.waitForLine('early', timeout: const Duration(seconds: 10));
        final again = await app.waitForLine(
          RegExp('ear.y'),
          timeout: const Duration(seconds: 1),
        );
        expect(again, 'early');
      } finally {
        await app.stop();
      }
    }, skip: _noSh);

    test(
      'waitForLine gives null at once when the app exits without it',
      () async {
        final app = await AppProcess.start(script('echo bye'));
        final stopwatch = Stopwatch()..start();
        final line = await app.waitForLine(
          'never',
          timeout: const Duration(seconds: 30),
        );
        expect(line, isNull);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
        await app.whenExited;
        expect(app.exited, isTrue);
        expect(app.exitCode, 0);
      },
      skip: _noSh,
    );

    test('waitForLine gives null when the time runs out', () async {
      final app = await AppProcess.start(script('sleep 30'));
      try {
        final line = await app.waitForLine(
          'never',
          timeout: const Duration(milliseconds: 300),
        );
        expect(line, isNull);
        expect(app.exited, isFalse);
      } finally {
        await app.stop();
      }
    }, skip: _noSh);

    test('stop kills an app that ignores the request to quit', () async {
      final app = await AppProcess.start(
        script('trap "" TERM\necho up\nwhile true; do sleep 1; done'),
      );
      await app.waitForLine('up', timeout: const Duration(seconds: 10));
      await app.stop(grace: const Duration(milliseconds: 300));
      expect(app.exited, isTrue);
    }, skip: _noSh);

    test('start names a binary that is not there', () {
      expect(
        AppProcess.start('${tmp.path}/missing'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
