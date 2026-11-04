/// What a run does when the app dies after the tool has connected to it.
///
/// The property: an app that dies while a session is connected to it (before
/// its first frame, mid-session, mid-reload) ends the session with the
/// platform's account of why, and the run fails with that account. A quit the
/// user asked for, a relaunch the tool asked for, and an app that exits
/// cleanly are none of them a crash. The signal is the connection closing and
/// not coming back, or the process exiting; no timer decides anything.
///
/// Before this, nothing in a `run` listened for the connection closing: the
/// wait for the first frame kept asking a service that was gone and printing
/// "still waiting" until the tool was killed.
library;

import 'dart:async';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

/// A device whose platform answers [whyAppExited] as the test says.
class _Platform extends Device {
  /// What the platform says about the app: null while it runs or when it
  /// cannot tell.
  String? verdict;

  /// Asked of the platform, in order: the property is that it is asked before
  /// the app is stopped.
  final List<String> calls = [];

  @override
  String get name => 'Test Phone';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnsupportedError('not launched in this test');

  @override
  Future<String?> whyAppExited(AppInstance instance) async {
    calls.add('whyAppExited');
    return verdict;
  }

  @override
  Future<void> stop(AppInstance instance) async => calls.add('stop');
}

void main() {
  final serviceUri = Uri.parse('http://127.0.0.1:8181/');
  const platformWords =
      'com.example.app (pid 42) exited after announcing its VM service on '
      'Test Phone. The end of its output:\n  Unhandled exception: boom';

  late _Platform device;
  late FakeProcess process;
  late FakeVmService fake;
  late VmServiceClient client;
  late DeviceSession session;
  late List<String> deaths;

  setUp(() async {
    device = _Platform();
    process = FakeProcess();
    fake = FakeVmService(
      isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
    );
    client = VmServiceClient(connector: connectorFor(fake));
    await client.connect(serviceUri, createDevFS: false);
    deaths = [];
    session = DeviceSession(
      device: device,
      appInstance: AppInstance(process: process),
      vmClient: client,
      appId: 'app_1',
      onDied: deaths.add,
    );
  });

  test('the connection closing for good ends the session with the '
      "platform's account of why", () async {
    device.verdict = platformWords;

    fake.simulateDisposed();
    await session.terminated.timeout(const Duration(seconds: 5));

    expect(deaths, [platformWords]);
    expect(session.death, platformWords);
  });

  test('the platform is asked before the app is stopped, so that a process '
      'the tool killed is never one that died', () async {
    device.verdict = platformWords;

    fake.simulateDisposed();
    await session.terminated.timeout(const Duration(seconds: 5));
    await session.shutdown(MachineProtocol(enabled: false));

    expect(device.calls, ['whyAppExited', 'stop']);
  });

  test('a platform that cannot tell still ends the session, naming the '
      'connection that was lost', () async {
    device.verdict = null;

    fake.simulateDisposed();
    await session.terminated.timeout(const Duration(seconds: 5));

    expect(deaths, hasLength(1));
    expect(deaths.single, contains('Test Phone'));
    expect(deaths.single, contains(client.goneReason!));
  });

  test(
    'the process exiting with a failure ends the session with the account',
    () async {
      device.verdict = platformWords;

      process.complete(1);
      await session.terminated.timeout(const Duration(seconds: 5));

      expect(deaths, [platformWords]);
    },
  );

  test('the process and the connection both ending is one death', () async {
    device.verdict = platformWords;

    process.complete(1);
    fake.simulateDisposed();
    await session.terminated.timeout(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(deaths, hasLength(1));
  });

  test('an app that exits with code 0 finished; it did not crash', () async {
    device.verdict = 'The Test Phone app exited with code 0. ';

    process.complete(0);
    fake.simulateDisposed();
    await session.terminated.timeout(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(deaths, isEmpty);
    expect(session.death, isNull);
  });

  test('the connection closing because the user quit is not a death', () async {
    device.verdict = platformWords;

    await session.shutdown(MachineProtocol(enabled: false));
    fake.simulateDisposed();
    await pumpEventQueue();

    expect(deaths, isEmpty);
    expect(session.death, isNull);
  });

  test(
    'a stop the user asked for ends the session, which ends the run',
    () async {
      device.verdict = platformWords;

      await session.shutdown(MachineProtocol(enabled: false));
      process.complete(-15);

      await session.terminated.timeout(const Duration(seconds: 5));
      expect(deaths, isEmpty);
    },
  );

  test('replacing the app is not a death', () async {
    device.verdict = platformWords;
    final replacement = FakeProcess();

    await session.relaunch(() async {
      process.complete(0);
      await pumpEventQueue();
      return AppInstance(process: replacement);
    });
    await pumpEventQueue();

    expect(deaths, isEmpty);
    expect(session.death, isNull);
  });

  test('the death is on the app.stop event a machine client reads', () async {
    device.verdict = platformWords;
    final sink = BufferSink();
    final protocol = MachineProtocol(enabled: true, output: sink);

    fake.simulateDisposed();
    await session.terminated.timeout(const Duration(seconds: 5));
    await session.shutdown(protocol);

    final stop = sink.buffer
        .toString()
        .split('\n')
        .where((l) => l.contains('"app.stop"'))
        .single;
    expect(stop, contains('"error"'));
    expect(stop, contains('Unhandled exception: boom'));
  });

  test('a stop the user asked for carries no error', () async {
    final sink = BufferSink();
    final protocol = MachineProtocol(enabled: true, output: sink);

    await session.shutdown(protocol);

    final stop = sink.buffer
        .toString()
        .split('\n')
        .where((l) => l.contains('"app.stop"'))
        .single;
    expect(stop, isNot(contains('"error"')));
  });

  test('an app that dies before its first frame ends the wait, and the '
      'refusal given to commands says why', () async {
    device.verdict = platformWords;
    // The service answers nothing, which is how a starting app looks.
    fake.callServiceExtensionGate = Completer<void>();

    final waiting = track(
      session.waitUntilDrivable(MachineProtocol(enabled: false)),
    );
    await pumpEventQueue();
    fake.simulateDisposed();
    await session.terminated.timeout(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(waiting.done, isTrue, reason: 'the wait must end with the app');
    expect(session.drivable.isReady, isFalse);
    expect(session.drivable.unavailableReason, contains('Unhandled exception'));
  });
}
