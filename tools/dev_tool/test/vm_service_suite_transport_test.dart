/// The VM-service transport of an integration test's suite, against a fake VM
/// service on a real loopback WebSocket: the framing, the stream
/// subscriptions and the id pairing of `package:vm_service` are all under test,
/// and the fake can register the app's extension, post its events and vanish at
/// the exact moment a real app is hard to catch at.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_bazel_dev_tool/integration/golden_requests.dart';
import 'package:flutter_bazel_dev_tool/integration/vm_service_suite_transport.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fake_suite_app.dart';

const _death =
    'The macOS app exited with code 3 after announcing its VM service.';

/// Lets everything already queued run, so that "has not happened yet" can be
/// asserted without waiting a fixed time.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeSuiteApp app;
  late VmService service;
  setUp(() async {
    app = await FakeSuiteApp.start();
    service = await app.connect();
  });
  tearDown(() async {
    await service.dispose();
    await app.stop();
  });

  Future<String?> deathReason() async => _death;

  group('connecting', () {
    test('waits for the isolate that registers the extension, and ends when it '
        'does, with no event polled for and no time spent', () async {
      app.isolates['isolates/1'] = {'ext.flutter.other'};
      var connected = false;
      final transport = VmServiceSuiteTransport.connect(
        service,
        whyLost: deathReason,
      ).whenComplete(() => connected = true);

      await app.answeredGetVm.future;
      await _settle();
      expect(connected, isFalse, reason: 'the extension is not registered yet');

      app.registerExtension('isolates/1', integrationTestMethod);
      final connectedTransport = await transport;

      expect(connectedTransport, isNotNull);
      expect(
        app.subscribed,
        containsAll(['Isolate', 'Extension']),
        reason: 'the Isolate stream was listened to before the registration',
      );
    });

    test('finds an extension the app registered before anyone was listening, '
        'which the VM does not replay', () async {
      app.isolates['isolates/1'] = {};
      app.isolates['isolates/2'] = {integrationTestMethod};

      final transport = await VmServiceSuiteTransport.connect(
        service,
        whyLost: deathReason,
      );
      transport.send('"hello"');

      await transport.close();
      expect(app.received, ['"hello"'], reason: 'sent to the right isolate');
    });

    test('an app that ends before registering it is reported with the '
        'device\'s account of why', () async {
      app.isolates['isolates/1'] = {};
      final connecting = VmServiceSuiteTransport.connect(
        service,
        whyLost: deathReason,
      );
      // Settled before the expectation, which is on the future's failure.
      final outcome = expectLater(
        connecting,
        throwsA(
          isA<AppLostBeforeSuite>().having((e) => e.reason, 'reason', _death),
        ),
      );

      await app.answeredGetVm.future;
      await app.vanish();
      await outcome;
    });
  });

  group('a connected suite', () {
    late VmServiceSuiteTransport transport;
    setUp(() async {
      app.isolates['isolates/1'] = {integrationTestMethod};
      transport = await VmServiceSuiteTransport.connect(
        service,
        whyLost: deathReason,
      );
    });

    test('turns the golden events the app posts into requests, and leaves its '
        'suite messages to the suite', () async {
      final golden = transport.goldenRequests.first;
      final suite = transport.incoming.first;

      app.postGolden('isolates/1', {
        'op': 'compare',
        'id': 1001,
        'path': 'goldens/macos/a.png',
        'bytes': base64.encode([9, 8]),
      });
      app.post('isolates/1', integrationTestEventKind, '"suite"');

      final request = await golden;
      expect(request.id, 1001);
      expect(request.operation, GoldenOperation.compare);
      expect(request.key, 'goldens/macos/a.png');
      expect(request.bytes, [9, 8]);
      expect(await suite, '"suite"', reason: 'a suite message, not a golden');
    });

    test(
      'answers a golden through the extension the app registered, with '
      'the strings its handler reads: the id and a result or an error',
      () async {
        await transport.answerGolden(1001, const GoldenAnswer.matched(false));
        await transport.answerGolden(
          1002,
          const GoldenAnswer.failed('no file'),
        );

        expect(app.goldenAnswers, [
          {'id': '1001', 'result': 'false'},
          {'id': '1002', 'error': 'no file'},
        ]);
      },
    );

    test('carries the host\'s messages to the app, in the order they were '
        'sent', () async {
      for (final message in ['"a"', '"b"', '"c"']) {
        transport.send(message);
      }
      await transport.close();

      expect(app.received, ['"a"', '"b"', '"c"']);
    });

    test('carries the app\'s messages to the host, and nothing else the app '
        'posts', () async {
      final seen = transport.incoming.take(2).toList();

      app.post('isolates/1', 'Flutter.Frame', '"a frame"');
      app.post('isolates/9', integrationTestEventKind, '"another isolate"');
      app.post('isolates/1', integrationTestEventKind, '[1,{"type":"x"}]');
      app.post('isolates/1', integrationTestEventKind, '"second"');

      // The other two were posted first, so they would be among these.
      expect(await seen, ['[1,{"type":"x"}]', '"second"']);
    });

    test('reports the app ending, in the device\'s words', () async {
      final lost = transport.lostReason;

      await app.vanish();

      expect(await lost, _death);
    });

    test('and says so when the device cannot say why', () async {
      final unknown = await VmServiceSuiteTransport.connect(
        service,
        whyLost: () async => null,
      );

      await app.vanish();

      expect(
        await unknown.lostReason,
        allOf(contains('VM service closed'), contains('could not say why')),
      );
    });

    test('reports an app that refuses a message, which nothing after it can '
        'recover from', () async {
      app.refuse = RPCError('ext', -32001, 'extension threw');

      transport.send('"x"');

      expect(
        await transport.lostReason,
        allOf(contains('refused a message'), contains('extension threw')),
      );
    });

    test('a polite close is not the app being lost', () async {
      var lost = false;
      unawaited(transport.lostReason.then((_) => lost = true));

      await transport.close();
      await _settle();

      expect(lost, isFalse);
    });

    test('abandoning a wedged app closes the connection without waiting for '
        'the app to answer', () async {
      var lost = false;
      unawaited(transport.lostReason.then((_) => lost = true));

      await transport.abandon('did not finish');
      await app.closed;
      await _settle();

      expect(lost, isFalse, reason: 'the driver already knows why');
    });
  });
}
