/// A suite running in a web app, spoken to over the Chrome DevTools Protocol.
///
/// A dart2wasm or dart2js bundle has no VM service for the host to call, so the
/// suite's channel (`_channel_web.dart` of the support library) is a pair of
/// page-level hooks, the same shape as the agent's bridge
/// (`browser_extension_channel.dart`):
///
///  * host to app: the page publishes `globalThis.$rulesFlutterIntegration` with
///    a `send(jsonText)` that pushes one message into the suite, and announces it
///    with a `rulesflutterintegrationready` event on `window`; the host calls it
///    through `Runtime.evaluate`;
///  * app to host: the page calls `globalThis.rulesFlutterIntegrationPost(jsonText)`,
///    a binding the host added with `Runtime.addBinding`, and the host receives a
///    `Runtime.bindingCalled` event carrying the text.
///
/// Only the process that launched the browser holds its debugging port, so the
/// channel needs no token and no server.
///
/// The host speaks first in the suite protocol (`remote_suite.dart`), and the
/// page posts only in answer. So once the bridge exists the binding does too,
/// when it is added first, and nothing polls and nothing races.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_rule_tools/remote_suite.dart';

import '../browser_extension_channel.dart' show CdpSender;
import 'golden_requests.dart';
import 'lost_before_suite.dart';

/// The name of the binding the page calls to post to the host.
const cdpBindingName = 'rulesFlutterIntegrationPost';

/// The name of the binding the page calls to ask the host about a golden: the
/// JSON text of `{id, op, key, bytes}`, `bytes` in base64. It is answered by
/// calling `golden(jsonText)` of the bridge with `{id, matched}` or
/// `{id, error}`.
const cdpGoldenBindingName = 'rulesFlutterGoldenPost';

/// The global the page publishes the host's way in under.
const _bridge = r'globalThis.$rulesFlutterIntegration';

/// The event the page dispatches on `window` once [_bridge] exists.
const _readyEvent = 'rulesflutterintegrationready';

/// How long one evaluation may be held open. The caller bounds the wait for the
/// suite itself; this only keeps an evaluation from outliving the run if it
/// does not.
const _evaluationCeiling = Duration(hours: 2);

/// The browser's page went away before it installed the suite's bridge, with
/// why.
///
/// Distinct from a transport lost mid-suite, which a [RemoteSuiteDriver]
/// reports as the failure of the test it interrupted: here there is no test.
class PageLostBeforeSuite extends LostBeforeSuite {
  /// Says what became of the page.
  PageLostBeforeSuite(super.reason);

  @override
  String toString() =>
      'the page was lost before it installed the integration test bridge: '
      '$reason';
}

/// A [SuiteTransport] over [_page], the DevTools connection of the page running
/// the suite.
class CdpSuiteTransport implements IntegrationSuiteTransport {
  CdpSuiteTransport._(this._page, this._whyLost) {
    // Subscribed before anything is asked of the page, so that no event falls
    // between a command and the listener for what it provokes.
    _events = _page.events.listen(_onEvent, onDone: _onClosed);
  }

  /// Connects to the suite in the page behind [page].
  ///
  /// Adds the binding the page posts through before anything else, then waits
  /// for the page to install its bridge: in the page, on its own event, so
  /// there is no polling and no sleep, and the wait ends when the app has
  /// started the suite however long its load took, or when the page is lost:
  /// [whyLost] is then asked and a [PageLostBeforeSuite] says so. The caller
  /// bounds the whole wait.
  ///
  /// [whyLost] says why the connection to the page closed: the browser's exit,
  /// in the device's words, or null when the device cannot tell.
  static Future<CdpSuiteTransport> connect(
    CdpSender page, {
    required Future<String?> Function() whyLost,
  }) async {
    final transport = CdpSuiteTransport._(page, whyLost);
    try {
      // Without this the page's `Inspector.targetCrashed` is never sent, and a
      // crashed page would be a wait that ends at Bazel's timeout.
      await page.send('Inspector.enable', const {});
      // Before the binding is added: measured on Chrome for Testing, a binding
      // added to a client that has not enabled the domain is never installed
      // in the page, and one added after enabling is, and its calls are
      // reported. The domain streams the page's console over this connection
      // too, which nothing here reads: the console reaches the test log through
      // the browser device's own connection.
      await page.send('Runtime.enable', const {});
      await page.send('Runtime.addBinding', {'name': cdpBindingName});
      await page.send('Runtime.addBinding', {'name': cdpGoldenBindingName});
      final installed = transport._awaitBridge();
      // An evaluation the wait gives up on settles into nothing when the
      // connection closes.
      unawaited(installed.then<void>((_) {}, onError: (Object _) {}));
      await Future.any([
        installed,
        transport._lost.future.then<Object?>(
          (reason) => throw PageLostBeforeSuite(reason ?? _unknownReason),
        ),
      ]);
      return transport;
    } on StateError catch (e) {
      // The connection closed under a command: the same fact the close itself
      // reports, with the device's account of it.
      final reason = transport._lost.isCompleted
          ? await transport._lost.future
          : '${e.message}. ${await _closedBecause(whyLost)}';
      await transport._events.cancel();
      throw PageLostBeforeSuite(reason ?? _unknownReason);
    } on PageLostBeforeSuite {
      await transport._events.cancel();
      rethrow;
    }
  }

  /// Evaluates, in the page's main frame, the wait for the bridge.
  ///
  /// Only where there is a default execution context, which a page that is
  /// still loading has not got: `Runtime.evaluate` then answers "Cannot find
  /// default execution context", and a page that navigates answers "Execution
  /// context was destroyed" to an evaluation in the context it left. Either
  /// is the page not being there yet, so the host waits, on the event of a
  /// context being created, for the next one and asks in it: no polling and
  /// no sleep.
  Future<void> _awaitBridge() async {
    var asked = 0;
    while (true) {
      await _contextAfter(asked);
      asked = _contextGeneration;
      try {
        await _page.send('Runtime.evaluate', {
          'expression':
              '(async () => {'
              'if (!$_bridge) await new Promise(r => '
              "addEventListener('$_readyEvent', r, {once: true}));"
              'return true;'
              '})()',
          'awaitPromise': true,
          'returnByValue': true,
        }, timeout: _evaluationCeiling);
        return;
      } on StateError catch (e) {
        if (!_contextGoneMessages.any(e.message.contains)) rethrow;
      }
    }
  }

  /// How many default execution contexts the page has created.
  var _contextGeneration = 0;
  Completer<void>? _contextCreated;

  /// Completes once the page has created a default context after the
  /// [generation]th, which is at once if it already has.
  Future<void> _contextAfter(int generation) async {
    while (_contextGeneration <= generation) {
      await (_contextCreated ??= Completer<void>()).future;
    }
  }

  static const _contextGoneMessages = [
    'Cannot find default execution context',
    'Execution context was destroyed',
    'Cannot find context with specified id',
    'Inspected target navigated or closed',
  ];

  /// What the page behind [page] shows of how far it got: its URL, whether
  /// its document has loaded, whether it is cross-origin isolated (which the
  /// WebAssembly renderer's threads need), whether Flutter's loader is there,
  /// and the resources it has fetched, each with its status.
  ///
  /// For a page that never installed its bridge, which otherwise says nothing:
  /// a fetch that failed, a loader that never ran and a main thread that is
  /// stuck are told apart by this. Asked in [answerWithin], since a stuck
  /// page does not answer, which is then what this says.
  static Future<String> describePage(
    CdpSender page, {
    Duration answerWithin = const Duration(seconds: 5),
  }) async {
    final Map<String, dynamic> reply;
    try {
      reply = await page
          .send(
            'Runtime.evaluate',
            {'expression': _pageStateProbe, 'returnByValue': true},
            // The connection's own bound, past the one this wait keeps.
            timeout: answerWithin * 2,
          )
          .timeout(answerWithin);
    } on TimeoutException {
      return 'The page did not answer an evaluation within '
          '${answerWithin.inSeconds}s, so its main thread is busy or stuck.';
    } on StateError catch (e) {
      return 'Asking the page how far it got failed: ${e.message}.';
    }
    final value = reply['result']?['result']?['value'];
    final Object? state = value is String ? json.decode(value) : null;
    if (state is! Map) {
      return 'Asked how far it got, the page answered ${reply['result']}.';
    }
    final loaded = (state['loaded'] as List?)?.join(', ');
    return 'The page is at ${state['url']}, its document is '
        '${state['readyState']}, it is '
        '${state['crossOriginIsolated'] == true ? '' : 'not '}cross-origin '
        'isolated, Flutter\'s loader is '
        '${state['flutterLoader'] == true ? '' : 'not '}there, and it has '
        'fetched ${loaded == null || loaded.isEmpty ? 'nothing' : loaded}.';
  }

  /// The page's own account of how far it got, as JSON text: see
  /// [describePage]. A resource's status is 0 when the browser does not say
  /// (an opaque or a cached response).
  static const _pageStateProbe =
      '(() => JSON.stringify({'
      'url: location.href,'
      'readyState: document.readyState,'
      'crossOriginIsolated: self.crossOriginIsolated,'
      'flutterLoader: !!(globalThis._flutter && globalThis._flutter.loader),'
      "loaded: performance.getEntriesByType('resource').map(e => "
      "new URL(e.name).pathname.split('/').pop() + ' ' + e.responseStatus),"
      '}))()';

  static const _unknownReason =
      'the connection to the browser closed, and the device could not say why';

  static Future<String> _closedBecause(
    Future<String?> Function() whyLost,
  ) async => await whyLost() ?? _unknownReason;

  final CdpSender _page;
  final Future<String?> Function() _whyLost;
  late final StreamSubscription<Map<String, dynamic>> _events;
  final _incoming = StreamController<String>();
  final _goldenRequests = StreamController<GoldenRequest>();
  final _lost = Completer<String?>();
  var _closing = false;

  /// The sends in flight, one after another: the page handles the messages of a
  /// conversation in the order they were sent.
  Future<void> _sending = Future.value();

  void _loseWith(String reason) {
    if (_closing || _lost.isCompleted) return;
    _lost.complete(reason);
  }

  void _onEvent(Map<String, dynamic> event) {
    final params = event['params'];
    switch (event['method']) {
      case 'Runtime.bindingCalled':
        if (params is! Map) return;
        final payload = params['payload'];
        if (payload is! String) return;
        switch (params['name']) {
          case cdpBindingName:
            if (!_incoming.isClosed) _incoming.add(payload);
          case cdpGoldenBindingName:
            _onGoldenRequest(payload);
        }
      case 'Runtime.executionContextCreated':
        final context = params is Map ? params['context'] : null;
        final aux = context is Map ? context['auxData'] : null;
        if (aux is Map && aux['isDefault'] == true) {
          _contextGeneration++;
          _contextCreated?.complete();
          _contextCreated = null;
        }
      case 'Inspector.targetCrashed':
        _loseWith('the page crashed (Inspector.targetCrashed)');
      case 'Inspector.detached':
        final reason = params is Map ? params['reason'] : null;
        _loseWith('the browser detached from the page ($reason)');
    }
  }

  Future<void> _onClosed() async {
    if (_closing || _lost.isCompleted) return;
    final reason = await _closedBecause(_whyLost);
    _loseWith(reason);
  }

  void _onGoldenRequest(String payload) {
    final Object? request = json.decode(payload);
    if (request is! Map || _goldenRequests.isClosed) return;
    final operation = GoldenOperation.named('${request['op']}');
    if (operation == null) {
      _loseWith('the page asked for a golden to be "${request['op']}"');
      return;
    }
    _goldenRequests.add(
      GoldenRequest(
        id: request['id']! as int,
        operation: operation,
        key: request['key']! as String,
        bytes: base64.decode(request['bytes']! as String),
      ),
    );
  }

  @override
  Stream<GoldenRequest> get goldenRequests => _goldenRequests.stream;

  @override
  Future<void> answerGolden(int id, GoldenAnswer answer) async {
    final error = answer.error;
    final reply = await _page.send('Runtime.evaluate', {
      // The answer is a JSON string handed to the bridge as a string literal.
      'expression':
          '$_bridge.golden(${jsonEncode(json.encode({'id': id, if (error != null) 'error': error else 'matched': answer.matched}))})',
      'returnByValue': true,
    }, timeout: _evaluationCeiling);
    final result = reply['result'];
    if (result is Map && result['exceptionDetails'] is Map) {
      final details = result['exceptionDetails'] as Map;
      final description =
          (details['exception'] as Map?)?['description'] ?? details['text'];
      throw StateError(
        'the page refused the answer to golden $id: $description',
      );
    }
  }

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<String?> get lostReason => _lost.future;

  @override
  void send(String json) {
    if (_closing || _lost.isCompleted) return;
    _sending = _sending.then((_) async {
      if (_closing || _lost.isCompleted) return;
      try {
        final reply = await _page.send('Runtime.evaluate', {
          // A JSON string is a JavaScript string literal, so the bridge is
          // handed the text exactly as it was sent.
          'expression': '$_bridge.send(${jsonEncode(json)})',
          'returnByValue': true,
        }, timeout: _evaluationCeiling);
        final result = reply['result'];
        if (result is Map && result['exceptionDetails'] is Map) {
          final details = result['exceptionDetails'] as Map;
          final description =
              (details['exception'] as Map?)?['description'] ?? details['text'];
          _loseWith('the page refused a message: $description');
        }
      } on StateError catch (e) {
        // A connection that closed under the call is reported by the close
        // itself, with the device's account of why; any other failure is the
        // browser refusing the command.
        if (_closing || _lost.isCompleted || _page.isClosed) return;
        _loseWith('the browser refused a message: ${e.message}');
      }
    });
  }

  @override
  Future<void> close() async {
    // The last message, the suite's own `close`, is still in flight.
    await _sending;
    _closing = true;
    await _events.cancel();
    unawaited(_incoming.close()); // done when its listener is, if it has one
    unawaited(_goldenRequests.close());
    await _page.close();
  }

  @override
  Future<void> abandon(String why) async {
    _closing = true;
    await _events.cancel();
    unawaited(_incoming.close()); // done when its listener is, if it has one
    unawaited(_goldenRequests.close());
    unawaited(_page.close());
  }
}
