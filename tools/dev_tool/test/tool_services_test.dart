import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/tool_services.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

/// A reload or restart command the run dispatched, and what it was told to
/// answer.
class _Commands {
  final runner = CommandRunner();
  final calls = <String>[];
  Map<String, dynamic> reloadAnswer = {'message': 'Reloaded'};
  Map<String, dynamic> restartAnswer = {'message': 'Restarted'};
  Object? reloadThrows;

  _Commands() {
    runner.register('app.hotReload', (params) async {
      calls.add('app.hotReload');
      if (reloadThrows case final e?) throw e;
      return reloadAnswer;
    });
    runner.register('app.restart', (params) async {
      calls.add('app.restart');
      return restartAnswer;
    });
  }
}

typedef _Report = ({String action, String method, Map<String, dynamic> result});

FakeVmService _fake() => FakeVmService(
  isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
);

void main() {
  late _Commands commands;
  late List<_Report> reports;
  late ToolServices services;

  setUp(() {
    commands = _Commands();
    reports = [];
    services = ToolServices(
      commands: commands.runner,
      report: (action, result, {required method}) =>
          reports.add((action: action, method: method, result: result)),
    );
  });

  group('registration', () {
    test(
      'registers reloadSources and hotRestart, as flutter_tools does',
      () async {
        final fake = _fake();
        await services.registerOn(fake);
        expect(fake.registeredServices, {
          'reloadSources': ToolServices.alias,
          'hotRestart': ToolServices.alias,
        });
      },
    );

    test(
      'withoutHotRestart leaves hotRestart to someone else (DWDS)',
      () async {
        final fake = _fake();
        await services.withoutHotRestart().registerOn(fake);
        expect(fake.registeredServices.keys, ['reloadSources']);
        final answer = await fake.callRegistered('hotRestart');
        expect(
          (answer['error'] as Map)['code'],
          RPCErrorKind.kMethodNotFound.code,
        );
        expect(commands.calls, isEmpty);
      },
    );
  });

  group('routing', () {
    late FakeVmService fake;
    setUp(() async {
      fake = _fake();
      await services.registerOn(fake);
    });

    test('reloadSources runs app.hotReload and answers Success', () async {
      final answer = await fake.callRegistered('reloadSources', {
        'isolateId': 'iso-1',
      });
      expect(commands.calls, ['app.hotReload']);
      expect(answer, {
        'result': {'type': 'Success'},
      });
      expect(reports.single.action, 'Hot reload');
      expect(reports.single.method, 'app.hotReload');
      expect(reports.single.result, commands.reloadAnswer);
    });

    test('hotRestart runs app.restart and answers Success', () async {
      // The Dart MCP server passes an isolateId here; it is not a parameter.
      final answer = await fake.callRegistered('hotRestart', {
        'isolateId': 'iso-1',
      });
      expect(commands.calls, ['app.restart']);
      expect(answer, {
        'result': {'type': 'Success'},
      });
      expect(reports.single.method, 'app.restart');
    });

    test('a failed reload is an RPC error carrying the reason', () async {
      commands.reloadAnswer = {
        'error': 'lib/main.dart:3: Error: Expected a type',
        'succeeded': false,
      };
      final answer = await fake.callRegistered('reloadSources', {
        'isolateId': 'iso-1',
      });
      final error = answer['error'] as Map;
      expect(error['code'], RPCErrorKind.kInternalError.code);
      expect(error['message'], 'Unable to reload sources');
      expect(
        (error['data'] as Map)['details'],
        'lib/main.dart:3: Error: Expected a type',
      );
      // Reported as well: the terminal sees the failure, not only the caller.
      expect(reports.single.result['error'], isNotNull);
    });

    test('a refusal is an RPC error carrying the refusal', () async {
      commands.reloadThrows = const CommandFailure.unavailable(
        'Hot reload is off for this run',
      );
      final answer = await fake.callRegistered('reloadSources', {
        'isolateId': 'iso-1',
      });
      final error = answer['error'] as Map;
      expect(error['code'], RPCErrorKind.kInternalError.code);
      expect(
        (error['data'] as Map)['details'],
        'Hot reload is off for this run',
      );
    });

    test('a failed restart is an RPC error', () async {
      commands.restartAnswer = {'error': 'no app'};
      final answer = await fake.callRegistered('hotRestart');
      final error = answer['error'] as Map;
      expect(error['message'], 'Unable to restart');
    });

    test(
      'reloadSources requires an isolateId, as flutter_tools does',
      () async {
        final answer = await fake.callRegistered('reloadSources');
        expect(
          (answer['error'] as Map)['code'],
          RPCErrorKind.kInvalidParams.code,
        );
        expect(commands.calls, isEmpty);
      },
    );

    test('pause: true is refused, not ignored', () async {
      for (final (service, params) in [
        ('reloadSources', {'isolateId': 'iso-1', 'pause': true}),
        ('hotRestart', {'pause': true}),
      ]) {
        final answer = await fake.callRegistered(service, params);
        expect(
          (answer['error'] as Map)['code'],
          RPCErrorKind.kInvalidParams.code,
          reason: service,
        );
      }
      expect(commands.calls, isEmpty);
    });

    test('pause: false and force are accepted', () async {
      final answer = await fake.callRegistered('reloadSources', {
        'isolateId': 'iso-1',
        'pause': false,
        'force': true,
      });
      expect(answer.containsKey('result'), isTrue);
    });

    test('a non-bool force is refused', () async {
      final answer = await fake.callRegistered('reloadSources', {
        'isolateId': 'iso-1',
        'force': 'yes',
      });
      expect(
        (answer['error'] as Map)['code'],
        RPCErrorKind.kInvalidParams.code,
      );
    });
  });

  group('VmServiceClient', () {
    test('registers the services on connect', () async {
      final fake = _fake();
      final client = VmServiceClient(
        connector: connectorFor(fake),
        services: services,
      );
      await client.connect(
        Uri.parse('http://127.0.0.1:1/'),
        createDevFS: false,
      );
      expect(fake.registeredServices.keys, ['reloadSources', 'hotRestart']);
      await client.disconnect();
    });

    test('registers nothing without services', () async {
      final fake = _fake();
      final client = VmServiceClient(connector: connectorFor(fake));
      await client.connect(
        Uri.parse('http://127.0.0.1:1/'),
        createDevFS: false,
      );
      expect(fake.registeredServices, isEmpty);
      await client.disconnect();
    });

    test('registers again on the connection a re-dial makes', () async {
      final fakes = <FakeVmService>[];
      final client = VmServiceClient(
        connector: (_) async {
          final fake = _fake();
          fakes.add(fake);
          return fake;
        },
        services: services,
      );
      await client.connect(
        Uri.parse('http://127.0.0.1:1/'),
        createDevFS: false,
      );
      fakes.first.simulateDisposed();
      // Any RPC finds the dead socket and re-dials.
      await client.callServiceExtension('ext.flutter.foo');
      expect(fakes, hasLength(2));
      expect(fakes.last.registeredServices.keys, [
        'reloadSources',
        'hotRestart',
      ]);
      await client.disconnect();
    });
  });
}
