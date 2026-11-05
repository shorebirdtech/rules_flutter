/// A fake page for the tests of an integration test's DevTools transport: its
/// connection records every command, answers the ones the transport sends, and
/// can send the events a page and a browser send.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_bazel_dev_tool/browser_extension_channel.dart';
import 'package:test/test.dart';

/// A page whose DevTools connection records the commands sent to it.
class FakeCdpPage implements CdpSender {
  /// Every command, in order.
  final commands = <({String method, Map<String, dynamic> params})>[];

  /// Completed by the test when the page installs its bridge, which the
  /// transport is waiting for in an evaluation.
  final bridgeInstalled = Completer<void>();

  /// Whether the page has a default execution context when `Runtime.enable`
  /// is asked, as a loaded page has. A page that is still loading has none:
  /// the test emits [emitDefaultContext] when it has one.
  var hasContextAtEnable = true;

  /// An answer to the evaluation that waits for the bridge, instead of the
  /// wait: the error of a page whose context went away under it, once.
  String? waitFailsOnce;

  /// What a `send` call to the bridge answers with: an exception's text, or
  /// null for a page that takes the message.
  String? bridgeThrows;

  /// The answers to goldens the bridge was handed, as the JSON text each was.
  final goldenAnswers = <String>[];

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  var _closed = false;

  /// The messages the bridge was sent, decoded from the string literal in each
  /// evaluated expression.
  final delivered = <String>[];

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    _closed = true;
    await _events.close();
  }

  /// The browser closes the connection.
  Future<void> vanish() => close();

  /// An event from the page or the browser.
  void emit(String method, Map<String, Object?> params) =>
      _events.add({'method': method, 'params': params});

  /// The page creates a context: the default one of its main frame, or the
  /// kind of context an extension or a worker has.
  void emitDefaultContext({int id = 1, bool isDefault = true}) =>
      emit('Runtime.executionContextCreated', {
        'context': {
          'id': id,
          'origin': 'http://127.0.0.1',
          'name': '',
          'auxData': {'isDefault': isDefault, 'frameId': 'F'},
        },
      });

  /// The page's context `id` goes away, as it does when the page navigates.
  void emitContextDestroyed({int id = 1}) =>
      emit('Runtime.executionContextDestroyed', {'executionContextId': id});

  /// The page calls its binding `name` with `payload`.
  void callBinding(String name, String payload) =>
      emit('Runtime.bindingCalled', {
        'name': name,
        'payload': payload,
        'executionContextId': 1,
      });

  List<String> get methods => [for (final c in commands) c.method];

  @override
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closed) throw StateError('the page\'s CDP connection closed');
    commands.add((method: method, params: params));
    if (method == 'Runtime.enable' && hasContextAtEnable) emitDefaultContext();
    if (method != 'Runtime.evaluate') return {'result': <String, Object?>{}};

    final expression = params['expression'] as String;
    const call = r'globalThis.$rulesFlutterIntegration.send(';
    if (expression.startsWith(call)) {
      delivered.add(
        json.decode(expression.substring(call.length, expression.length - 1))
            as String,
      );
      return {
        'result': {
          'result': <String, Object?>{'type': 'undefined'},
          if (bridgeThrows != null)
            'exceptionDetails': {
              'text': 'Uncaught',
              'exception': {'description': bridgeThrows},
            },
        },
      };
    }
    const golden = r'globalThis.$rulesFlutterIntegration.golden(';
    if (expression.startsWith(golden)) {
      goldenAnswers.add(
        json.decode(expression.substring(golden.length, expression.length - 1))
            as String,
      );
      return {
        'result': {
          'result': <String, Object?>{'type': 'undefined'},
        },
      };
    }
    // The wait for the bridge: a promise the page settles when it has one.
    expect(params['awaitPromise'], isTrue);
    final failure = waitFailsOnce;
    if (failure != null) {
      waitFailsOnce = null;
      throw StateError(
        'CDP Runtime.evaluate failed: {code: -32000, message: $failure}',
      );
    }
    await bridgeInstalled.future;
    return {
      'result': {
        'result': {'type': 'boolean', 'value': true},
      },
    };
  }
}
