/// What a run of an integration test does when something other than a test
/// fails, and the verdict it gives for the ways a suite can end: each one ends
/// the run with a reason that names its cause, instead of a hang until Bazel
/// kills the target, and a run that never started the suite never says it
/// passed.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/integration/integration_runner_config.dart';
import 'package:flutter_bazel_dev_tool/integration/integration_test_run.dart';
import 'package:flutter_bazel_dev_tool/integration/suite_connectors.dart';
import 'package:path/path.dart' as p;
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
    choice: DeviceChoice(
      device,
      prepare ?? () async => () async {},
      vmServiceConnector(dial: vmServiceConnectUri),
    ),
    environment: {'TEST_TIMEOUT': '60', ...environment},
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

  group('the device of a web config', () {
    final webConfig = IntegrationRunnerConfig(
      family: IntegrationFamily.web,
      appArtifacts: const ['_main/app_web'],
      launcher: const {'chrome': 'chrome+/chrome-headless-shell'},
      testDisplayName: '//pkg:web_test',
      env: const {},
    );

    test('is a headless Chrome, and the one the runner named, resolved from '
        'the runfiles', () async {
      final choice = await chooseDevice(
        webConfig,
        os: 'linux',
        resolve: (path) => '/runfiles/$path',
      );

      final device = choice.device as WebDevice;
      expect(device.webOptions!.browser.headless, isTrue);
      expect(
        (await device.requiredHostTools()).single.candidates,
        ['/runfiles/chrome+/chrome-headless-shell'],
      );
    });

    test('a config that names no browser is refused, naming the key', () async {
      final unnamed = IntegrationRunnerConfig(
        family: IntegrationFamily.web,
        appArtifacts: const ['_main/app_web'],
        launcher: const {},
        testDisplayName: '//pkg:web_test',
        env: const {},
      );

      await expectLater(
        chooseDevice(unnamed, os: 'linux', resolve: (p) => p),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('"launcher.chrome"'),
          ),
        ),
      );
    });
  });

  group('the device of an Android config', () {
    late Directory scratch;
    late String sdkAdb;
    late String runfilesAdb;
    setUp(() {
      scratch = Directory.systemTemp.createTempSync('android_choice_test');
      // The SDK the runner's `adb` belongs to, and the runfiles entry that
      // links to it, as Bazel's `@androidsdk` repository does.
      final sdk = Directory(p.join(scratch.path, 'sdk'));
      sdkAdb = p.join(sdk.path, 'platform-tools', 'adb');
      File(sdkAdb).createSync(recursive: true);
      File(
        p.join(sdk.path, 'build-tools', '35.0.0', 'aapt2'),
      ).createSync(recursive: true);
      runfilesAdb = p.join(scratch.path, 'runfiles', 'adb');
      Directory(p.dirname(runfilesAdb)).createSync(recursive: true);
      Link(runfilesAdb).createSync(sdkAdb);
    });
    tearDown(() => scratch.deleteSync(recursive: true));

    final androidConfig = IntegrationRunnerConfig(
      family: IntegrationFamily.android,
      appArtifacts: const ['_main/app.apk'],
      launcher: const {'adb': 'androidsdk/platform-tools/adb'},
      testDisplayName: '//pkg:android_test',
      env: const {},
    );

    Future<DeviceChoice> choose({
      Map<String, String> environment = const {},
      required String devices,
      List<List<String>>? asked,
    }) => chooseDevice(
      androidConfig,
      os: 'macos',
      resolve: (path) => runfilesAdb,
      environment: environment,
      runAdb: (executable, arguments) async {
        asked?.add([executable, ...arguments]);
        return ProcessResult(0, 0, devices, '');
      },
      lockDirectory: Directory(p.join(scratch.path, 'locks')),
    );

    const oneDevice = 'List of devices attached\n58051JEBF01271\tdevice\n';
    const twoDevices =
        'List of devices attached\n58051JEBF01271\tdevice\n'
        'emulator-5554\tdevice\n';

    test('is the attached device, driven with the adb the runner named and '
        'the aapt2 of the same SDK, and expects the VM service a debug app '
        'serves', () async {
      final asked = <List<String>>[];

      final choice = await choose(devices: oneDevice, asked: asked);

      final device = choice.device as AndroidDevice;
      expect(device.deviceId, '58051JEBF01271');
      expect(device.adbPath, runfilesAdb);
      expect(
        device.aapt2Path,
        p.join(
          scratch.resolveSymbolicLinksSync(),
          'sdk',
          'build-tools',
          '35.0.0',
          'aapt2',
        ),
      );
      expect(device.expectsVmService, isTrue);
      expect(asked, [
        [runfilesAdb, 'devices'],
      ]);
    });

    test('is the one ANDROID_SERIAL names when several are attached', () async {
      final choice = await choose(
        devices: twoDevices,
        environment: {'ANDROID_SERIAL': 'emulator-5554'},
      );

      expect((choice.device as AndroidDevice).deviceId, 'emulator-5554');
    });

    test('is refused when several are attached and none is named, naming '
        '`adb devices`', () async {
      await expectLater(
        choose(devices: twoDevices),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('`adb devices`'), contains('ANDROID_SERIAL')),
          ),
        ),
      );
    });

    test(
      'is refused when the SDK of the adb has no aapt2, naming it',
      () async {
        File(
          p.join(scratch.path, 'sdk', 'build-tools', '35.0.0', 'aapt2'),
        ).deleteSync();

        await expectLater(
          choose(devices: oneDevice),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('aapt2'), contains('build-tools')),
            ),
          ),
        );
      },
    );

    test(
      'is refused when the runner\'s adb is not there, naming the path',
      () async {
        File(sdkAdb).deleteSync();

        await expectLater(
          choose(devices: oneDevice),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('adb'), contains(runfilesAdb)),
            ),
          ),
        );
      },
    );

    test('takes the lock on its serial for the run, so two tests do not '
        'install over each other', () async {
      final lockFile = File(
        p.join(scratch.path, 'locks', 'android-58051JEBF01271.lock'),
      );
      final choice = await choose(devices: oneDevice);
      expect(lockFile.existsSync(), isFalse, reason: 'taken when the run is');

      final give = await choice.prepare();

      expect(lockFile.existsSync(), isTrue);
      await give();
    });
  });
}
