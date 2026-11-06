/// Properties of launching an app on an iOS Simulator by its UDID.
///
/// A simulator that is shut down, or that has only just been told to boot, is
/// the ordinary starting point of a run on a fresh CI machine and of the first
/// run after a reboot. What the person needs from the launch is that it either
/// works or says which step did not, however long the steps take:
///
///   * a step that fails is reported as that step's failure, with the tool's
///     own words, instead of surfacing later as a different step's error;
///   * a step that is merely slow is waited for, not failed on a clock.
///
/// The simulator here is a small state machine behind `xcrun simctl`: `boot`
/// starts a boot that finishes some time later, `bootstatus -b` boots if needed
/// and answers when the boot is done, and `install` and `launch` refuse a
/// device that is not booted with the words `simctl` uses for it. Time is
/// `package:fake_async`'s, so a ninety-second boot costs nothing to test.
///
/// What was measured against a real simulator (Xcode 27.2, an idle shut-down
/// iPhone): `install` on a shut-down device exits 149 with `Unable to lookup in
/// current state: Shutdown`; `boot` exits 0 at once; `boot` on a device already
/// booting or booted exits 149 with `Unable to boot device in current state`;
/// `bootstatus -b` blocks until the boot is done and exits 0. Not observed: an
/// `install` landing while the device was still `Booting` (on that machine it
/// was `Booted` by the next command), so a booting device's refusal is modelled
/// on the shut-down wording, not measured.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// `xcrun simctl` for one simulator, as far as a launch can tell.
class FakeSimulator {
  FakeSimulator({
    this.state = 'Shutdown',
    this.bootTime = const Duration(seconds: 8),
    this.bootFailure,
  }) {
    if (state == 'Booted') _booted.complete();
  }

  /// `Shutdown`, `Booting` or `Booted`: the words `simctl list` uses.
  String state;

  /// How long a boot takes once started.
  final Duration bootTime;

  /// When set, `boot` fails with this on stderr and the device stays as it was.
  final String? bootFailure;

  /// Every `xcrun` invocation, one line each, in order.
  final List<String> calls = [];

  /// The state the device was in at each `install`, in order.
  final List<String> installStates = [];

  final Completer<void> _booted = Completer<void>();

  bool _startBoot() {
    if (state != 'Shutdown') return false;
    state = 'Booting';
    Timer(bootTime, () {
      state = 'Booted';
      _booted.complete();
    });
    return true;
  }

  ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');

  ProcessResult _wrongState(String what) => ProcessResult(
    0,
    149,
    '',
    'An error was encountered processing the command (domain=com.apple.'
        'CoreSimulator.SimError, code=405):\n$what in current state: $state',
  );

  Future<ProcessResult> run(String executable, List<String> args) async {
    calls.add(args.join(' '));
    if (args.length < 2 || args[0] != 'simctl') return _ok();
    switch (args[1]) {
      case 'boot':
        if (bootFailure != null) return ProcessResult(0, 1, '', bootFailure!);
        // `simctl boot` on a device that is not shut down is an error with this
        // exit code, which is why a launch cannot read a nonzero exit as "the
        // boot failed".
        if (!_startBoot()) {
          return ProcessResult(
            0,
            149,
            '',
            'Unable to boot device in current state: $state',
          );
        }
        return _ok();
      case 'bootstatus':
        // `-b` is "boot it if it is not booted", and blocks until it is.
        if (state == 'Shutdown') {
          if (!args.contains('-b')) {
            return ProcessResult(0, 1, '', 'Unable to boot: device is $state');
          }
          if (bootFailure != null) {
            return ProcessResult(0, 1, '', bootFailure!);
          }
          _startBoot();
        }
        await _booted.future;
        return _ok('Status=4294967295, isTerminal=YES\n');
      case 'list':
        return _ok(
          jsonEncode({
            'devices': {
              'com.apple.CoreSimulator.SimRuntime.iOS-18-0': [
                {
                  'udid': 'SIM-UDID',
                  'name': 'iPhone',
                  'state': state,
                  'isAvailable': true,
                },
              ],
            },
          }),
        );
      case 'install':
        installStates.add(state);
        if (state != 'Booted') return _wrongState('Unable to lookup');
        return _ok();
      case 'launch':
        if (state != 'Booted') return _wrongState('Unable to launch');
        return _ok('${args[3]}: 1234\n');
    }
    return _ok();
  }
}

const _announcement =
    'The Dart VM service is listening on http://127.0.0.1:2222/k=/';

/// A launch on [simulator], driven under [async]. The discovery stream carries
/// the app's announcement [announceAfter] into the launch, or never if null.
({IOSSimulatorDevice device, Outcome<AppInstance> launched}) launchOn(
  FakeAsync async,
  FakeSimulator simulator, {
  Duration? announceAfter = const Duration(seconds: 1),
}) {
  final log = FakeSimulatorLog();
  final device = IOSSimulatorDevice(
    udid: 'SIM-UDID',
    bundleId: 'com.example.app',
    runProcess: log.run(simulator.run),
    startProcess: log.start((executable, args) async {
      final process = FakeProcess();
      if (args.contains('ndjson') && announceAfter != null) {
        unawaited(
          process.outputAttached.then((_) async {
            await Future<void>.delayed(announceAfter);
            process.emitStdout(
              jsonEncode({
                'eventType': 'logEvent',
                'processID': 1234,
                'eventMessage': 'flutter: $_announcement',
              }),
            );
          }),
        );
      }
      return process;
    }),
  );
  final launched = async.run((_) => track(device.launch('/build/Runner.app')));
  return (device: device, launched: launched);
}

/// Move [async] on by [by], in steps small enough that each turn of the real
/// microtask queue (where a stream subscription's cancel completes, which the
/// fake zone does not drive) gets its chance between them.
Future<void> elapse(FakeAsync async, Duration by) async {
  const step = Duration(seconds: 1);
  for (var left = by; left > Duration.zero; left -= step) {
    async.elapse(left < step ? left : step);
    await pumpEventQueue();
    async.flushMicrotasks();
  }
  for (var i = 0; i < 5; i++) {
    await pumpEventQueue();
    async.flushMicrotasks();
  }
}

void main() {
  group('launching on an already booted simulator', () {
    test('boots nothing, installs, and attaches to the app', () async {
      final async = FakeAsync();
      final simulator = FakeSimulator(state: 'Booted');
      final run = launchOn(async, simulator);

      await elapse(async, const Duration(seconds: 5));

      expect(run.launched.error, isNull, reason: '${run.launched.error}');
      expect(
        run.launched.value?.vmServiceUri,
        Uri.parse('http://127.0.0.1:2222/k=/'),
      );
      expect(simulator.installStates, ['Booted']);
    });

    test(
      'a slow app announcement within the first seconds is waited for',
      () async {
        final async = FakeAsync();
        final run = launchOn(
          async,
          FakeSimulator(state: 'Booted'),
          announceAfter: const Duration(seconds: 12),
        );

        await elapse(async, const Duration(seconds: 20));

        expect(
          run.launched.value?.vmServiceUri,
          Uri.parse('http://127.0.0.1:2222/k=/'),
        );
      },
    );
  });

  group('launching on a simulator that is shut down', () {
    // Every boot time a real machine produces is a valid one: a warm laptop
    // takes seconds, a first boot after a reboot or on a loaded CI runner takes
    // minutes. The property does not have a boot time it fails at.
    for (final bootTime in const [
      Duration(seconds: 2),
      Duration(seconds: 8),
      Duration(minutes: 2),
    ]) {
      test('installs only once the boot has finished, however long it takes '
          '(${bootTime.inSeconds}s boot)', () async {
        final async = FakeAsync();
        final simulator = FakeSimulator(bootTime: bootTime);
        final run = launchOn(async, simulator);

        await elapse(async, bootTime + const Duration(seconds: 30));

        expect(
          run.launched.error,
          isNull,
          reason:
              'a boot that is still in progress is not a failed launch; '
              'the launch said: ${run.launched.error}\n'
              'simctl was asked: ${simulator.calls.join('\n  ')}',
        );
        expect(
          simulator.installStates,
          ['Booted'],
          reason:
              'an install sent to a device that is still booting fails '
              'in `simctl`, with a message about the install',
        );
        expect(
          run.launched.value?.vmServiceUri,
          Uri.parse('http://127.0.0.1:2222/k=/'),
        );
      });
    }

    for (final failure in const [
      'Unable to boot device because the runtime is unavailable',
      'Invalid device: SIM-UDID',
    ]) {
      test(
        'a boot that fails is reported as the boot failing: "$failure"',
        () async {
          final async = FakeAsync();
          final simulator = FakeSimulator(bootFailure: failure);
          final run = launchOn(async, simulator);

          await elapse(async, const Duration(seconds: 30));

          expect(
            run.launched.done,
            isTrue,
            reason: 'the launch is still waiting',
          );
          expect(
            run.launched.error.toString(),
            contains(failure),
            reason:
                'the words simctl used for the step that failed are the whole '
                'diagnosis; reporting "simctl install failed" about a device '
                'that never booted sends the reader after the wrong step. The '
                'launch said: ${run.launched.error}',
          );
          expect(
            simulator.calls.where((c) => c.startsWith('simctl install')),
            isEmpty,
            reason: 'nothing is installed on a device that did not boot',
          );
        },
      );
    }
  });

  group('an app that announces its VM service late', () {
    // The first launch after a boot, and a host busy with a build, are the
    // slow starts; neither is a launch that failed. How long the app takes is
    // not what makes it wrong, so no one delay is the bound under test.
    for (final delay in const [
      Duration(seconds: 45),
      Duration(minutes: 3),
      Duration(minutes: 15),
    ]) {
      test('is attached to when it announces after ${delay.inSeconds}s', () async {
        final async = FakeAsync();
        final run = launchOn(
          async,
          FakeSimulator(state: 'Booted'),
          announceAfter: delay,
        );

        await elapse(async, delay + const Duration(seconds: 10));

        expect(run.launched.error, isNull, reason: '${run.launched.error}');
        expect(
          run.launched.value?.vmServiceUri,
          Uri.parse('http://127.0.0.1:2222/k=/'),
          reason:
              'the app was running and announced; a launch that gave up '
              '${delay.inSeconds > 30 ? 'at 30s ' : ''}on a clock reports the '
              'run as having no VM service',
        );
      });
    }
  });
}
