// The suite's channel to the host over the VM service, as `flutter test`'s
// integration test device does it: the host calls the service extension
// `ext.flutter.integrationTest` with `{data: <json>}`, and the app posts
// `Flutter.IntegrationTest` events with `{data: <json>}`.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:stream_channel/stream_channel.dart';

import '_golden.dart';

const _method = 'ext.flutter.integrationTest';
const _eventKind = 'Flutter.IntegrationTest';
const _dataKey = 'data';

/// Carries [testChannel]'s messages to the host and the host's to it.
void connectSuiteChannel(StreamChannel<dynamic> testChannel) {
  _registerGoldenAnswers();
  developer.registerExtension(_method, (method, parameters) async {
    testChannel.sink.add(json.decode(parameters[_dataKey]!));
    // The result is ignored, but null is not accepted here.
    return developer.ServiceExtensionResponse.result('{}');
  });

  testChannel.stream.listen((dynamic message) {
    developer.postEvent(_eventKind, {_dataKey: json.encode(message)});
  });
}

/// Registers [_goldenMethod], which the host answers golden requests through.
void _registerGoldenAnswers() {
  developer.registerExtension(_goldenMethod, (method, parameters) async {
    final pending = _pendingGoldens.remove(
      int.tryParse(parameters['id'] ?? ''),
    );
    if (pending == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        'No pending golden request with id "${parameters['id']}".',
      );
    }
    final error = parameters['error'];
    pending.complete(
      error != null
          ? GoldenReply.failed(error)
          : GoldenReply.matched(parameters['result'] == 'true'),
    );
    return developer.ServiceExtensionResponse.result('{}');
  });
}

/// Starts the binding the suite's tests run in: upstream's, as it is.
void initializeBinding() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
}

/// What `flutter test` sets up in the app before the suite runs, which a VM
/// has and a page does not: top-level errors reported to the suite as its own,
/// and goldens compared by the host.
void preparePlatform() {
  _catchIsolateErrors();
  goldenFileComparator = HostGoldenFileComparator(_askHost);
}

// The event the app posts to ask the host about a golden, and the extension the
// host answers through. The event is on the Extension stream, with the suite's
// own: a stream of the app's own naming, as upstream's
// `VmServiceProxyGoldenFileComparator` posts to, is one the VM refuses a
// listener for unless the connection is through the debug service (DDS).
const _goldenEventKind = 'Flutter.IntegrationTest.Golden';
const _goldenMethod = 'ext.flutter.integrationTest.golden';

final _pendingGoldens = <int, Completer<GoldenReply>>{};
var _lastGoldenId = 0;

/// Posts the request to the host and waits for its answer, which arrives as a
/// call of [_goldenMethod] carrying the request's id.
Future<GoldenReply> _askHost(
  String operation,
  String key,
  Uint8List bytes,
) {
  final id = ++_lastGoldenId;
  final reply = _pendingGoldens[id] = Completer<GoldenReply>();
  developer.postEvent(_goldenEventKind, {
    'op': operation,
    'id': id,
    'path': key,
    'bytes': base64.encode(bytes),
  });
  return reply.future;
}

/// Reports any top-level error (mostly lazy syntax errors, since the others are
/// caught by the test) to the host as the suite's own.
void _catchIsolateErrors() {
  final errorPort = ReceivePort();
  // Treat errors as non-fatal because otherwise they would be printed twice.
  Isolate.current.setErrorsFatal(false);
  Isolate.current.addErrorListener(errorPort.sendPort);
  errorPort.listen((dynamic message) {
    // Masquerade as an IsolateSpawnException, which is what this would be had
    // the error been detected statically.
    final list = message as List<dynamic>;
    final error = IsolateSpawnException(list[0] as String);
    final stackTrace = list[1] == null
        ? Trace(const <Frame>[])
        : Trace.parse(list[1] as String);
    Zone.current.handleUncaughtError(error, stackTrace);
  });
}
