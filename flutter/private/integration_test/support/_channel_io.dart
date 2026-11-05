// The suite's channel to the host over the VM service, as `flutter test`'s
// integration test device does it: the host calls the service extension
// `ext.flutter.integrationTest` with `{data: <json>}`, and the app posts
// `Flutter.IntegrationTest` events with `{data: <json>}`.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:integration_test/integration_test.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:stream_channel/stream_channel.dart';

const _method = 'ext.flutter.integrationTest';
const _eventKind = 'Flutter.IntegrationTest';
const _dataKey = 'data';

/// Carries [testChannel]'s messages to the host and the host's to it.
void connectSuiteChannel(StreamChannel<dynamic> testChannel) {
  developer.registerExtension(_method, (method, parameters) async {
    testChannel.sink.add(json.decode(parameters[_dataKey]! ));
    // The result is ignored, but null is not accepted here.
    return developer.ServiceExtensionResponse.result('{}');
  });

  testChannel.stream.listen((dynamic message) {
    developer.postEvent(_eventKind, {_dataKey: json.encode(message)});
  });
}

/// What `flutter test` sets up in the app before the suite runs, which a VM
/// has and a page does not: top-level errors reported to the suite as its own,
/// and goldens compared by the host.
void preparePlatform() {
  _catchIsolateErrors();
  VmServiceProxyGoldenFileComparator.useIfRunningOnDevice();
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
