// The suite's channel to the host over the VM service, as `flutter test`'s
// integration test device does it: the host calls the service extension
// `ext.flutter.integrationTest` with `{data: <json>}`, and the app posts
// `Flutter.IntegrationTest` events with `{data: <json>}`.
import 'dart:convert';
import 'dart:developer' as developer;

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
