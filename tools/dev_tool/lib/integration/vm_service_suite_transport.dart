/// A suite running in an app, spoken to over the app's VM service: what
/// `flutter test integration_test/x_test.dart -d <device>` does.
///
/// The host calls the service extension `ext.flutter.integrationTest` with
/// `{data: <json>}`, and the app calls `developer.postEvent` of kind
/// `Flutter.IntegrationTest` on the Extension stream with `{data: <json>}`.
/// The app does not dial the host, so nothing about the device has to reach
/// back: whatever already reaches the app's VM service (a loopback socket, a
/// port forward, a tunnel) carries the suite too.
library;

import 'dart:async';

import 'package:flutter_rule_tools/remote_suite.dart';
import 'package:vm_service/vm_service.dart';

import 'lost_before_suite.dart';

/// The service extension the app registers for the host's messages.
const integrationTestMethod = 'ext.flutter.integrationTest';

/// The kind of the event the app posts for each of its messages.
const integrationTestEventKind = 'Flutter.IntegrationTest';

/// The key both directions carry the JSON text under.
const integrationTestDataKey = 'data';

/// The JSON-RPC code of `streamListen` on a stream already subscribed.
const _streamAlreadySubscribed = 103;

/// The app went away before it registered [integrationTestMethod], with why.
class AppLostBeforeSuite extends LostBeforeSuite {
  /// Says what became of the app.
  AppLostBeforeSuite(super.reason);

  @override
  String toString() =>
      'the app ended before it registered $integrationTestMethod: $reason';
}

/// A [SuiteTransport] over [service], the VM service of the app running the
/// suite.
class VmServiceSuiteTransport implements SuiteTransport {
  VmServiceSuiteTransport._(this._service, this._isolateId, this._whyLost) {
    _events = service.onExtensionEvent
        .where(
          (event) =>
              event.extensionKind == integrationTestEventKind &&
              (event.isolate?.id ?? _isolateId) == _isolateId,
        )
        .map(
          (event) =>
              event.extensionData!.data[integrationTestDataKey]! as String,
        )
        .listen(_incoming.add);
    unawaited(
      _service.onDone.then((_) async {
        if (_closing || _lost.isCompleted) return;
        final why = await _whyLost();
        if (!_lost.isCompleted) _lost.complete(why);
      }),
    );
  }

  /// Connects to the suite in the app behind [service].
  ///
  /// Waits for the isolate that registers [integrationTestMethod], which is the
  /// one running the test bootstrap: its registrations already made are read
  /// from the isolates the VM lists, and later ones arrive as
  /// `ServiceExtensionAdded` events on the Isolate stream, which is subscribed
  /// first so none falls between the two. There is no polling and no sleep, so
  /// the wait ends when the app has started the suite, however long its build
  /// and launch took, or when the app ends: [whyLost] is then asked and an
  /// [AppLostBeforeSuite] says so. The caller bounds the whole wait.
  ///
  /// [whyLost] says why the connection to the app closed: the app's exit, in
  /// the device's words, or null when the device cannot tell.
  static Future<VmServiceSuiteTransport> connect(
    VmService service, {
    required Future<String?> Function() whyLost,
  }) async {
    Future<String> why() async =>
        await whyLost() ??
        'the connection to the app\'s VM service closed, and the device '
            'could not say why';

    final found = Completer<String>();
    final registrations = service.onIsolateEvent.listen((event) {
      final id = event.isolate?.id;
      if (event.kind == EventKind.kServiceExtensionAdded &&
          event.extensionRPC == integrationTestMethod &&
          id != null &&
          !found.isCompleted) {
        found.complete(id);
      }
    });
    final ended = service.onDone.then<String>((_) => why());
    try {
      try {
        await _subscribe(service, EventStreams.kIsolate);
        await _subscribe(service, EventStreams.kExtension);

        // What registered before the listener existed is not replayed.
        final vm = await service.getVM();
        for (final ref in vm.isolates ?? const <IsolateRef>[]) {
          final id = ref.id;
          if (id == null || found.isCompleted) continue;
          final Isolate isolate;
          try {
            isolate = await service.getIsolate(id);
          } on SentinelException {
            continue;
          }
          // The registration event may have been delivered while the isolate
          // was being read.
          if (!found.isCompleted &&
              (isolate.extensionRPCs ?? const <String>[]).contains(
                integrationTestMethod,
              )) {
            found.complete(id);
          }
        }
      } on RPCError catch (e) {
        // The app ended while the isolates were being read.
        if (!_isConnectionDisposed(e)) rethrow;
        throw AppLostBeforeSuite(await ended);
      }

      final isolateId = await Future.any([
        found.future,
        ended.then<String>((reason) => throw AppLostBeforeSuite(reason)),
      ]);
      return VmServiceSuiteTransport._(service, isolateId, why);
    } finally {
      await registrations.cancel();
    }
  }

  /// A stream already subscribed is the state asked for.
  static Future<void> _subscribe(VmService service, String stream) async {
    try {
      await service.streamListen(stream);
    } on RPCError catch (e) {
      if (e.code != _streamAlreadySubscribed) rethrow;
    }
  }

  final VmService _service;

  /// The VM service this transport speaks over.
  VmService get service => _service;

  final String _isolateId;
  final Future<String> Function() _whyLost;
  final _incoming = StreamController<String>();
  final _lost = Completer<String?>();
  late final StreamSubscription<String> _events;
  var _closing = false;

  /// The sends in flight, one after another: the app handles the messages of a
  /// conversation in the order they were sent.
  Future<void> _sending = Future.value();

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
        await _service.callServiceExtension(
          integrationTestMethod,
          isolateId: _isolateId,
          args: {integrationTestDataKey: json},
        );
      } on RPCError catch (e) {
        // A connection that closed under the call is reported by `onDone`, with
        // the device's account of why; any other failure is the app refusing
        // the message, which nothing after it can recover from.
        if (_closing || _lost.isCompleted || _isConnectionDisposed(e)) return;
        _lost.complete('the app refused a message: ${e.message}');
      }
    });
  }

  /// Whether [e] says the connection closed under the call, which `package:vm_service`
  /// words as `RPCError(-32000, "Service connection disposed")`.
  static bool _isConnectionDisposed(RPCError e) =>
      e.code == -32000 && e.message.contains('Service connection disposed');

  @override
  Future<void> close() async {
    // The last message, the suite's own `close`, is still in flight.
    await _sending;
    _closing = true;
    await _events.cancel();
    unawaited(_incoming.close()); // done when its listener is, if it has one
    await _service.dispose();
  }

  @override
  Future<void> abandon(String why) async {
    _closing = true;
    await _events.cancel();
    unawaited(_incoming.close()); // done when its listener is, if it has one
    unawaited(_service.dispose());
  }
}
