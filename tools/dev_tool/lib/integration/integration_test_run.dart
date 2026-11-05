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
import 'integration_runner_config.dart';
import 'suite_connectors.dart';

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
/// which names the Android device (`ANDROID_SERIAL`). [runAdb] runs the `adb`
/// that lists the attached devices, and [lockDirectory] is where a device's
/// lock is kept, unless a test of this says otherwise.
///
/// Throws a [StateError] for a device no runner has been written for, or one
/// the host does not have: the run fails, saying so, rather than falling back
/// to another.
Future<DeviceChoice> chooseDevice(
  IntegrationRunnerConfig config, {
  required String os,
  required String Function(String runfilesPath) resolve,
  Map<String, String> environment = const {},
  ProcessRunSync? runAdb,
  Directory? lockDirectory,
  void Function(String message)? log,
}) async {
  switch (config.family) {
    case IntegrationFamily.desktop when os == 'macos':
      return DeviceChoice(
        MacOSDevice(),
        () => _prepareMacOs(log),
        vmServiceConnector(),
      );
    case IntegrationFamily.desktop:
      throw StateError(
        'integration tests run on macOS desktops; this host is $os, which has '
        'no runner.',
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
        run: runAdb ?? Process.run,
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
    case IntegrationFamily.iosSimulator:
      throw StateError(
        'integration tests on "${config.family.key}" devices are not '
        'supported by this runner.',
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
/// report.
Future<int> runIntegrationTest(
  IntegrationRunnerConfig config, {
  required String Function(String runfilesPath) resolve,
  required DeviceChoice choice,
  required Map<String, String> environment,
  StringSink? out,
  StringSink? err,
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

  final bazelTimeout = environment['TEST_TIMEOUT'];
  final ceiling = testCeiling(bazelTimeout);
  final device = choice.device;

  Future<void> Function()? give;
  try {
    give = await choice.prepare();
  } on StateError catch (e) {
    errors.writeln('integration_test: ${e.message}');
    return 1;
  }

  AppInstance? instance;
  SuiteTransport? transport;
  try {
    try {
      await device.preflight();
      final artifact = device.pickArtifact([
        for (final path in config.appArtifacts) resolve(path),
      ]);
      instance = await device.launch(
        artifact,
        onLog: (line) => errors.writeln('[app] ${line.text}'),
      );
    } on Object catch (e) {
      errors.writeln('integration_test: launching the app failed: $e');
      return 1;
    }

    final SuiteTransport connected;
    try {
      connected = await choice.connect(device, instance, ceiling: ceiling);
    } on SuiteUnreachable catch (e) {
      errors.writeln('integration_test: ${e.message}');
      return 1;
    }
    transport = connected;

    final outcome =
        await RemoteSuiteDriver(
          connected,
          suitePath: config.testDisplayName,
          timeout: suiteTimeout(bazelTimeout),
          logPrefix: 'integration_test',
          failOnNoTests: true,
          out: sink,
          err: errors,
        ).run(
          selection: selection,
          xmlOutput: environment['XML_OUTPUT_FILE'],
          ceiling: ceiling,
        );
    sink.writeln(outcome.summary());
    return outcome.exitCode;
  } finally {
    if (transport != null) await transport.abandon('the run is over');
    if (instance != null) await device.stop(instance);
    await give();
  }
}
