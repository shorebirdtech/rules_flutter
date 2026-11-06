/// One integration test run: launch the app on its device, drive the suite it
/// runs over the channel its device gives (a native app's VM service, a web
/// app's DevTools connection), report each test, stop the app.
///
/// What `flutter test integration_test/x_test.dart -d <device>` does, with
/// Bazel's test protocol in place of `flutter test`'s reporters: a
/// `--test_filter` and a shard select tests, a JUnit file is written to
/// `XML_OUTPUT_FILE`, and the target fails if any selected test did, or none
/// ran.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_rule_tools/remote_suite.dart';
import 'package:path/path.dart' as p;
import 'package:rules_flutter_macos_gui_session/macos_gui_session.dart';

import '../device.dart';
import '../host_tools.dart';
import '../web_options.dart';
import 'android_serial.dart';
import 'device_lock.dart';
import 'golden_comparator.dart';
import 'golden_requests.dart';
import 'golden_service_process.dart';
import 'integration_runner_config.dart';
import 'linux_runtime.dart';
import 'suite_connectors.dart';
import 'test_simulator.dart';

/// What the run needs of its host beyond the device: the locks and the
/// desktop session the device's family asks for, taken before the app is
/// launched and given back after it is stopped.
typedef HostPreparation = Future<Future<void> Function()> Function();

/// A device and what must be true of the host to use it.
class DeviceChoice {
  /// A [device], the [prepare] that has to run before it is launched on, and
  /// the [connect] that reaches the suite of an app launched on it.
  const DeviceChoice(this.device, this.prepare, this.connect);

  /// The device the app runs on.
  final Device device;

  /// Takes what the device needs of the host, and returns what gives it back.
  /// Fails, naming the remedy, when the host cannot give it.
  final HostPreparation prepare;

  /// How the suite of an app launched on [device] is reached.
  final SuiteConnector connect;
}

/// The device `config` runs on, on a host whose operating system is [os].
///
/// [resolve] turns a runfiles path into a file, for what the runner's config
/// names (the browser, the `adb`). [environment] is the test's environment,
/// which names the Android device (`ANDROID_SERIAL`). [run] runs the host's own
/// tools (`adb` to list the attached devices, `simctl` to make a simulator),
/// [lockDirectory] is where a device's lock is kept, and [processId] is the run
/// a simulator is named for, unless a test of this says otherwise.
/// [startIsolated] starts a Linux test's X server, unless a test of this says
/// otherwise.
///
/// Throws a [StateError] for a device no runner has been written for, or one
/// the host does not have: the run fails, saying so, rather than falling back
/// to another.
Future<DeviceChoice> chooseDevice(
  IntegrationRunnerConfig config, {
  required String os,
  required String Function(String runfilesPath) resolve,
  Map<String, String> environment = const {},
  ProcessRunSync? run,
  Directory? lockDirectory,
  int? processId,
  void Function(String message)? log,
  IsolatedProcessStarter? startIsolated,
}) async {
  switch (config.family) {
    case IntegrationFamily.desktop when os == 'macos':
      return DeviceChoice(
        MacOSDevice(),
        () => _prepareMacOs(log),
        vmServiceConnector(),
      );
    case IntegrationFamily.desktop when os == 'windows':
      // No lock and no session probe, as macOS has. Measured on a Windows VM:
      // windows that overlap keep drawing (two tests' windows at one origin
      // each completed forty awaited frames), so tests need not take turns on
      // the screen, and an app started from an SSH logon, which has no visible
      // desktop, drew and was driven all the same. An app that cannot start
      // is reported by the launch, by name (`whyAppExited`, `SuiteUnreachable`).
      return DeviceChoice(
        WindowsDevice(),
        () async => () async {},
        vmServiceConnector(),
      );
    case IntegrationFamily.desktop when os == 'linux':
      // The app draws on an X server of the test's own, with the runtime's
      // GTK and software OpenGL: never the host's display or libraries. No
      // lock and no session probe: each test has a screen to itself.
      final runtime = _linuxRuntime(config, resolve);
      final device = LinuxDevice();
      return DeviceChoice(device, () async {
        final cache = _cacheDir(environment);
        final display = await runtime.startDisplay(
          host: environment,
          cacheDir: cache,
          start: startIsolated ?? startIsolatedProcess,
        );
        device.environment = runtime.environment(
          host: environment,
          cacheDir: cache,
          display: display.number,
        );
        return display.stop;
      }, vmServiceConnector());
    case IntegrationFamily.desktop:
      throw StateError(
        'integration tests run on macOS, Windows and Linux desktops; this host '
        'is $os, which has no runner.',
      );
    case IntegrationFamily.web when os == 'linux':
      final runtime = _linuxRuntime(config, resolve);
      final browserEnvironment = runtime.environment(
        host: environment,
        cacheDir: _cacheDir(environment),
      );
      return DeviceChoice(
        WebDevice(
          chromePath: resolve(config.chromePath),
          startProcess: (exe, args) =>
              startIsolatedProcess(exe, args, browserEnvironment),
        )..webOptions = _linuxHeadlessWebOptions,
        () async => () async {},
        chromePageConnector(),
      );
    case IntegrationFamily.web:
      return DeviceChoice(
        WebDevice(chromePath: resolve(config.chromePath))
          ..webOptions = headlessWebOptions,
        () async => () async {},
        chromePageConnector(),
      );
    case IntegrationFamily.android:
      final adb = resolve(config.adbPath);
      final serial = await chooseAndroidSerial(
        adb: adb,
        requested: environment['ANDROID_SERIAL'],
        run: run ?? Process.run,
      );
      return DeviceChoice(
        AndroidDevice(
            deviceId: serial,
            adbPath: adb,
            aapt2Path: _aapt2OfSdkOf(adb),
          )
          // A debug app serves the VM service the suite is driven through, and
          // cannot without the INTERNET permission, which the launch checks.
          ..expectsVmService = true,
        () => _hold('android-$serial', lockDirectory, log),
        vmServiceConnector(),
      );
    case IntegrationFamily.iosSimulator when os == 'macos':
      final device = TestSimulatorDevice();
      final deviceType = config.simulatorDeviceType;
      final runtime = config.simulatorRuntime;
      return DeviceChoice(device, () async {
        // Made when the run takes what it needs of the host, not before: a run
        // that is refused earlier has made nothing to remove.
        final simulator = await TestSimulator.create(
          name: testSimulatorName(config.testDisplayName, processId ?? pid),
          deviceType: deviceType,
          runtime: runtime,
          run: run ?? Process.run,
        );
        device.simulator = simulator;
        return simulator.remove;
      }, vmServiceConnector());
    case IntegrationFamily.iosSimulator:
      throw StateError(
        'iOS simulators run on macOS; this host is $os, which has none.',
      );
  }
}

/// The `aapt2` of the Android SDK that [adb] belongs to.
///
/// The runner's `adb` is a link to the SDK's own, and the build tools that read
/// the APK's package and launchable activity are the same SDK's: found from the
/// `adb`, never from the host's environment, so a test reads the APK with the
/// tools of the SDK it was built against.
String _aapt2OfSdkOf(String adb) {
  final String sdk;
  try {
    sdk = p.dirname(p.dirname(File(adb).resolveSymbolicLinksSync()));
  } on FileSystemException catch (e) {
    throw StateError(
      'the runner\'s adb $adb is not there (${e.osError?.message ?? e.message}): '
      'the Android SDK it links to is gone.',
    );
  }
  return aapt2Tool(environment: {'ANDROID_HOME': sdk, 'PATH': ''}).require();
}

/// Takes the lock [key] for the run, and returns what gives it back.
Future<Future<void> Function()> _hold(
  String key,
  Directory? directory,
  void Function(String message)? log,
) async {
  final lock = await DeviceLock.acquire(key, directory: directory, log: log);
  return lock.release;
}

/// What a test's browser is: headless, serving the bundle as a static site, with
/// the cross-origin isolation `flutter_bazel run -d chrome --wasm` serves a
/// WebAssembly app under (the renderer's threads need it), and no debugger, so
/// no expression evaluation.
const headlessWebOptions = WebOptions(
  server: WebServerOptions(crossOriginIsolation: true),
  browser: BrowserLaunchOptions(headless: true),
  enableExpressionEvaluation: false,
);

/// [headlessWebOptions] on a Linux host, where the browser runs without its
/// sandbox, as upstream's headless Chrome always does. The sandbox needs the
/// host set up for it: unprivileged user namespaces, which Ubuntu since 23.10
/// denies to programs AppArmor has no profile for ("No usable sandbox!", on
/// Ubuntu 24.04), or Chrome's set-user-ID helper installed by root. The page
/// is the test's own.
const _linuxHeadlessWebOptions = WebOptions(
  server: WebServerOptions(crossOriginIsolation: true),
  browser: BrowserLaunchOptions(
    headless: true,
    browserFlags: ['--no-sandbox'],
  ),
  enableExpressionEvaluation: false,
);

/// The Linux runtime the runner of [config] carries. Throws a [StateError]
/// for a runner that carries none: a Linux test runs with nothing of the
/// host's but its C and C++ runtime.
LinuxRuntime _linuxRuntime(
  IntegrationRunnerConfig config,
  String Function(String runfilesPath) resolve,
) {
  final runtime = config.linuxRuntime;
  if (runtime == null) {
    throw StateError(
      'the runner has no Linux runtime, which a Linux test runs its app or '
      'browser with: give the runner rule `linux_runtime` (the default '
      'runners of @rules_flutter//flutter/integration_test do).',
    );
  }
  return LinuxRuntime.fromConfig(runtime, resolve);
}

/// Where fontconfig keeps its cache for this test: under the test's own
/// temporary directory, which Bazel removes.
String _cacheDir(Map<String, String> environment) {
  final base = environment['TEST_TMPDIR'] ?? Directory.systemTemp.path;
  return '$base/linux_runtime_cache';
}

/// The lock on the screen and the held-awake session a macOS window needs.
Future<Future<void> Function()> _prepareMacOs(
  void Function(String message)? log,
) async {
  final lock = await DeviceLock.acquire('macos-gui', log: log);
  GuiSession? session;
  try {
    session = await GuiSession.hold();
    final state = await GuiSession.probe();
    if (state.screenLocked || state.displayAsleep) {
      throw StateError(
        'the app cannot show a window: ${GuiSession.explain(GuiSession.diagnose(state))} '
        '(Read: $state.)',
      );
    }
  } catch (_) {
    await session?.release();
    await lock.release();
    rethrow;
  }
  return () async {
    await session?.release();
    await lock.release();
  };
}

/// Runs the integration test [config] describes and returns the exit status
/// the target should end with.
///
/// [resolve] turns a runfiles path into a file. [environment] is the test's
/// environment: Bazel's variables for the selection, the timeout and the
/// report. [terminated] has an event when the test is told to end (Bazel
/// terminates a test that runs out of time): the run is undone as it ends any
/// other way, the app stopped and what the host gave given back, and ends with
/// 143. By default that is SIGTERM and SIGINT.
///
/// The goldens the app asks about are compared by the golden service the config
/// names, started by [startGoldenService] (by default as a process) when the
/// first is asked, and written instead of compared when [updateGoldens].
Future<int> runIntegrationTest(
  IntegrationRunnerConfig config, {
  required String Function(String runfilesPath) resolve,
  required DeviceChoice choice,
  required Map<String, String> environment,
  StringSink? out,
  StringSink? err,
  Stream<void>? terminated,
  bool updateGoldens = false,
  GoldenServiceLauncher? startGoldenService,
}) async {
  final sink = out ?? stdout;
  final errors = err ?? stderr;
  final TestSelection selection;
  try {
    selection = TestSelection.fromEnvironment(environment);
  } on FormatException catch (e) {
    errors.writeln('integration_test: ${e.message}');
    return 64;
  }
  // Touched before the run, as Bazel asks: it is how a runner says it supports
  // sharding at all, and Bazel 9 fails a sharded test whose runner never does.
  final shardStatus = environment['TEST_SHARD_STATUS_FILE'];
  if (shardStatus != null) File(shardStatus).writeAsStringSync('');

  final teardown = _Teardown(choice.device, errors);
  final ended = Completer<int>();
  final signals = (terminated ?? _terminationSignals()).listen((_) {
    if (ended.isCompleted) return;
    errors.writeln('integration_test: the test was terminated, so it ends.');
    // The status is the answer once the run is undone, whichever of this and
    // the run's own end undoes it first.
    ended.complete(143);
    unawaited(teardown.run());
  });
  try {
    final result = await Future.any([
      _drive(
        config,
        resolve: resolve,
        choice: choice,
        environment: environment,
        selection: selection,
        out: sink,
        err: errors,
        teardown: teardown,
        updateGoldens: updateGoldens,
        startGoldenService: startGoldenService,
      ),
      ended.future,
    ]);
    if (ended.isCompleted) await teardown.done;
    return result == 0 && teardown.failed ? 1 : result;
  } finally {
    await signals.cancel();
  }
}

/// SIGTERM and SIGINT, where the platform has them.
Stream<void> _terminationSignals() {
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  late final StreamController<void> controller;
  controller = StreamController<void>(
    onListen: () {
      if (Platform.isWindows) return;
      for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
        subscriptions.add(signal.watch().listen(controller.add));
      }
    },
    onCancel: () => Future.wait(subscriptions.map((s) => s.cancel())),
  );
  return controller.stream;
}

/// What a run has to undo as it ends: the transport and the app it started
/// and what the host gave it. Once, however many things end the run.
class _Teardown {
  _Teardown(this._device, this._errors);

  final Device _device;
  final StringSink _errors;

  SuiteTransport? transport;
  GoldenHost? goldens;
  AppInstance? instance;
  Future<void> Function()? give;

  /// Whether something could not be undone, which fails the run: a simulator
  /// that was left behind is not a pass.
  bool failed = false;

  Future<void>? _running;

  /// Completes when [run] has.
  Future<void> get done => _running ?? Future.value();

  Future<void> run() => _running ??= _undo();

  Future<void> _undo() async {
    try {
      if (transport != null) await transport!.abandon('the run is over');
      // After the transport, whose end is the end of what the app asks.
      await goldens?.close();
      if (instance != null) {
        await _device.stop(instance!);
      } else {
        await _device.abandonLaunch();
      }
    } on Object catch (e) {
      failed = true;
      _errors.writeln('integration_test: stopping the app failed: $e');
    }
    final giveBack = give;
    if (giveBack != null) {
      try {
        await giveBack();
      } on StateError catch (e) {
        failed = true;
        _errors.writeln('integration_test: ${e.message}');
      }
    }
  }
}

Future<int> _drive(
  IntegrationRunnerConfig config, {
  required String Function(String runfilesPath) resolve,
  required DeviceChoice choice,
  required Map<String, String> environment,
  required TestSelection selection,
  required StringSink out,
  required StringSink err,
  required _Teardown teardown,
  required bool updateGoldens,
  required GoldenServiceLauncher? startGoldenService,
}) async {
  final bazelTimeout = environment['TEST_TIMEOUT'];
  final ceiling = testCeiling(bazelTimeout);
  final device = choice.device;

  try {
    teardown.give = await choice.prepare();
  } on StateError catch (e) {
    err.writeln('integration_test: ${e.message}');
    return 1;
  }

  try {
    final AppInstance instance;
    try {
      await device.preflight();
      final artifact = device.pickArtifact([
        for (final path in config.appArtifacts) resolve(path),
      ]);
      instance = teardown.instance = await device.launch(
        artifact,
        onLog: (line) => err.writeln('[app] ${line.text}'),
      );
    } on Object catch (e) {
      err.writeln('integration_test: launching the app failed: $e');
      return 1;
    }

    final IntegrationSuiteTransport connected;
    try {
      connected = await choice.connect(device, instance, ceiling: ceiling);
    } on SuiteUnreachable catch (e) {
      err.writeln('integration_test: ${e.message}');
      return 1;
    }
    teardown.transport = connected;
    teardown.goldens = GoldenHost(
      connected,
      _goldenComparator(
        config,
        resolve: resolve,
        environment: environment,
        update: updateGoldens,
        ceiling: ceiling,
        start: startGoldenService,
      ),
      update: updateGoldens,
      log: (message) => err.writeln('integration_test: $message'),
    );

    final outcome =
        await RemoteSuiteDriver(
          connected,
          suitePath: config.testDisplayName,
          timeout: suiteTimeout(bazelTimeout),
          logPrefix: 'integration_test',
          failOnNoTests: true,
          out: out,
          err: err,
        ).run(
          selection: selection,
          xmlOutput: environment['XML_OUTPUT_FILE'],
          ceiling: ceiling,
        );
    out.writeln(outcome.summary());
    return outcome.exitCode;
  } finally {
    await teardown.run();
  }
}

/// The comparator for the goldens the app asks about: the service the config
/// names, or one that says there is none.
GoldenComparator _goldenComparator(
  IntegrationRunnerConfig config, {
  required String Function(String runfilesPath) resolve,
  required Map<String, String> environment,
  required bool update,
  required Duration ceiling,
  required GoldenServiceLauncher? start,
}) {
  final goldens = config.goldens;
  if (goldens == null) {
    return const NoGoldenComparator(
      'this test was given no golden comparator. The `flutter_*_integration_test` '
      'macros declare one; a test made of the rules themselves gives its '
      'source as `src` and the comparator as `golden_service`.',
    );
  }
  final executable = resolve(goldens.executable);
  return GoldenServiceComparator(
    testPath: goldens.testSource,
    ceiling: ceiling,
    environment: goldenServiceEnvironment(
      environment,
      goldens.environment,
      update: update,
    ),
    launch: (serviceEnvironment) => (start ?? _startProcess(executable))(
      serviceEnvironment,
    ),
  );
}

GoldenServiceLauncher _startProcess(String executable) =>
    (environment) => startGoldenServiceProcess(executable, environment);
