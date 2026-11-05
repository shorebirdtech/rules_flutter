// The part of an integration test's program that is the same for every test:
// run the suite and connect it to the host.
//
// A near-verbatim port of the bootstrap `flutter test integration_test/x_test.dart
// -d <device>` generates (`generateTestBootstrap(..., integrationTest: true)` in
// flutter_tools), minus what that generator bakes into the text of each
// bootstrap: this file is staged as it is and the generated bootstrap only calls
// it.
//
// It is compiled as the program's own source, against whatever
// `package:integration_test`, `package:flutter_test` and `package:test_api` the
// program's `deps` provide.
import 'dart:async';
import 'dart:isolate';

import 'package:integration_test/integration_test.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:test_api/backend.dart';

import '_channel.dart';

/// Runs [testMain], the `main` of the integration test file, as a suite the host
/// drives, and connects the suite to the host.
///
/// [testExecutable] is the `testExecutable` of the nearest
/// `flutter_test_config.dart`, if there is one: it is handed the test's main
/// and runs it, as `flutter test` does.
///
/// Returns once the suite is registered. The program then runs until the host
/// ends it: the host speaks first, so nothing here has to wait for it.
Future<void> runIntegrationSuite(
  FutureOr<void> Function() testMain, {
  Future<void> Function(FutureOr<void> Function())? testExecutable,
}) async {
  Future<void> suiteMain() async {
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();
    // Not returned: if the user's `main` is annotated with `@doNotStore`, its
    // result may not be propagated.
    await Future<void>(testMain);
  }

  final testChannel = RemoteListener.start(() {
    _catchIsolateErrors();
    VmServiceProxyGoldenFileComparator.useIfRunningOnDevice();
    return testExecutable == null ? suiteMain : () => testExecutable(suiteMain);
  });
  connectSuiteChannel(testChannel);
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
