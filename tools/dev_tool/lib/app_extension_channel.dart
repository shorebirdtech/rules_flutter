/// How the `app.*` agent commands reach the running app's service extensions.
///
/// The commands proxy to `ext.rules_flutter.*` (and the framework's
/// `ext.flutter.inspector.*`). A native app and the DDC dev loop expose those
/// over a VM service; a bundled web build (dart2wasm, dart2js) has no VM
/// service, and reaches them through a JavaScript bridge the generated main
/// installs on the page, driven over the Chrome DevTools Protocol. Both are an
/// [AppExtensionChannel], so the commands are written once.
library;

import 'dart:async';

import 'vm_service_client.dart';

/// The extension whose presence means the Flutter binding exists.
///
/// Registered by `BindingBase.initServiceExtensions`, so it appears exactly
/// when `WidgetsFlutterBinding.ensureInitialized()` runs — which is what every
/// handler in the agent needs and what the inspector RPCs are registered
/// alongside. The agent's own extensions are registered *earlier* than this on
/// web (pre-`bootstrapEngine`, deliberately, so the startup window is covered),
/// so their presence alone does not mean the app can answer: dispatching in
/// between gets `Binding has not yet been initialized` from inside the handler.
const bindingServiceExtension = 'ext.flutter.reassemble';

/// The channel itself failing, as opposed to the app answering badly: the
/// browser cannot be reached, or the page never installed the agent bridge.
///
/// Its [message] is what the command reports, so it names the cause. An app
/// refusing a call is an `RPCError` on every channel, not this.
class AppChannelException implements Exception {
  final String message;
  const AppChannelException(this.message);

  @override
  String toString() => message;
}

/// A way to ask a running app's service extensions questions and to call them.
///
/// An app's refusal of a call (`ServiceExtensionResponse.error` on its side) is
/// thrown as `RPCError` from `package:vm_service` with `details` holding the
/// app's text, on every implementation, so the caller has one path for it.
abstract interface class AppExtensionChannel {
  /// Why the app cannot run Dart right now (paused at a breakpoint, say), or
  /// null when it can or the channel cannot tell.
  Future<String?> pausedReason();

  /// Wait until the app has registered [method], returning whether it did.
  Future<bool> waitForServiceExtension(String method);

  /// Wait until the Flutter binding has registered its service extensions (the
  /// moment [bindingServiceExtension] appears), returning whether it did.
  Future<bool> waitForBinding();

  /// Call [method] with [args] and return the extension's result object.
  Future<Map<String, dynamic>?> callServiceExtension(
    String method, {
    Map<String, String>? args,
  });

  /// Wait for the app's first rendered frame, returning whether it came within
  /// [timeout] and before [until] completed.
  Future<bool> waitForFirstFrame({
    required Duration timeout,
    Future<void>? until,
  });

  /// What to say about the app when a dispatched call was not answered within
  /// its bound. [pauseReadBound] bounds any read this has to make to find out.
  Future<String> unansweredNote(Duration pauseReadBound);
}

/// [AppExtensionChannel] over a VM service connection: native, and the DDC dev
/// loop once DWDS has handed its connection over.
class VmExtensionChannel implements AppExtensionChannel {
  final VmServiceClient client;

  VmExtensionChannel(this.client);

  @override
  Future<String?> pausedReason() => client.pausedReason();

  @override
  Future<bool> waitForServiceExtension(String method) =>
      client.waitForServiceExtension(method);

  @override
  Future<bool> waitForBinding() =>
      client.waitForServiceExtension(bindingServiceExtension);

  @override
  Future<Map<String, dynamic>?> callServiceExtension(
    String method, {
    Map<String, String>? args,
  }) => client.callServiceExtension(method, args: args);

  @override
  Future<bool> waitForFirstFrame({
    required Duration timeout,
    Future<void>? until,
  }) => client.waitForFirstFrame(timeout: timeout, until: until);

  /// What the app's isolate looked like when a dispatch gave up on it.
  ///
  /// Three states, kept apart, because they send the reader to three different
  /// places: a pause names itself and a debugger resumes it; no pause means the
  /// app was running and simply never returned from the handler; and a read
  /// that did not answer either says the VM service is the problem, not the
  /// app.
  @override
  Future<String> unansweredNote(Duration pauseReadBound) async {
    try {
      final reason = await client.pausedReason().timeout(pauseReadBound);
      return reason == null
          ? 'Its isolate reported no pause, so the app was running and the '
                'handler never returned — a backgrounded app stops producing '
                'frames, and any unbounded wait for one never ends.'
          : 'Its isolate is paused: $reason';
    } on TimeoutException {
      return 'Its isolate\'s pause state could not be read within '
          '${pauseReadBound.inSeconds}s either, so the VM service connection '
          'is no longer answering.';
    }
  }
}
