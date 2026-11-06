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
import 'package:flutter_bazel_dev_tool/integration/test_simulator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vm_service/vm_service_io.dart';

import 'fake_suite_app.dart';
import 'fakes.dart';

/// What the Android SDK calls aapt2 on this host.
final _aapt2 = Platform.isWindows ? 'aapt2.exe' : 'aapt2';

/// A device whose launch is whatever the test says.
class _FakeDevice extends Device {
  _FakeDevice(this._launch);

  final Future<AppInstance> Function() _launch;
  final stopped = <AppInstance>[];
  var abandoned = 0;
  String? exitedBecause;

  @override
  Future<void> abandonLaunch() async => abandoned++;

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

const _linuxRuntime = {
  'root': 'rt/root',
  'triple': 'x86_64-linux-gnu',
  'xvfb': 'rt/runtime/Xvfb',
  'fontsConf': 'rt/fonts.conf',
};

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
    Stream<void> terminated = const Stream.empty(),
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
    terminated: terminated,
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
        os: 'macos',
        resolve: (path) => '/runfiles/$path',
      );

      final device = choice.device as WebDevice;
      expect(device.webOptions!.browser.headless, isTrue);
      expect(
        (await device.requiredHostTools()).single.candidates,
        ['/runfiles/chrome+/chrome-headless-shell'],
      );
    });

    test('on Linux runs the browser with the runner\'s runtime and without '
        'its sandbox', () async {
      final linuxConfig = IntegrationRunnerConfig(
        family: IntegrationFamily.web,
        appArtifacts: const ['_main/app_web'],
        launcher: const {
          'chrome': 'chrome+/chrome-headless-shell',
          'linuxRuntime': _linuxRuntime,
        },
        testDisplayName: '//pkg:web_test',
        env: const {},
      );
      final choice = await chooseDevice(
        linuxConfig,
        os: 'linux',
        resolve: (path) => '/runfiles/$path',
        environment: const {'DISPLAY': ':0', 'TEST_TMPDIR': '/tmp/t'},
      );

      final device = choice.device as WebDevice;
      expect(device.webOptions!.browser.headless, isTrue);
      expect(device.webOptions!.browser.browserFlags, ['--no-sandbox']);
    });

    test('on Linux is refused when the runner has no runtime, naming the '
        'attribute', () async {
      await expectLater(
        chooseDevice(webConfig, os: 'linux', resolve: (p) => p),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('linux_runtime'),
          ),
        ),
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
        chooseDevice(unnamed, os: 'macos', resolve: (p) => p),
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

  group('the device of a desktop config', () {
    test('is the Windows desktop on a Windows host, which takes nothing of the '
        'host beforehand', () async {
      final choice = await chooseDevice(
        _config,
        os: 'windows',
        resolve: (path) => path,
      );

      expect(choice.device, isA<WindowsDevice>());
      final give = await choice.prepare();
      await give();
    });

    test('is the macOS desktop on a macOS host', () async {
      final choice = await chooseDevice(
        _config,
        os: 'macos',
        resolve: (path) => path,
      );

      expect(choice.device, isA<MacOSDevice>());
    });

    test('is refused on a host with no runner, naming the hosts that have '
        'one', () async {
      await expectLater(
        chooseDevice(_config, os: 'fuchsia', resolve: (path) => path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('macOS'),
              contains('Windows'),
              contains('Linux'),
              contains('fuchsia'),
            ),
          ),
        ),
      );
    });

    test('on Linux is an X server of the test\'s own, started when the host '
        'prepares and stopped when the run gives it back, which the app is '
        'shown on with the runtime\'s libraries', () async {
      final server = FakeProcess();
      final linuxConfig = IntegrationRunnerConfig(
        family: IntegrationFamily.desktop,
        appArtifacts: const ['_main/app'],
        launcher: const {'linuxRuntime': _linuxRuntime},
        testDisplayName: '//pkg:linux_test',
        env: const {},
      );
      final choice = await chooseDevice(
        linuxConfig,
        os: 'linux',
        resolve: (path) => '/runfiles/$path',
        environment: const {'DISPLAY': ':0', 'TEST_TMPDIR': '/tmp/t'},
        startIsolated: (exe, args, env) async => server,
      );
      final device = choice.device as LinuxDevice;
      expect(device.environment, isNull, reason: 'no display before prepare');

      final preparing = choice.prepare();
      await server.outputAttached;
      server.emitStdout('5');
      final give = await preparing;

      expect(device.environment!['DISPLAY'], ':5');
      expect(
        device.environment!['LD_LIBRARY_PATH'],
        '/runfiles/rt/root/usr/lib/x86_64-linux-gnu',
      );
      expect(server.killed, isFalse);
      await give();
      expect(server.killed, isTrue);
    });

    test('on Linux is refused when the runner has no runtime, naming the '
        'attribute', () async {
      await expectLater(
        chooseDevice(_config, os: 'linux', resolve: (path) => path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('linux_runtime'),
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
        p.join(sdk.path, 'build-tools', '35.0.0', _aapt2),
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
      run: (executable, arguments) async {
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
          _aapt2,
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
          p.join(scratch.path, 'sdk', 'build-tools', '35.0.0', _aapt2),
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

  group('the device of an iOS simulator config', () {
    final iosConfig = IntegrationRunnerConfig(
      family: IntegrationFamily.iosSimulator,
      appArtifacts: const ['_main/app.ipa'],
      launcher: const {'deviceType': 'iPhone 16', 'runtime': ''},
      testDisplayName: '//pkg:ios_test',
      env: const {},
    );

    test('is a simulator that exists only once the host has prepared, made '
        'for this test and gone when the run gives it back', () async {
      final asked = <List<String>>[];
      final choice = await chooseDevice(
        iosConfig,
        os: 'macos',
        resolve: (path) => path,
        processId: 4242,
        run: (executable, arguments) async {
          asked.add([executable, ...arguments]);
          return ProcessResult(
            0,
            0,
            arguments[1] == 'create' ? 'UDID-1\n' : '',
            '',
          );
        },
      );
      final device = choice.device as TestSimulatorDevice;
      expect(asked, isEmpty, reason: 'nothing is made before the run is');
      expect(() => device.udid, throwsStateError);

      final give = await choice.prepare();

      expect(device.udid, 'UDID-1');
      expect(asked, [
        [
          'xcrun',
          'simctl',
          'create',
          'rules_flutter-pkg_ios_test-4242',
          'iPhone 16',
        ],
      ]);
      await give();
      expect(asked.skip(1).map((c) => c.skip(1).take(2).join(' ')), [
        'simctl shutdown',
        'simctl delete',
      ]);
    });

    test('is refused off macOS, which is where the simulators are', () async {
      await expectLater(
        chooseDevice(iosConfig, os: 'linux', resolve: (p) => p),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('macOS'), contains('linux')),
          ),
        ),
      );
    });

    test('a config that names no device type is refused, naming the key', () {
      final unnamed = IntegrationRunnerConfig(
        family: IntegrationFamily.iosSimulator,
        appArtifacts: const ['_main/app.ipa'],
        launcher: const {'runtime': ''},
        testDisplayName: '//pkg:ios_test',
        env: const {},
      );

      expect(
        chooseDevice(unnamed, os: 'macos', resolve: (p) => p),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('"launcher.deviceType"'),
          ),
        ),
      );
    });
  });

  group('a run that is ended from outside', () {
    test('is stopped when Bazel terminates the test: the app is stopped and '
        'what the host gave is given back, so a timed-out run leaves nothing '
        'behind', () async {
      final launching = Completer<void>();
      final device = _FakeDevice(() {
        launching.complete();
        return Completer<AppInstance>().future;
      });
      var given = false;
      final terminate = StreamController<void>();

      final result = run(
        device,
        prepare: () async =>
            () async => given = true,
        terminated: terminate.stream,
      );
      await launching.future;
      terminate.add(null);

      expect(await result, 143);
      expect(given, isTrue);
      expect(device.abandoned, 1, reason: 'the launch in flight is undone');
      expect(err.toString(), contains('terminated'));
    });

    test(
      'is stopped once, though the run it interrupted finishes after',
      () async {
        final launched = Completer<AppInstance>();
        final started = Completer<void>();
        final device = _FakeDevice(() {
          started.complete();
          return launched.future;
        });
        var gave = 0;
        final terminate = StreamController<void>();

        final result = run(
          device,
          prepare: () async =>
              () async => gave++,
          terminated: terminate.stream,
        );
        await started.future;
        terminate.add(null);
        expect(await result, 143);

        launched.complete(appRunning());
        await pumpEventQueue();

        expect(gave, 1);
      },
    );
  });

  test('a host that cannot give back what it gave fails the run, saying '
      'what is left behind', () async {
    final device = _FakeDevice(() async => throw StateError('launch failed'));

    final result = await run(
      device,
      prepare: () async =>
          () async => throw StateError('the simulator X was not removed'),
    );

    expect(result, 1);
    expect(err.toString(), contains('the simulator X was not removed'));
  });
}
