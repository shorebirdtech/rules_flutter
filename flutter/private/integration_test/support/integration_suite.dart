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

import 'package:integration_test/integration_test.dart';
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
    preparePlatform();
    return testExecutable == null ? suiteMain : () => testExecutable(suiteMain);
  });
  connectSuiteChannel(testChannel);
}
