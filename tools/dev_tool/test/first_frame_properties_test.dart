/// Properties of the wait that makes an app drivable: the first frame.
///
/// Two ways this wait gives up on an app that is simply not there yet, and both
/// leave the same result for the person driving it: every agent command is
/// refused, for good, with a reason that reads as a broken app.
///
///   * It gives up on a clock. The budget is 30 s on a desktop or simulator, and
///     a loaded machine (a CI runner, an e2e sweep with many Bazel JVMs, a
///     laptop mid-build) lands its first frame later than that.
///   * It gives up on an ordering. The VM service is announced before the app's
///     root isolate runs, so a client that reads the isolate list and only then
///     subscribes to isolate events can miss the one isolate it needs, and the
///     wait answers "no" at once, without waiting for anything.
///
/// Both are stated as what must be true for the person, not as the mechanism:
/// the app becomes drivable whenever its first frame arrives, however late; and
/// an event that happens after the tool started waiting for it is never lost.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/agent_command.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

void main() {
  final serviceUri = Uri.parse('http://127.0.0.1:8181/');
  const firstFrameQuery = 'ext.flutter.didSendFirstFrameEvent';

  Future<VmServiceClient> connected(FakeVmService fake) async {
    final client = VmServiceClient(connector: (_) async => fake);
    await client.connect(serviceUri, createDevFS: false);
    return client;
  }

  /// Let everything that can happen without time moving happen. A subscription
  /// cancelled inside a [FakeAsync] zone completes on the real microtask queue,
  /// which that zone does not drive, so the two queues are taken in turns.
  Future<void> settle(FakeAsync async) async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
      async.flushMicrotasks();
    }
  }

  /// How long after launch the first frame lands, in each case a loaded host
  /// can produce: just past the desktop budget, minutes, and an hour. The
  /// property is "whenever", so no one of these is the bound being tested.
  const lateArrivals = {
    'just past the budget': Duration(seconds: 31),
    'minutes late': Duration(minutes: 5),
    'an hour late': Duration(hours: 1),
  };

  group('an app whose first frame is late', () {
    DeviceSession sessionOn(Device device, VmServiceClient client) =>
        DeviceSession(
          device: device,
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: 'app_1',
        );

    for (final MapEntry(key: label, value: arrival) in lateArrivals.entries) {
      for (final device in <Device>[
        MacOSDevice(),
        IOSSimulatorDevice(udid: 'SIM'),
      ]) {
        // The app is up and the VM answers nothing, which is how a physical
        // device and a starved host both look: only the frame event can come.
        test(
          'the app becomes drivable when its first frame lands $label '
          '(${device.name})',
          () async {
            final fake = FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )..callServiceExtensionGate = Completer<void>();
            final session = sessionOn(device, await connected(fake));

            final async = FakeAsync();
            final waiting = async.run(
              (_) => track(
                session.waitUntilDrivable(MachineProtocol(enabled: false)),
              ),
            );

            async.elapse(arrival);
            fake.emitFirstFrame();
            await settle(async);

            expect(
              session.drivable.isReady,
              isTrue,
              reason:
                  'the frame arrived ${arrival.inSeconds}s after the wait '
                  'began, and the app is exactly as drivable as it would have '
                  'been had it arrived sooner; refusing it now '
                  '(${session.drivable.unavailableReason}) is a verdict about '
                  'the clock, not about the app',
            );
            expect(waiting.error, isNull);
            session.stopWaitingForFirstFrame();
            fake.callServiceExtensionGate!.complete();
          },
        );
      }
    }

    // The user-visible form of the same property, through the surface an agent
    // actually uses: a command sent while the app is still starting is served
    // once it has started, not refused with the budget's verdict.
    for (final MapEntry(key: label, value: arrival) in lateArrivals.entries) {
      test('a command issued before a first frame that lands $label is served '
          'when it lands', () async {
        final fake =
            FakeVmService(
                isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
              )
              ..extensionRPCs = [
                'ext.rules_flutter.getText',
                'ext.flutter.reassemble',
              ]
              ..extensionResponses['ext.rules_flutter.getText'] = {
                'text': 'hi',
              };
        final session = sessionOn(MacOSDevice(), await connected(fake));
        final cr = CommandRunner();
        setUpAgentCommands(cr, (_) => session);

        final async = FakeAsync();
        Future<Map<String, dynamic>>? command;
        async.run((_) {
          unawaited(
            session.waitUntilDrivable(MachineProtocol(enabled: false)),
          );
          command = cr.run('app.getText', {'appId': 'app_1', 'key': 'k'});
        });
        final answer = track(command!);

        async.elapse(arrival);
        // The extension call stands in for nothing here: the query is how the
        // wait learns of the frame, as on a desktop app that has now painted.
        fake.extensionResponses[firstFrameQuery] = {'enabled': 'true'};
        fake.emitFirstFrame();
        await settle(async);

        expect(answer.error, isNull, reason: 'refused: ${answer.error}');
        expect(answer.value?['text'], 'hi');
        session.stopWaitingForFirstFrame();
      });
    }
  });

  group('an isolate that starts while the client is connecting', () {
    /// Where in the handshake the root isolate starts. The VM announces its
    /// service before the root isolate runs, so any of these is a real
    /// ordering; each is "after the client's last question, before its next".
    final startsAfter = <String, bool Function(String, String?)>{
      'the VM was read': (m, _) => m == 'getVM',
      'the Extension stream was subscribed': (m, a) =>
          m == 'streamListen' && a == EventStreams.kExtension,
      'the Isolate stream was subscribed': (m, a) =>
          m == 'streamListen' && a == EventStreams.kIsolate,
    };

    for (final MapEntry(key: label, value: matches) in startsAfter.entries) {
      test(
        'is the one the client drives when it starts after $label',
        () async {
          // Growable, because the VM adds to it as the isolate starts.
          final fake = FakeVmService(isolates: <IsolateRef>[])
            ..extensionResponses[firstFrameQuery] = {'enabled': 'true'};
          var started = false;
          fake.afterAnswering = (method, argument) {
            if (started || !matches(method, argument)) return;
            started = true;
            fake.startIsolate('iso-1');
          };

          final client = await connected(fake);

          expect(started, isTrue, reason: 'the scenario never happened');
          expect(
            await client.waitForFirstFrame(timeout: const Duration(seconds: 5)),
            isTrue,
            reason:
                'the isolate existed and said so before the client asked, or '
                'after: either way an event or a read tells a client that '
                'subscribed before it read, and the wait must not answer "no '
                'isolate" about an app that has one',
          );
          expect(
            fake.extensionCalls.where((c) => c.method == firstFrameQuery),
            isNotEmpty,
            reason: 'the query must have gone to the isolate that started',
          );
          expect(fake.lastIsolateId, 'iso-1');
        },
      );
    }

    test('is waited for, not given up on, by a wait that began before it', () async {
      // The engine reports the VM service before the root isolate exists, so a
      // client can be connected, with a wait running, and no isolate yet.
      final fake = FakeVmService(isolates: <IsolateRef>[])
        ..extensionResponses[firstFrameQuery] = {'enabled': 'true'};
      final client = await connected(fake);

      final waiting = client.waitForFirstFrame(
        timeout: const Duration(seconds: 30),
      );
      final answer = track(waiting);
      await pumpEventQueue();
      expect(
        answer.done,
        isFalse,
        reason:
            'no isolate yet is the app still starting; answering now turns '
            'that into "never rendered"',
      );

      fake.startIsolate('iso-1');
      expect(await waiting, isTrue);
    });
  });
}
