/// What a run of an integration test does when something other than a test
/// fails, and the verdict it gives for the ways a suite can end: each one ends
/// the run with a reason that names its cause, instead of a hang until Bazel
/// kills the target, and a run that never started the suite never says it
/// passed.
library;

import 'dart:async';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/integration/integration_runner_config.dart';
import 'package:flutter_bazel_dev_tool/integration/integration_test_run.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service_io.dart';

import 'fake_suite_app.dart';
import 'fakes.dart';

/// A device whose launch is whatever the test says.
class _FakeDevice extends Device {
  _FakeDevice(this._launch);

  final Future<AppInstance> Function() _launch;
  final stopped = <AppInstance>[];
  String? exitedBecause;

  @override
  String get name => 'fake';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      _launch();

  @override
  Future<void> stop(AppInstance instance) async => stopped.add(instance);

  @override
  Future<String?> whyAppExited(AppInstance instance) async => exitedBecause;
}

final _config = IntegrationRunnerConfig(
  family: IntegrationFamily.desktop,
  appArtifacts: const ['_main/app.zip'],
  launcher: const {},
  testDisplayName: '//pkg:app_test',
  env: const {},
);

void main() {
  late FakeSuiteApp app;
  late StringBuffer out;
  late StringBuffer err;
  setUp(() async {
    app = await FakeSuiteApp.start();
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => app.stop());

  Future<int> run(
    _FakeDevice device, {
    Map<String, String> environment = const {},
    Future<Future<void> Function()> Function()? prepare,
  }) => runIntegrationTest(
    _config,
    resolve: (path) => '/runfiles/$path',
    choice: DeviceChoice(device, prepare ?? () async => () async {}),
    environment: {'TEST_TIMEOUT': '60', ...environment},
    dial: vmServiceConnectUri,
    out: out,
    err: err,
  );

  AppInstance appRunning() =>
      AppInstance(process: FakeProcess(), vmServiceUri: app.httpUri);

  test(
    'a launch that fails fails the run, in the launch\'s own words',
    () async {
      final device = _FakeDevice(() async => throw StateError('no such app'));

      expect(await run(device), 1);

      expect(err.toString(), contains('launching the app failed'));
      expect(err.toString(), contains('no such app'));
    },
  );

  test('an app that announces no VM service fails the run, since the suite is '
      'driven through it', () async {
    final device = _FakeDevice(() async => AppInstance(process: FakeProcess()));

    expect(await run(device), 1);

    expect(err.toString(), contains('did not announce a VM service'));
  });

  test('an app that ends before registering the suite fails the run with the '
      'device\'s account of how it ended, and is stopped', () async {
    app.isolates['isolates/1'] = {};
    final instance = appRunning();
    final device = _FakeDevice(() async => instance)
      ..exitedBecause = 'The fake app exited with code 3 after announcing.';

    final result = run(device);
    await app.answeredGetVm.future;
    await app.vanish();

    expect(await result, 1);
    expect(err.toString(), contains('before it registered'));
    expect(err.toString(), contains('exited with code 3'));
    expect(device.stopped, [instance]);
  });

  test('a host that cannot give the device what it needs fails the run, '
      'saying what, before launching anything', () async {
    var launched = false;
    final device = _FakeDevice(() async {
      launched = true;
      return appRunning();
    });

    final result = await run(
      device,
      prepare: () async => throw StateError('the screen is locked'),
    );

    expect(result, 1);
    expect(err.toString(), contains('the screen is locked'));
    expect(launched, isFalse);
  });

  test('what the host gave the device is given back when the run ends, '
      'however it ends', () async {
    var given = false;
    final device = _FakeDevice(() async => throw StateError('launch failed'));

    await run(
      device,
      prepare: () async =>
          () async => given = true,
    );

    expect(given, isTrue);
  });

  test('a --test_filter that is not a regular expression is a usage error, '
      'not a run that selected nothing', () async {
    final device = _FakeDevice(() async => appRunning());

    final result = await run(
      device,
      environment: {'TESTBRIDGE_TEST_ONLY': '('},
    );

    expect(result, 64);
    expect(err.toString(), contains('not a regular expression'));
  });

  test('an app whose suite never registers fails at the ceiling, naming the '
      'extension it waited for', () async {
    // No isolate ever registers the extension: the wait is bounded by the
    // ceiling Bazel's own timeout gives, here the shortest it allows.
    app.isolates['isolates/1'] = {};
    final device = _FakeDevice(() async => appRunning());

    final result = await run(device, environment: {'TEST_TIMEOUT': '11'});

    expect(result, 1);
    expect(
      err.toString(),
      contains('did not register ext.flutter.integrationTest'),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
