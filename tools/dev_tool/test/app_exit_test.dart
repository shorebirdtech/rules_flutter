/// When a launched app's VM service cannot be reached, the launcher asks the
/// device whether the app is still there ([Device.whyAppExited]). The property
/// for every device that launches an app the tool can watch: an app that
/// announced its VM service and then died is reported as exited, with the end
/// of its output; one that is still running is not.
///
/// Android's and the physical iOS device's cases sit beside their launch tests
/// in `device_test.dart`, which holds the harnesses they need.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

const _vmServiceLine =
    'The Dart VM service is listening on http://127.0.0.1:12345/test=/';

/// Settled long past the longest wait the device under test is allowed.
const _longPast = Duration(minutes: 1);

void main() {
  group('a desktop app', () {
    late Directory bundleRoot;
    setUp(() {
      bundleRoot = Directory.systemTemp.createTempSync('app_exit_test');
      Directory(p.join(bundleRoot.path, 'MyApp.app')).createSync();
      File(
        p.join(bundleRoot.path, 'MyApp.app', 'MyApp.app.exe'),
      ).writeAsStringSync('exe');
    });
    tearDown(() => bundleRoot.deleteSync(recursive: true));

    final devices =
        <String, ({Device Function(ProcessStarter) build, bool posix})>{
          'macOS': (
            build: (start) => MacOSDevice(
              runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
              startProcess: start,
            ),
            posix: true,
          ),
          'Linux': (
            build: (start) => LinuxDevice(startProcess: start),
            posix: true,
          ),
          'Windows': (
            build: (start) => WindowsDevice(
              startProcess: start,
              makeStagingDir: () =>
                  Directory(p.join(bundleRoot.path, 'staged')).absolute
                    ..createSync(recursive: true),
            ),
            posix: false,
          ),
        };

    Future<(Device, AppInstance, FakeProcess)> launched(
      Device Function(ProcessStarter) build,
    ) async {
      final app = FakeProcess();
      final device = build((exe, args) async => app);
      final pending = device.launch(p.join(bundleRoot.path, 'MyApp.app'));
      await app.outputAttached;
      app.emitStdout(_vmServiceLine);
      return (device, await pending, app);
    }

    devices.forEach((name, cfg) {
      group(name, () {
        test('that died after announcing is said to have exited, with its '
            'last output', () async {
          final (device, instance, app) = await launched(cfg.build);
          app.emitStdout('flutter: about to fail');
          app.emitStderr('Unhandled exception: boom\n');
          app.complete(3);
          await pumpEventQueue();

          final why = await device.whyAppExited(instance);

          expect(
            why,
            allOf(
              contains('exited with code 3'),
              contains('after announcing its VM service'),
              contains('Unhandled exception: boom'),
              contains('about to fail'),
            ),
          );
        });

        test('that is still running is not said to have exited', () async {
          final (device, instance, _) = await launched(cfg.build);

          fakeAsync((async) {
            Object? verdict = 'unanswered';
            device.whyAppExited(instance).then((why) => verdict = why);
            async.flushMicrotasks();
            expect(
              verdict,
              'unanswered',
              reason: 'a running app is given time to be reported as exited',
            );
            async.elapse(_longPast);
            expect(verdict, isNull);
          });
        });

        // The OS tells this tool of a child's exit a moment after the child
        // refused the connection that is being explained, so an exit that
        // arrives during the question still counts.
        test('that dies while the question is being asked is still '
            'said to have exited', () async {
          final (device, instance, app) = await launched(cfg.build);

          final asked = device.whyAppExited(instance);
          app.emitStdout('flutter: last words');
          app.complete(9);

          expect(
            await asked,
            allOf(contains('exited with code 9'), contains('last words')),
          );
        });
      });
    });

    // `dart:io` reports a child killed by a signal as the negative signal
    // number; "exited with code -11" would hide what happened.
    for (final name in ['macOS', 'Linux']) {
      test('$name: an app killed by a signal is said to be', () async {
        final (device, instance, app) = await launched(devices[name]!.build);
        app.complete(-11);
        await pumpEventQueue();

        expect(
          await device.whyAppExited(instance),
          contains('was killed by signal 11'),
        );
      });
    }

    // A Windows exit code is a status, negative or not: 0xC0000005 reads
    // -1073741819 and is not a signal.
    test('Windows: a negative exit code is a status, not a signal', () async {
      final (device, instance, app) = await launched(
        devices['Windows']!.build,
      );
      app.complete(-1073741819);
      await pumpEventQueue();

      expect(
        await device.whyAppExited(instance),
        contains('exited with code -1073741819'),
      );
    });
  });

  group('an iOS Simulator app', () {
    const bundleId = 'com.example.test';
    const pid = 1234;

    /// A simulator whose `kill -0 <pid>` answers [killAnswer] once a test has
    /// set it, and whose launch announces its VM service at once.
    Future<
      ({
        IOSSimulatorDevice device,
        AppInstance instance,
        FakeProcess output,
        FakeProcess terminations,
        List<List<String>> kills,
        void Function(ProcessResult) answerKill,
      })
    >
    launched() async {
      var killAnswer = ProcessResult(0, 0, '', '');
      final kills = <List<String>>[];
      final output = FakeProcess();
      final terminations = FakeProcess();
      final sim = FakeSimulatorLog();
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: bundleId,
        runProcess: sim.run((exe, args) async {
          if (exe == 'kill') {
            kills.add([...args]);
            return killAnswer;
          }
          return simctlOkWithPid(args, pid);
        }),
        startProcess: sim.start((exe, args) async {
          if (args.any((a) => a.contains('termination reported by launchd'))) {
            return terminations;
          }
          if (args.contains('ndjson')) {
            final discovery = FakeProcess();
            unawaited(
              discovery.outputAttached.then(
                (_) => discovery.emitStdout(
                  json.encode({
                    'processID': pid,
                    'eventMessage': _vmServiceLine,
                  }),
                ),
              ),
            );
            return discovery;
          }
          return output;
        }),
      );
      // A record that is not coming is waited for this long, not the real
      // bound.
      device
        ..terminationRecordBound = const Duration(milliseconds: 10)
        ..goneRecordBound = const Duration(milliseconds: 10);
      final instance = await device.launch('/path/to/MyApp.app');
      kills.clear();
      return (
        device: device,
        instance: instance,
        output: output,
        terminations: terminations,
        kills: kills,
        answerKill: (r) => killAnswer = r,
      );
    }

    String record(String tuple) => json.encode({
      'processID': 99,
      'eventMessage':
          '[app<$bundleId((null))>:$pid] termination reported by launchd '
          '$tuple',
    });

    test('closed from the app switcher is said to have been closed, which '
        'is not a crash', () async {
      final sim = await launched();
      sim.terminations.emitStdout(record('(0, 0, 0)'));

      final exit = await sim.device.howAppExited(sim.instance);

      expect(exit!.closed, isTrue);
      expect(exit.account, contains('$bundleId (pid $pid)'));
      expect(sim.kills, isEmpty, reason: 'the record is the answer');
    });

    test('terminated with simctl is said to have been closed', () async {
      final sim = await launched();
      sim.terminations.emitStdout(record('(10, 4227595259, 9)'));

      final exit = await sim.device.howAppExited(sim.instance);

      expect(exit!.closed, isTrue);
      expect(exit.account, contains('simctl terminate'));
    });

    test('killed by a signal is said to have crashed, with the signal and '
        'its log', () async {
      final sim = await launched();
      sim.output.emitStdout('  "eventMessage" : "about to fault",');
      await pumpEventQueue();
      sim.terminations.emitStdout(record('(2, 11, 11)'));

      final exit = await sim.device.howAppExited(sim.instance);

      expect(exit!.closed, isFalse);
      expect(
        exit.account,
        allOf(contains('signal 11 (SIGSEGV)'), contains('about to fault')),
      );
      expect(await sim.device.whyAppExited(sim.instance), exit.account);
    });

    test('gone, with the record arriving late, is said to have been closed '
        'all the same', () async {
      final sim = await launched();
      sim.device.goneRecordBound = const Duration(seconds: 5);
      sim.answerKill(ProcessResult(0, 1, '', 'kill: $pid: No such process'));
      // The record arrives once the process check has answered.
      sim.device.terminationRecordBound = Duration.zero;
      final asked = sim.device.howAppExited(sim.instance);
      await pumpEventQueue();
      expect(sim.kills, isNotEmpty);
      sim.terminations.emitStdout(record('(10, 4227595259, 9)'));

      expect((await asked)!.closed, isTrue);
    });

    test("another process's end says nothing about this one", () async {
      final sim = await launched();
      sim.terminations.emitStdout(
        json.encode({
          'processID': 99,
          'eventMessage':
              '[app<$bundleId((null))>:${pid + 1}] termination reported by '
              'launchd (0, 0, 0)',
        }),
      );

      expect(await sim.device.howAppExited(sim.instance), isNull);
    });

    test(
      'whose process is gone with no record is said to have exited, with '
      'its log',
      () async {
        final sim = await launched();
        sim.output.emitStdout(
          '  "eventMessage" : "Terminating app due to uncaught exception",',
        );
        await pumpEventQueue();
        sim.answerKill(ProcessResult(0, 1, '', 'kill: $pid: No such process'));

        final why = await sim.device.whyAppExited(sim.instance);

        expect(sim.kills, [
          ['-0', '$pid'],
        ], reason: 'liveness is asked of the pid the launch named');
        expect(
          why,
          allOf(
            contains(bundleId),
            contains('pid $pid'),
            contains('exited after announcing its VM service'),
            contains('Terminating app due to uncaught exception'),
          ),
        );
      },
    );

    test('whose process is there is not said to have exited', () async {
      final sim = await launched();

      expect(await sim.device.whyAppExited(sim.instance), isNull);
    });

    // `kill -0` also fails for a process this user may not signal. That is
    // not the process being gone, and saying so would blame the app for the
    // check's own failure.
    test(
      'is not declared gone because the liveness check was refused',
      () async {
        final sim = await launched();
        sim.answerKill(
          ProcessResult(0, 1, '', 'kill: $pid: Operation not permitted'),
        );

        expect(await sim.device.whyAppExited(sim.instance), isNull);
      },
    );
  });
}

/// A fake `simctl` that names [pid] as the process `simctl launch` started.
ProcessResult simctlOkWithPid(List<String> args, int pid) =>
    args.length > 3 && args[0] == 'simctl' && args[1] == 'launch'
    ? ProcessResult(0, 0, '${args[3]}: $pid\n', '')
    : ProcessResult(0, 0, '', '');
