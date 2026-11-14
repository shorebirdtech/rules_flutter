/// Properties of the failures the dev tool absorbs instead of surfacing.
///
/// Most of the tool's `catch (_)` sites are cleanup that rethrows, and are
/// fine: the failure still reaches its caller. The ones that matter are the
/// sites where the failure stops: a console line dropped, a pause probe that
/// answers "no", an HTTP 500 whose cause only the client sees, a retry loop
/// whose final error forgets what the last attempt said. The person running
/// `flutter_bazel` reads exactly one thing about the run: its log. A failure
/// that leaves no trace there turns into "it does not work, and nothing says
/// why".
///
/// The property: when the tool absorbs a failure, or converts it into another
/// failure, the cause is recorded in the run's log (at any level; it need not
/// be loud) or carried in the error that replaces it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/cdp_console.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/http_control_channel.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

void main() {
  /// Everything logged from now until the test ends, at every level, as one
  /// string per record: its message, its structured fields and its error.
  List<String> logged() {
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final lines = <String>[];
    final subscription = Logger.root.onRecord.listen(
      (r) => lines.add('${r.level.name} ${r.message} ${r.object} ${r.error}'),
    );
    addTearDown(() {
      subscription.cancel();
      Logger.root.level = previous;
    });
    return lines;
  }

  group('a console line the tool cannot read', () {
    // Each of these is a CDP notification whose shape is not what the handler
    // reads. The line is dropped, correctly: a console line is never worth
    // failing a run over. Dropping it without a word is the part in question.
    final malformed = <String, Map<String, dynamic>>{
      'a console call whose params are not an object': {
        'method': 'Runtime.consoleAPICalled',
        'params': 'garbage',
      },
      'an exception whose details are not an object': {
        'method': 'Runtime.exceptionThrown',
        'params': {'exceptionDetails': 'garbage'},
      },
    };

    for (final MapEntry(key: what, value: message) in malformed.entries) {
      test('is dropped from the app log but recorded: $what', () {
        final log = logged();
        final logs = AppLogStream();
        final lines = <String>[];
        logs.lines.listen((l) => lines.add(l.text));

        expect(() => handleCdpConsoleMessage(message, logs), returnsNormally);

        expect(lines, isEmpty);
        expect(
          log.where(
            (l) => l.contains('Runtime.') || l.contains('subtype'),
          ),
          isNotEmpty,
          reason: 'nothing in the run log says a console message was dropped',
        );
      });
    }
  });

  group('a VM service that will not answer a pause probe', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');
    const cause = 'stream disconnected (fake)';

    Future<VmServiceClient> connected() async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri, createDevFS: false);
      fake.getIsolateError = RPCError('getIsolate', 104, cause);
      return client;
    }

    test('is no answer, and the cause is recorded (pausedReason)', () async {
      final log = logged();
      final client = await connected();

      expect(await client.pausedReason(), isNull);

      expect(
        log.where((l) => l.contains(cause)),
        isNotEmpty,
        reason:
            'a command that fails right after this has the real cause only '
            'in the log, if anywhere',
      );
    });

    test(
      'is "unknown", and the cause is recorded (waitUntilPausedAtStart)',
      () async {
        final log = logged();
        final client = await connected();

        expect(
          await client.waitUntilPausedAtStart(
            timeout: const Duration(milliseconds: 250),
          ),
          StartPausedState.unknown,
        );

        expect(log.where((l) => l.contains(cause)), isNotEmpty);
      },
    );
  });

  group('a command that breaks the tool', () {
    test('answers 500 and records the cause in the run log', () async {
      final log = logged();
      final commands = CommandRunner()
        ..register('test.fail', (_) async {
          throw StateError('handler exploded (fake)');
        });
      final channel = HttpControlChannel(
        commandRunner: commands,
        findSession: (_) => null,
        token: 'tok',
      );
      await channel.start();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await channel.stop();
      });

      final request = await client.postUrl(
        channel.uri.replace(path: '/command', query: 'token=tok'),
      );
      request.headers.contentType = ContentType.json;
      request.write(json.encode({'method': 'test.fail'}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      expect(response.statusCode, HttpStatus.internalServerError);
      expect(body, contains('handler exploded (fake)'));
      expect(
        log.where((l) => l.contains('handler exploded (fake)')),
        isNotEmpty,
        reason:
            'the 500 is for the client; the person watching the terminal '
            'sees nothing at all unless the tool says it too',
      );
    });
  });

  group('a port that never accepts', () {
    for (final cause in const [
      'Connection refused',
      'Network is unreachable',
      'Operation not permitted',
    ]) {
      test('fails naming what the last attempt said: $cause', () {
        fakeAsync((async) {
          final outcome = track(
            waitForLocalTcpPort(
              4242,
              what: 'iproxy forward',
              budget: const Duration(seconds: 2),
              probe: (_) async => throw SocketException(cause),
            ),
          );

          async.elapse(const Duration(seconds: 5));

          expect(outcome.done, isTrue);
          expect(outcome.error, isA<StateError>());
          expect(
            outcome.error.toString(),
            contains(cause),
            reason:
                '"did not accept connections" is true of a refusal, a '
                'firewall and a wrong address alike; the last attempt knew '
                'which, and the error that replaces it should not discard it',
          );
        });
      });
    }
  });
}
