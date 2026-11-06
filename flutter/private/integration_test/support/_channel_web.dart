// The suite's channel to the host in a web page, which has no VM service: the
// host reaches the suite over the browser's DevTools protocol.
//
//  * Host to app: the page publishes `globalThis.$rulesFlutterIntegration` with
//    a `send(jsonText)` that pushes one message into the suite, and announces it
//    with a `rulesflutterintegrationready` event on `window`. The host calls it
//    through `Runtime.evaluate`.
//  * Goldens, which the host compares: the page calls
//    `globalThis.rulesFlutterGoldenPost(jsonText)`, a second binding, with
//    `{id, op, key, bytes}` (the bytes in base64), and the host answers by
//    calling `$rulesFlutterIntegration.golden(jsonText)` with `{id, matched}` or
//    `{id, error}`.
//  * App to host: the page calls `globalThis.rulesFlutterIntegrationPost(jsonText)`,
//    a binding the host added with `Runtime.addBinding`. It exists before the
//    page ever posts: the host speaks first in the suite's protocol and the
//    page answers, so nothing here waits for it or polls for it.
//
// The host's half is `cdp_suite_transport.dart` in the dev tool.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stream_channel/stream_channel.dart';

import '_golden.dart';

/// The binding the host added: called with the JSON text of a message.
@JS('rulesFlutterIntegrationPost')
external void _post(JSString jsonText);

/// The binding the host added for goldens: called with the JSON text of a
/// request.
@JS('rulesFlutterGoldenPost')
external void _postGolden(JSString jsonText);

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
    )
    ..setProperty(
      'golden'.toJS,
      ((JSString jsonText) {
        _answerGolden(json.decode(jsonText.toDart) as Map<String, dynamic>);
      }).toJS,
    );
  globalContext.setProperty(r'$rulesFlutterIntegration'.toJS, bridge);
  _dispatchEvent(_Event('rulesflutterintegrationready'));
}

/// Starts the binding the suite's tests run in: upstream's, with
/// [_PageBinding.runAsync] waiting for the engine to catch up first.
void initializeBinding() {
  _PageBinding();
}

/// Upstream's binding, but a picture taken in [runAsync] is never drawn on a
/// surface a frame has resized under it.
///
/// `matchesGoldenFile` takes its picture in [runAsync]: it draws the widget's
/// layer into an image and encodes it as a PNG, which in a page means drawing
/// it on the engine's offscreen surface after resizing that surface to the
/// image. Frames are drawn on the same surface, resized to the page, and the
/// engine draws them after the framework has moved on: when a frame is still
/// waiting its turn as the picture is taken, its resize can land between the
/// picture's resize and its drawing, and the picture comes back the size of the
/// page with the widget in its corner (flutter/flutter#185034). A busy machine
/// leaves a frame waiting after any `pumpAndSettle`.
///
/// A frame that starts while the picture is taken makes the same resize: one
/// the app draws of its own accord, as it does under
/// [LiveTestWidgetsFlutterBindingFramePolicy.fullyLive] or while a tap's
/// pointer fades.
///
/// So no frame is drawn while [runAsync] runs: one the engine asks for then is
/// drawn once it returns. And [runAsync] first encodes a one-pixel image the
/// way the picture is encoded. The engine's worker answers in the order it was
/// asked, and a waiting frame starts as soon as the one before it is drawn, so
/// once that image comes back every frame handed to the engine has made its
/// resize, and none can make one in the middle of the picture.
///
/// This is what the automated binding of `flutter test` gives code in
/// [runAsync]: no frame is drawn until the test pumps one.
class _PageBinding extends IntegrationTestWidgetsFlutterBinding {
  /// Whether frames wait for [runAsync] to return.
  var _holding = false;

  /// Whether the engine asked for a frame while frames waited.
  var _held = false;

  /// Whether the frame begun is one that waits, so its draw does too.
  var _holdingThisFrame = false;

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    if (_holding) {
      _held = _holdingThisFrame = true;
      return;
    }
    super.handleBeginFrame(rawTimeStamp);
  }

  @override
  void handleDrawFrame() {
    if (_holdingThisFrame) {
      _holdingThisFrame = false;
      return;
    }
    super.handleDrawFrame();
  }

  @override
  Future<T?> runAsync<T>(Future<T> Function() callback) =>
      super.runAsync(() async {
        _holding = true;
        try {
          await _engineCaughtUp();
          return await callback();
        } finally {
          _holding = false;
          if (_held) {
            _held = false;
            platformDispatcher.scheduleFrame();
          }
        }
      });
}

/// Completes once every frame handed to the engine has started drawing.
Future<void> _engineCaughtUp() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  picture.dispose();
  try {
    await image.toByteData(format: ui.ImageByteFormat.png);
  } finally {
    image.dispose();
  }
}

/// What `flutter test` sets up in the app before the suite runs: goldens
/// compared by the host. A page has no isolate to report top-level errors from.
void preparePlatform() {
  goldenFileComparator = HostGoldenFileComparator(_askHost);
}

final _pendingGoldens = <int, Completer<GoldenReply>>{};
var _lastGoldenId = 0;

/// Posts the request to the host and waits for its answer, which arrives as a
/// call of the bridge's `golden` carrying the request's id.
Future<GoldenReply> _askHost(String operation, String key, Uint8List bytes) {
  final id = ++_lastGoldenId;
  final reply = _pendingGoldens[id] = Completer<GoldenReply>();
  _postGolden(
    json.encode({
      'id': id,
      'op': operation,
      'key': key,
      'bytes': base64.encode(bytes),
    }).toJS,
  );
  return reply.future;
}

void _answerGolden(Map<String, dynamic> answer) {
  final pending = _pendingGoldens.remove(answer['id']);
  if (pending == null) {
    throw StateError('No pending golden request with id "${answer['id']}".');
  }
  final error = answer['error'];
  pending.complete(
    error is String
        ? GoldenReply.failed(error)
        : GoldenReply.matched(answer['matched'] as bool),
  );
}

@JS('Event')
extension type _Event._(JSObject _) implements JSObject {
  external factory _Event(String type);
}

@JS('dispatchEvent')
external bool _dispatchEvent(_Event event);
