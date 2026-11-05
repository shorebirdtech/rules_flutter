/// A fake VM service for the tests of an integration test's host side.
///
/// Real enough to be worth having: it speaks JSON-RPC over a real WebSocket on
/// a real loopback port, so the framing, the stream subscriptions and the id
/// pairing of `package:vm_service` are under test rather than mocked away, and
/// it can register the app's extension, post its events and vanish at the exact
/// moment a real app is hard to catch at.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/integration/vm_service_suite_transport.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// A VM service on a loopback WebSocket with isolates, their registered
/// extensions, and the two streams a suite transport subscribes to: what an app
/// running an integration test looks like from the host.
class FakeSuiteApp {
  FakeSuiteApp._(this._server) {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      socket.listen(
        (raw) => _answer(json.decode(raw as String) as Map<String, Object?>),
        onDone: () => _closed.complete(),
      );
    });
  }

  final HttpServer _server;
  WebSocket? _socket;
  final _closed = Completer<void>();
  var _vanished = false;

  /// Completes when the client's socket has closed.
  Future<void> get closed => _closed.future;

  /// The extensions each isolate has registered, by isolate id.
  final isolates = <String, Set<String>>{};

  /// The streams a client has subscribed to.
  final subscribed = <String>{};

  /// The parameters of each call to the golden extension, in arrival order.
  final goldenAnswers = <Map<String, String>>[];

  /// The `data` of each call to the integration extension, in arrival order.
  final received = <String>[];

  /// Completes when the first `getVM` has been answered: the client is then
  /// waiting for a registration that has not happened.
  final answeredGetVm = Completer<void>();

  /// An error to answer calls to the extension with, or null to succeed.
  RPCError? refuse;

  Uri get httpUri => Uri.parse('http://127.0.0.1:${_server.port}/');

  Uri get wsUri => Uri.parse('ws://127.0.0.1:${_server.port}/ws');

  static Future<FakeSuiteApp> start() async =>
      FakeSuiteApp._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<VmService> connect() => vmServiceConnectUri(wsUri.toString());

  Map<String, Object?> _ref(String id) => {
    'type': '@Isolate',
    'id': id,
    'name': id,
    'number': id.replaceAll(RegExp(r'\D'), ''),
    'isSystemIsolate': false,
  };

  void _answer(Map<String, Object?> request) {
    // A request already on the wire when the app ended gets no answer.
    if (_vanished) return;
    final id = request['id'];
    final method = request['method'] as String;
    final params = (request['params'] as Map?)?.cast<String, Object?>() ?? {};
    Object? result;
    switch (method) {
      case 'getVM':
        result = {
          'type': 'VM',
          'name': 'fake',
          'architectureBits': 64,
          'hostCPU': 'fake',
          'operatingSystem': 'fake',
          'targetCPU': 'fake',
          'version': '3.0.0',
          'pid': 1,
          'startTime': 0,
          'isolates': [for (final iso in isolates.keys) _ref(iso)],
          'isolateGroups': <Object?>[],
          'systemIsolates': <Object?>[],
          'systemIsolateGroups': <Object?>[],
        };
        if (!answeredGetVm.isCompleted) {
          Timer.run(answeredGetVm.complete);
        }
      case 'getIsolate':
        final isolate = params['isolateId']! as String;
        result = {
          ..._ref(isolate),
          'type': 'Isolate',
          'isolateFlags': <Object?>[],
          'startTime': 0,
          'runnable': true,
          'livePorts': 0,
          'pauseOnExit': false,
          'pauseEvent': {'type': 'Event', 'kind': 'Resume', 'timestamp': 0},
          'libraries': <Object?>[],
          'breakpoints': <Object?>[],
          'exceptionPauseMode': 'None',
          'extensionRPCs': isolates[isolate]!.toList(),
        };
      case 'streamListen':
        subscribed.add(params['streamId']! as String);
        result = {'type': 'Success'};
      case goldenMethod:
        goldenAnswers.add(params.cast<String, String>()..remove('isolateId'));
        result = {'type': 'Response'};
      case integrationTestMethod:
        received.add(params[integrationTestDataKey]! as String);
        final error = refuse;
        if (error != null) {
          _socket!.add(
            json.encode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': error.code, 'message': error.message},
            }),
          );
          return;
        }
        result = {'type': 'Response'};
      default:
        _socket!.add(
          json.encode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'unexpected RPC: $method'},
          }),
        );
        return;
    }
    _socket!.add(json.encode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  void _notify(String stream, Map<String, Object?> event) => _socket!.add(
    json.encode({
      'jsonrpc': '2.0',
      'method': 'streamNotify',
      'params': {'streamId': stream, 'event': event},
    }),
  );

  /// The app calls `registerExtension` in [isolate]: the VM tells a client
  /// that subscribed to the Isolate stream, and only that one.
  void registerExtension(String isolate, String rpc) {
    isolates.putIfAbsent(isolate, () => {}).add(rpc);
    if (subscribed.contains('Isolate')) {
      _notify('Isolate', {
        'type': 'Event',
        'kind': 'ServiceExtensionAdded',
        'timestamp': 0,
        'isolate': _ref(isolate),
        'extensionRPC': rpc,
      });
    }
  }

  /// The app calls `postEvent(kind, {data: [data]})` in [isolate].
  void post(String isolate, String kind, String data) => _notify('Extension', {
    'type': 'Event',
    'kind': 'Extension',
    'timestamp': 0,
    'isolate': _ref(isolate),
    'extensionKind': kind,
    'extensionData': {integrationTestDataKey: data},
  });

  /// The app asks about a golden: `postEvent(goldenEventKind, data)` in
  /// [isolate].
  void postGolden(String isolate, Map<String, Object?> data) =>
      _notify('Extension', {
        'type': 'Event',
        'kind': 'Extension',
        'timestamp': 0,
        'isolate': _ref(isolate),
        'extensionKind': goldenEventKind,
        'extensionData': data,
      });

  /// The app ends: its VM service's socket closes.
  Future<void> vanish() async {
    _vanished = true;
    await _socket!.close();
    await _closed.future;
  }

  Future<void> stop() => _server.close(force: true);
}
