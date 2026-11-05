// The suite's channel to the host in a web page, which has no VM service: the
// host reaches the suite over the browser's DevTools protocol.
//
//  * Host to app: the page publishes `globalThis.$rulesFlutterIntegration` with
//    a `send(jsonText)` that pushes one message into the suite, and announces it
//    with a `rulesflutterintegrationready` event on `window`. The host calls it
//    through `Runtime.evaluate`.
//  * App to host: the page calls `globalThis.rulesFlutterIntegrationPost(jsonText)`,
//    a binding the host added with `Runtime.addBinding`. It exists before the
//    page ever posts: the host speaks first in the suite's protocol and the
//    page answers, so nothing here waits for it or polls for it.
//
// The host's half is `cdp_suite_transport.dart` in the dev tool.
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:stream_channel/stream_channel.dart';

/// The binding the host added: called with the JSON text of a message.
@JS('rulesFlutterIntegrationPost')
external void _post(JSString jsonText);

/// Carries [testChannel]'s messages to the host and the host's to it.
void connectSuiteChannel(StreamChannel<dynamic> testChannel) {
  testChannel.stream.listen((dynamic message) {
    _post(json.encode(message).toJS);
  });

  final bridge = JSObject()
    ..setProperty(
      'send'.toJS,
      ((JSString jsonText) {
        testChannel.sink.add(json.decode(jsonText.toDart));
      }).toJS,
    );
  globalContext.setProperty(r'$rulesFlutterIntegration'.toJS, bridge);
  _dispatchEvent(_Event('rulesflutterintegrationready'));
}

/// What `flutter test` sets up in the app before the suite runs, which a page
/// has no use for: a page has no isolate to report top-level errors from, and
/// goldens are compared by the host over the VM service, which a page lacks. The
/// framework's own comparator stands, which says so when a test compares a
/// golden, where the VM service's proxy would wait for a host that never answers.
void preparePlatform() {}

@JS('Event')
extension type _Event._(JSObject _) implements JSObject {
  external factory _Event(String type);
}

@JS('dispatchEvent')
external bool _dispatchEvent(_Event event);
