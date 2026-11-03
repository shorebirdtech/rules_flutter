/// [AppExtensionChannel] for a bundled web build, over the Chrome DevTools
/// Protocol.
///
/// A dart2wasm or dart2js bundle has no VM service, so `registerExtension`
/// there only stores handlers in a map nothing can reach. In debug builds the
/// generated main therefore registers the agent extensions itself and installs
/// a bridge on `globalThis.$rulesFlutterAgent`, announcing it with a
/// `rulesflutteragentready` event on `window`. This channel evaluates calls on
/// that bridge in the app's page:
///
///  * `call(method, paramsJson)` resolves to JSON text, one of
///    `{"result": {…}}`, `{"error": {"code": n, "detail": "…"}}` or
///    `{"unregistered": true}`;
///  * `registered(method)`, `bindingReady()` and `firstFrame()` resolve when
///    their fact is true (`registered` with the answer).
///
/// Every evaluation first waits, inside the page and on the event, for the
/// bridge, so nothing here polls and a command issued before the page has
/// loaded simply waits for it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:vm_service/vm_service.dart';

import 'app_extension_channel.dart';
import 'device.dart';

/// The part of a CDP page connection this channel uses; [CdpPageConnection]
/// is the real one, and a test names its own.
abstract interface class CdpSender {
  /// Send [method] and return the whole reply; a CDP error is a [StateError].
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout,
  });

  bool get isClosed;

  /// The page's CDP events: every message that is not a reply.
  Stream<Map<String, dynamic>> get events;

  Future<void> close();
}

/// How long [BrowserExtensionChannel] waits for the page to install the bridge
/// when the caller names no budget of its own.
const defaultBridgeTimeout = Duration(seconds: 30);

/// The longest a single in-page call is held open. The caller bounds every
/// dispatch itself (`app.*` commands add a margin to the app's own deadline);
/// this only keeps an evaluation from outliving the session if it does not.
const _callCeiling = Duration(minutes: 30);

class BrowserExtensionChannel implements AppExtensionChannel {
  final Future<CdpSender> Function() _connect;

  /// How long to wait for the page to install the bridge, and for the binding
  /// or an inspector extension to appear after that.
  final Duration bridgeTimeout;

  CdpSender? _connection;
  Future<CdpSender>? _connecting;

  BrowserExtensionChannel({
    required Future<CdpSender> Function() connect,
    this.bridgeTimeout = defaultBridgeTimeout,
  }) : _connect = connect;

  /// The channel to the page serving [appUrl] on [cdpPort].
  factory BrowserExtensionChannel.forPage({
    required int cdpPort,
    required String appUrl,
    Duration bridgeTimeout = defaultBridgeTimeout,
  }) => BrowserExtensionChannel(
    connect: () => CdpPageConnection.open(cdpPort, appUrl: appUrl),
    bridgeTimeout: bridgeTimeout,
  );

  /// Release the websocket. The channel dials again if used afterwards.
  Future<void> close() async {
    final connection = _connection;
    _connection = null;
    await connection?.close();
  }

  // Never polls: no debugger is attached, because enabling the Debugger domain
  // changes how the page behaves.
  @override
  Future<String?> pausedReason() async => null;

  @override
  Future<String> unansweredNote(Duration pauseReadBound) async =>
      'The page did not answer. If it is paused in the browser\'s DevTools '
      '(a breakpoint, or pause-on-exceptions), resume it; a hidden or '
      'backgrounded tab draws no frames, so anything waiting for one waits.';

  @override
  Future<bool> waitForServiceExtension(String method) async {
    await _installed(bridgeTimeout);
    // `registered` for an inspector extension waits for the binding, so it is
    // bounded here and a timeout is the answer "not (yet) registered".
    try {
      final value = await _evaluate(
        'await agent.registered(${jsonEncode(method)})',
      ).timeout(bridgeTimeout);
      return value == true;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<bool> waitForBinding() async {
    await _installed(bridgeTimeout);
    try {
      await _evaluate('await agent.bindingReady()').timeout(bridgeTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>?> callServiceExtension(
    String method, {
    Map<String, String>? args,
  }) async {
    final text = await _evaluate(
      'await agent.call(${jsonEncode(method)}, '
      '${jsonEncode(jsonEncode(args ?? const <String, String>{}))})',
      ceiling: _callCeiling,
    );
    final Object? reply;
    try {
      reply = jsonDecode(text as String);
    } on Object {
      throw AppChannelException(
        'the page\'s agent bridge answered $method with something that is not '
        'JSON: $text',
      );
    }
    if (reply is! Map) {
      throw AppChannelException(
        'the page\'s agent bridge answered $method with $reply, not an object',
      );
    }
    if (reply['unregistered'] == true) {
      throw RPCError.withDetails(
        method,
        RPCErrorKind.kMethodNotFound.code,
        'Method not found',
        details: '$method is not registered in the page',
      );
    }
    if (reply['error'] case final Map error) {
      throw RPCError.withDetails(
        method,
        error['code'] is int
            ? error['code'] as int
            : RPCErrorKind.kInvalidParams.code,
        'Invalid params',
        details: '${error['detail']}',
      );
    }
    final result = reply['result'];
    return result is Map ? result.cast<String, dynamic>() : null;
  }

  @override
  Future<bool> waitForFirstFrame({
    required Duration timeout,
    Future<void>? until,
  }) async {
    final spent = clock.stopwatch()..start();
    final wait = () async {
      await _installed(timeout);
      final left = timeout - spent.elapsed;
      try {
        await _evaluate(
          'await agent.firstFrame()',
        ).timeout(left.isNegative ? Duration.zero : left);
        return true;
      } on TimeoutException {
        return false;
      }
    }();
    if (until == null) return wait;
    // Left running if the run ends first: the evaluation settles into nothing
    // when the socket closes.
    unawaited(wait.then<void>((_) {}, onError: (Object _) {}));
    return Future.any([wait, until.then((_) => false)]);
  }

  /// Wait, inside the page, for the bridge to exist, and say so if it never
  /// does within [timeout].
  Future<void> _installed(Duration timeout) async {
    try {
      await _evaluate('true').timeout(timeout);
    } on TimeoutException {
      throw AppChannelException(
        'the page never installed the rules_flutter agent bridge within '
        '${timeout.inSeconds}s. The agent surface is compiled into debug web '
        'builds only, so this is a non-debug build, a build made before the '
        'bridge existed, or a page that is not the app.',
      );
    }
  }

  /// Evaluate [body] in the app's page once its bridge is installed, with
  /// `agent` bound to the bridge, and return the value.
  ///
  /// A page that navigates mid-evaluation (a restart is `Page.reload`) or a
  /// websocket that drops is retried once, on the new document and a new
  /// connection.
  Future<Object?> _evaluate(
    String body, {
    Duration ceiling = _callCeiling,
  }) async {
    final expression =
        '(async () => {'
        r'if (!globalThis.$rulesFlutterAgent) await new Promise(r => '
        "addEventListener('rulesflutteragentready', r, {once: true}));"
        r'const agent = globalThis.$rulesFlutterAgent;'
        'return $body;'
        '})()';
    for (var attempt = 0; ; attempt++) {
      try {
        final connection = await _open();
        final Map<String, dynamic> reply;
        try {
          reply = await connection.send('Runtime.evaluate', {
            'expression': expression,
            'awaitPromise': true,
            'returnByValue': true,
          }, timeout: ceiling);
        } on StateError {
          if (connection.isClosed && identical(_connection, connection)) {
            _connection = null;
          }
          rethrow;
        }
        final result = reply['result'];
        if (result is Map && result['exceptionDetails'] is Map) {
          final details = result['exceptionDetails'] as Map;
          final description =
              (details['exception'] as Map?)?['description'] ?? details['text'];
          if (_navigated('$description')) throw StateError('$description');
          throw AppChannelException(
            'evaluating in the page threw: $description',
          );
        }
        return (result as Map?)?['result'] is Map
            ? ((result as Map)['result'] as Map)['value']
            : null;
      } on StateError catch (e) {
        // Between two documents — the page loading, or a restart's reload
        // committing — there is no context to evaluate in. Wait for the next
        // one and go again: that is the page arriving, not failing.
        if (e.message.contains(_noContext) && attempt < _contextWaits) {
          await _awaitDefaultContext();
          continue;
        }
        if (attempt == 0 && _navigated(e.message)) continue;
        throw AppChannelException(
          'could not talk to the app\'s page over the browser\'s DevTools '
          'endpoint: ${e.message}',
        );
      } on IOException catch (e) {
        if (attempt == 0) {
          _connection = null;
          continue;
        }
        throw AppChannelException(
          'could not reach the browser\'s DevTools endpoint: $e',
        );
      }
    }
  }

  /// What Chrome answers an evaluation sent while the page has no document.
  static const _noContext = 'Cannot find default execution context';

  /// How many times one evaluation waits out a missing document. A load that
  /// lands between the wait and the retry can need a second; more than a few
  /// is a page that keeps navigating, which is reported rather than chased.
  static const _contextWaits = 3;

  /// Wait for the page to have a document to evaluate in.
  ///
  /// `Runtime.enable` reports every context that already exists and then each
  /// new one, so subscribing first and enabling after cannot miss a context
  /// created in between — and disabling first makes an enable on a connection
  /// that had it on report them again. Off again afterwards: an enabled
  /// Runtime domain streams the page's console over this socket.
  Future<void> _awaitDefaultContext() async {
    final connection = await _open();
    final created = connection.events
        .where(
          (e) =>
              e['method'] == 'Runtime.executionContextCreated' &&
              ((e['params'] as Map?)?['context'] as Map?)?['auxData'] is Map &&
              (((e['params'] as Map)['context'] as Map)['auxData']
                      as Map)['isDefault'] ==
                  true,
        )
        .first;
    try {
      await connection.send('Runtime.disable', const {});
      await connection.send('Runtime.enable', const {});
      await created.timeout(bridgeTimeout);
    } on StateError {
      // The socket dropped mid-wait; the caller's next attempt dials again.
      if (!connection.isClosed) rethrow;
    } on TimeoutException {
      throw AppChannelException(
        'the app\'s page had no document to evaluate in for '
        '${bridgeTimeout.inSeconds}s: it never finished loading',
      );
    } finally {
      unawaited(created.then<void>((_) {}, onError: (Object _) {}));
      if (!connection.isClosed) {
        await connection
            .send('Runtime.disable', const {})
            .then<void>((_) {}, onError: (Object _) {});
      }
    }
  }

  /// Whether [message] says the page's document, or the connection to it, went
  /// away under the evaluation.
  static bool _navigated(String message) {
    final m = message.toLowerCase();
    return m.contains('navigated or closed') ||
        m.contains('context was destroyed') ||
        m.contains('cannot find context') ||
        m.contains('connection closed') ||
        m.contains('connection was closed');
  }

  Future<CdpSender> _open() {
    final current = _connection;
    if (current != null && !current.isClosed) return Future.value(current);
    return _connecting ??= _connect()
        .then((c) {
          _connection = c;
          return c;
        })
        .whenComplete(() => _connecting = null);
  }
}
