/// The Android emulator an integration test runs on.
///
/// One is booted for each test run, from a cold start on a device (an AVD) made
/// in the test's own directory, and shut down when it ends, as the iOS
/// simulator of a test is: a test shares no state with another or with the
/// emulators and phones of the person running it.
///
/// The emulator answers to an `adb` server of the test's own, on a port of the
/// test's own, which looks at no USB or network device and for no emulator but
/// the one that registers with it. So the test never reaches a phone attached to
/// the host or another emulator. The emulator's own ports are in the range it
/// recommends, the one an `adb` server tries for emulators when it starts (5554
/// to 5585). An `adb` server of the person's that starts while the test runs
/// lists the emulator too, which does it no harm: an emulator takes several
/// `adb` servers at once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../device.dart' show ProcessRunSync;
import 'device_lock.dart' show LockFile;
import 'linux_runtime.dart' show IsolatedProcessStarter;
import 'test_simulator.dart' show processStartTime;

/// What the runner says the emulator is: the launcher's `emulator`.
class EmulatorSettings {
  const EmulatorSettings({
    required this.executable,
    required this.systemImage,
    required this.abi,
    required this.apiLevel,
    required this.tag,
    required this.cores,
    required this.memoryMb,
  });

  /// The settings of the launcher config's `emulator` object, whose runfiles
  /// paths are left for the caller to resolve. Throws a [FormatException]
  /// naming the key that is missing or of the wrong kind.
  factory EmulatorSettings.fromConfig(Map<String, Object?> config) {
    T value<T>(String key, String what) {
      final v = config[key];
      if (v is! T || (v is String && v.isEmpty)) {
        throw FormatException(
          'the config: "launcher.emulator.$key" must be $what, got '
          '${v == null ? 'nothing' : json.encode(v)}',
        );
      }
      return v;
    }

    return EmulatorSettings(
      executable: value<String>('executable', 'the emulator\'s runfiles path'),
      systemImage: value<String>(
        'systemImage',
        'the runfiles path of the system image\'s source.properties',
      ),
      abi: value<String>('abi', 'the system image\'s ABI'),
      apiLevel: value<int>('apiLevel', 'the system image\'s API level'),
      tag: value<String>('tag', 'the system image\'s tag'),
      cores: value<int>('cores', 'the device\'s CPU cores'),
      memoryMb: value<int>('memoryMb', 'the device\'s memory in MB'),
    );
  }

  /// The `emulator` launcher.
  final String executable;

  /// The system image's `source.properties`, whose directory is the image.
  final String systemImage;

  final String abi;
  final int apiLevel;
  final String tag;
  final int cores;
  final int memoryMb;

  /// The settings with [executable] and [systemImage] turned into files by
  /// [resolve].
  EmulatorSettings resolved(String Function(String runfilesPath) resolve) =>
      EmulatorSettings(
        executable: resolve(executable),
        systemImage: resolve(systemImage),
        abi: abi,
        apiLevel: apiLevel,
        tag: tag,
        cores: cores,
        memoryMb: memoryMb,
      );
}

/// The first console port a test's emulator may take: the first of the
/// emulator ports `adb` knows.
const firstEmulatorConsolePort = 5554;

/// How many emulators may run at once: the console and `adb` port pairs from
/// [firstEmulatorConsolePort] to 5585, the last port `adb` knows. A pair that
/// an emulator of the person's has is passed over.
const emulatorSlots = 16;

/// The first port of the tests' own `adb` servers, one per slot.
const firstAdbServerPort = 5700;

/// The ports of one test's emulator and `adb` server, held for the test's
/// run under a lock that the operating system releases however the test ends.
class EmulatorPorts {
  EmulatorPorts._(this.slot, this._lock, this._record);

  /// Which of the [emulatorSlots] this is.
  final int slot;

  final RandomAccessFile _lock;

  /// What the run that holds the ports started, for a later run to reclaim if
  /// this one is killed before it can stop it.
  final File _record;

  /// The emulator's console port, which names it: `emulator-<console>`.
  int get console => consolePortOf(slot);

  /// The port the emulator's `adbd` is reached on.
  int get adb => console + 1;

  /// The port of the test's own `adb` server.
  int get server => firstAdbServerPort + slot;

  /// The emulator's serial, as `adb devices` lists it.
  String get serial => 'emulator-$console';

  /// The console port of [slot].
  static int consolePortOf(int slot) => firstEmulatorConsolePort + 2 * slot;

  /// Records the emulator the run started, as process [pid] that started at
  /// [startedAt].
  void record(int pid, int startedAt) => _record.writeAsStringSync(
    json.encode({'pid': pid, 'startedAt': startedAt, 'server': server}),
  );

  /// Gives the ports up: the record is the run's no longer.
  Future<void> release() async {
    if (_record.existsSync()) _record.deleteSync();
    await _lock.unlock();
    await _lock.close();
  }

  /// Takes the first slot no other run holds whose ports are free.
  ///
  /// A slot whose lock is free but which has a record was held by a run that
  /// ended without stopping its emulator (a SIGKILL): [reclaim] stops what the
  /// record names before the slot is used, and [log] says so. A slot whose
  /// ports something else listens on is passed over. Throws a [StateError]
  /// when every slot is taken.
  static Future<EmulatorPorts> take({
    required Directory lockDirectory,
    required Future<bool> Function(int port) isFree,
    required Future<void> Function(EmulatorRecord record) reclaim,
    required void Function(String message) log,
    LockFile open = _openLockFile,
  }) async {
    lockDirectory.createSync(recursive: true);
    for (var slot = 0; slot < emulatorSlots; slot++) {
      final console = consolePortOf(slot);
      final base = p.join(lockDirectory.path, 'android-emulator-$console');
      final lock = await open('$base.lock');
      try {
        await lock.lock(FileLock.exclusive);
      } on FileSystemException {
        await lock.close();
        continue;
      }
      final ports = EmulatorPorts._(slot, lock, File('$base.json'));
      final left = EmulatorRecord.read(ports._record);
      if (left != null) {
        log(
          'stopping the emulator ${ports.serial} (process ${left.pid}): the '
          'run that booted it is gone',
        );
        await reclaim(left);
        ports._record.deleteSync();
      }
      if (await isFree(ports.console) &&
          await isFree(ports.adb) &&
          await isFree(ports.server)) {
        return ports;
      }
      await lock.unlock();
      await lock.close();
    }
    throw StateError(
      'all $emulatorSlots Android emulator port pairs (from '
      '$firstEmulatorConsolePort) are in use, by other tests\' emulators or '
      'by other programs: run fewer Android emulator tests at once '
      '(`--local_test_jobs`).',
    );
  }
}

Future<RandomAccessFile> _openLockFile(String path) =>
    File(path).open(mode: FileMode.append);

/// What a run that held a slot started.
class EmulatorRecord {
  const EmulatorRecord(this.pid, this.startedAt, this.server);

  /// The emulator's process, and when it started (as `ps` says), which tells
  /// it from a later process that reuses its id.
  final int pid;
  final int startedAt;

  /// The port of the run's `adb` server.
  final int server;

  /// The record in [file], or null when there is none or it is not one (a run
  /// killed while writing it).
  static EmulatorRecord? read(File file) {
    if (!file.existsSync()) return null;
    try {
      final value = json.decode(file.readAsStringSync());
      if (value case {
        'pid': final int pid,
        'startedAt': final int startedAt,
        'server': final int server,
      }) {
        return EmulatorRecord(pid, startedAt, server);
      }
    } on FormatException {
      // Half written: the run was killed before it started anything to stop.
    }
    return null;
  }
}

/// Whether nothing listens on the loopback [port], by listening on it.
Future<bool> loopbackPortIsFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// Stops what a killed run left: its emulator, if the process that the record
/// names is still that one, and its `adb` server.
Future<void> reclaimEmulator(
  EmulatorRecord record, {
  required String adb,
  required Map<String, String> adbEnvironment,
  required ProcessRunSync ps,
  required EnvironmentProcessRun run,
  bool Function(int pid, ProcessSignal signal) kill = Process.killPid,
}) async {
  if (await processStartTime(record.pid, ps) == record.startedAt) {
    kill(record.pid, ProcessSignal.sigkill);
  }
  await run(adb, [
    '-P',
    '${record.server}',
    'kill-server',
  ], adbEnvironment);
}

/// Runs [executable] with [arguments] in exactly [environment].
typedef EnvironmentProcessRun = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
);

/// The [EnvironmentProcessRun] of a real process.
Future<ProcessResult> runIsolatedProcess(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
) => Process.run(
  executable,
  arguments,
  environment: environment,
  includeParentEnvironment: false,
);

/// Where a test's emulator keeps what it writes: the device, its SDK root and
/// its home, all under the test's own directory.
class EmulatorScratch {
  EmulatorScratch(this.root);

  final String root;

  /// The SDK root the emulator is given: links to the emulator and the system
  /// image where the emulator looks for them, and the `platform-tools`
  /// directory without which it does not take a directory as an SDK.
  String get sdk => p.join(root, 'sdk');

  /// The home of the test's `adb`, where it keeps its key.
  String get home => p.join(root, 'home');

  String get androidHome => p.join(home, '.android');

  String get emulatorHome => p.join(root, 'emulator_home');

  String get avdHome => p.join(root, 'avd');

  String get tmp => p.join(root, 'tmp');
}

/// The name of the test's device.
const avdName = 'rules_flutter_test';

/// Lays out [scratch] for [settings]: the SDK root and the device.
void layOutEmulator(EmulatorScratch scratch, EmulatorSettings settings) {
  final image = p.dirname(settings.systemImage);
  final sdk = scratch.sdk;
  Directory(p.join(sdk, 'platform-tools')).createSync(recursive: true);
  Link(p.join(sdk, 'emulator')).createSync(p.dirname(settings.executable));
  final images = p.join(
    sdk,
    'system-images',
    'android-${settings.apiLevel}',
    settings.tag,
  );
  Directory(images).createSync(recursive: true);
  Link(p.join(images, settings.abi)).createSync(image);

  Directory(scratch.androidHome).createSync(recursive: true);
  Directory(scratch.emulatorHome).createSync(recursive: true);
  Directory(scratch.tmp).createSync(recursive: true);
  final device = p.join(scratch.avdHome, '$avdName.avd');
  Directory(device).createSync(recursive: true);
  File(p.join(scratch.avdHome, '$avdName.ini')).writeAsStringSync(
    'avd.ini.encoding=UTF-8\n'
    'path=$device\n'
    'target=android-${settings.apiLevel}\n',
  );
  File(p.join(device, 'config.ini')).writeAsStringSync(
    avdConfig(settings),
  );
}

/// The device's `config.ini`: a phone-sized screen at one pixel per logical
/// pixel, drawn in software, with nothing the test does not use (no audio,
/// camera, SD card or Play Store).
String avdConfig(EmulatorSettings settings) {
  final arch = settings.abi == 'arm64-v8a' ? 'arm64' : 'x86_64';
  return [
    'AvdId=$avdName',
    'avd.ini.displayname=$avdName',
    'abi.type=${settings.abi}',
    'hw.cpu.arch=$arch',
    'hw.cpu.ncore=${settings.cores}',
    'hw.ramSize=${settings.memoryMb}',
    'image.sysdir.1=system-images/android-${settings.apiLevel}/'
        '${settings.tag}/${settings.abi}/',
    'tag.id=${settings.tag}',
    'disk.dataPartition.size=2G',
    'hw.gpu.enabled=yes',
    'hw.gpu.mode=swiftshader_indirect',
    'hw.lcd.width=480',
    'hw.lcd.height=800',
    'hw.lcd.density=160',
    'hw.keyboard=yes',
    'hw.audioInput=no',
    'hw.audioOutput=no',
    'hw.camera.back=none',
    'hw.camera.front=none',
    'hw.sdCard=no',
    'PlayStore.enabled=false',
    'showDeviceFrame=no',
    '',
  ].join('\n');
}

/// The environment the test's `adb` runs in, server and client: its own port,
/// its own home, and nothing to look at but the emulator that registers with
/// it. `ADB_USB=0` keeps it off USB, where it would contend with the
/// person's own server for an attached phone; `ADB_EMU=0` keeps it from trying
/// the emulator ports of other emulators, whose `adbd` takes one server at a
/// time; `ADB_MDNS=0` keeps it from devices on the network.
Map<String, String> adbEnvironment({
  required Map<String, String> host,
  required EmulatorScratch scratch,
  required int server,
}) => {
  for (final MapEntry(:key, :value) in host.entries)
    if (!key.startsWith('ANDROID_') && !key.startsWith('ADB_')) key: value,
  'HOME': scratch.home,
  'ANDROID_USER_HOME': scratch.androidHome,
  'ANDROID_ADB_SERVER_PORT': '$server',
  'ADB_USB': '0',
  'ADB_EMU': '0',
  'ADB_MDNS': '0',
};

/// The environment the emulator runs in: [base] (the Linux runtime's, which
/// brings the X libraries the emulator links, or nothing on macOS), the SDK
/// root and home of [scratch], and the test's `adb` server, which it registers
/// with when it starts.
///
/// Its `PATH` is `/usr/bin:/bin` and nothing of the host's more.
Map<String, String> emulatorEnvironment({
  required Map<String, String> base,
  required EmulatorScratch scratch,
  required int server,
}) => {
  for (final MapEntry(:key, :value) in base.entries)
    if (!key.startsWith('ANDROID_') && !key.startsWith('ADB_')) key: value,
  'PATH': '/usr/bin:/bin',
  'HOME': scratch.emulatorHome,
  'TMPDIR': scratch.tmp,
  'ANDROID_SDK_ROOT': scratch.sdk,
  'ANDROID_AVD_HOME': scratch.avdHome,
  'ANDROID_EMULATOR_HOME': scratch.emulatorHome,
  'ANDROID_USER_HOME': scratch.emulatorHome,
  'ANDROID_ADB_SERVER_PORT': '$server',
};

/// The emulator's arguments: the test's device, with no window, audio or
/// boot animation, from a cold boot on fresh data that it saves nothing of,
/// at [ports].
List<String> emulatorArguments(EmulatorPorts ports) => [
  '-avd',
  avdName,
  '-no-window',
  '-no-audio',
  '-no-boot-anim',
  '-no-snapshot',
  '-wipe-data',
  '-no-metrics',
  '-gpu',
  'swiftshader_indirect',
  '-accel',
  'on',
  '-ports',
  '${ports.console},${ports.adb}',
];

/// Checks that the emulator can use the host's hypervisor, which it needs
/// to run at all, asking the emulator itself (`emulator -accel-check`).
///
/// Throws a [StateError] saying what the emulator said and how to give it the
/// hypervisor on [os].
Future<void> checkAcceleration({
  required String emulator,
  required Map<String, String> environment,
  required String os,
  required EnvironmentProcessRun run,
}) async {
  final result = await run(emulator, const ['-accel-check'], environment);
  final said = '${result.stdout}'.trim();
  final status = _accelStatus(said);
  if (result.exitCode == 0 && status == 0) return;
  final what = [
    _accelMessage(said),
    '${result.stderr}'.trim(),
  ].where((s) => s.isNotEmpty).join(' ');
  throw StateError(
    'the Android emulator cannot use this host\'s hypervisor'
    '${what.isEmpty ? '' : ' ($what)'}: ${_accelerationRemedy(os)}',
  );
}

/// The status `-accel-check` reports between its `accel:` and `accel` lines,
/// or null when it reports none.
int? _accelStatus(String said) {
  final lines = const LineSplitter().convert(said);
  final start = lines.indexOf('accel:');
  if (start < 0 || start + 1 >= lines.length) return null;
  return int.tryParse(lines[start + 1].trim());
}

String _accelMessage(String said) {
  final lines = const LineSplitter().convert(said);
  final start = lines.indexOf('accel:');
  if (start < 0) return said;
  return lines
      .skip(start + 2)
      .takeWhile((line) => line != 'accel')
      .join(' ')
      .trim();
}

String _accelerationRemedy(String os) => switch (os) {
  'linux' =>
    'it needs KVM. Enable virtualization in the firmware (or nested '
        'virtualization for a VM), load the kvm module, and give the user '
        'read and write access to /dev/kvm (membership of the `kvm` group, or '
        '`KERNEL=="kvm", GROUP="kvm", MODE="0666"` in a udev rule). Or run the '
        'test on an attached device: '
        '`--@rules_flutter//flutter/integration_test:android_device=attached`.',
  'macos' =>
    'it needs Hypervisor.framework, which `sysctl kern.hv_support` reports as '
        '1 on a Mac that has it; a macOS virtual machine has it only with '
        'nested virtualization. Or run the test on an attached device: '
        '`--@rules_flutter//flutter/integration_test:android_device=attached`.',
  _ =>
    'the emulator runs here on macOS and on Linux only. Run the test on an '
        'attached device: '
        '`--@rules_flutter//flutter/integration_test:android_device=attached`.',
};

/// What the emulator prints when the device has booted: the system has set
/// `sys.boot_completed`, which the emulator waits on itself.
final _bootCompleted = RegExp(r'Boot completed in \d+ ms');

/// How many of the emulator's last lines a failure shows.
const _tail = 40;

/// A booted emulator of the test's own.
class TestEmulator {
  TestEmulator._(
    this.ports,
    this._process,
    this._stopServer,
    this._exit,
    this._readLog,
  );

  /// The ports it holds, which name it.
  final EmulatorPorts ports;

  final Process _process;
  final Future<void> Function() _stopServer;
  final Future<int> _exit;
  final Future<ProcessResult> Function() _readLog;

  /// Starts the test's `adb` server and boots an emulator at [ports], laid out
  /// in [scratch], and completes once the device has booted.
  ///
  /// The emulator runs in [environment] (see [emulatorEnvironment]), `adb` in
  /// [adbEnv] (see [adbEnvironment]). Its output is written to [output], and
  /// the last of it is in the failure when it exits before it has booted. Throws a
  /// [StateError] saying what went wrong, having stopped what it started.
  static Future<TestEmulator> boot({
    required EmulatorSettings settings,
    required EmulatorPorts ports,
    required EmulatorScratch scratch,
    required String adb,
    required Map<String, String> environment,
    required Map<String, String> adbEnv,
    required EnvironmentProcessRun run,
    required IsolatedProcessStarter start,
    required ProcessRunSync ps,
    void Function(String message)? log,
    IOSink? output,
  }) async {
    final server = await run(adb, [
      '-P',
      '${ports.server}',
      'start-server',
    ], adbEnv);
    if (server.exitCode != 0) {
      throw StateError(
        'the test\'s adb server on port ${ports.server} did not start: '
        '`adb start-server` exited ${server.exitCode}: '
        '${'${server.stderr}'.trim()}',
      );
    }
    Future<void> stopServer() async {
      final stopped = await run(adb, [
        '-P',
        '${ports.server}',
        'kill-server',
      ], adbEnv);
      if (stopped.exitCode != 0) {
        throw StateError(
          'the test\'s adb server on port ${ports.server} did not stop: '
          '`adb kill-server` exited ${stopped.exitCode}: '
          '${'${stopped.stderr}'.trim()}',
        );
      }
    }

    final Process process;
    try {
      process = await start(
        settings.executable,
        emulatorArguments(ports),
        environment,
      );
    } on Object {
      await stopServer();
      rethrow;
    }
    // The emulator reads nothing from its input.
    unawaited(process.stdin.close());
    final started = await processStartTime(process.pid, ps);
    if (started != null) ports.record(process.pid, started);

    final lines = <String>[];
    final booted = Completer<void>();
    void listen(Stream<List<int>> stream) => stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          output?.writeln(line);
          lines.add(line);
          if (lines.length > _tail) lines.removeAt(0);
          if (!booted.isCompleted && _bootCompleted.hasMatch(line)) {
            booted.complete();
          }
        });
    listen(process.stdout);
    listen(process.stderr);
    final exit = process.exitCode;
    final emulator = TestEmulator._(
      ports,
      process,
      stopServer,
      exit,
      () => run(adb, [
        '-P',
        '${ports.server}',
        '-s',
        ports.serial,
        'logcat',
        '-d',
      ], adbEnv),
    );

    final clock = Stopwatch()..start();
    final ended = await Future.any([
      booted.future.then((_) => null),
      exit.then<int?>((code) => code),
    ]);
    if (ended != null) {
      await stopServer();
      throw StateError(
        'the Android emulator exited $ended before the device booted. Its '
        'last words:\n${lines.join('\n')}',
      );
    }
    try {
      await _confirmBooted(adb, ports, adbEnv, run);
    } on StateError {
      await emulator.stop();
      rethrow;
    }
    log?.call(
      'booted the emulator ${ports.serial} '
      '(${settings.tag} ${settings.abi}, API ${settings.apiLevel}) in '
      '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
    );
    return emulator;
  }

  /// Shuts the emulator down and stops the test's `adb` server, having
  /// written the device's whole log to [logcat] when it is given: the device
  /// is gone afterwards, and with it what it logged of the app's end.
  ///
  /// Throws a [StateError] when the log cannot be read or the server would
  /// not stop; the emulator is shut down whatever the log does.
  Future<void> stop({String? logcat}) async {
    try {
      if (logcat != null) {
        final log = await _readLog();
        if (log.exitCode != 0) {
          throw StateError(
            '`adb logcat -d` of ${ports.serial} exited ${log.exitCode}: '
            '${'${log.stderr}'.trim()}',
          );
        }
        File(logcat).writeAsStringSync('${log.stdout}');
      }
    } finally {
      await _shutDown();
    }
  }

  Future<void> _shutDown() async {
    _process.kill(ProcessSignal.sigterm);
    await _exit;
    await _stopServer();
  }
}

/// That `adb` has the device, and the device says it has booted.
Future<void> _confirmBooted(
  String adb,
  EmulatorPorts ports,
  Map<String, String> adbEnv,
  EnvironmentProcessRun run,
) async {
  final result = await run(adb, [
    '-P',
    '${ports.server}',
    '-s',
    ports.serial,
    'wait-for-device',
    'shell',
    'getprop',
    'sys.boot_completed',
  ], adbEnv);
  final said = '${result.stdout}'.trim();
  if (result.exitCode != 0 || said != '1') {
    throw StateError(
      'the emulator said the device ${ports.serial} had booted, but `adb` '
      'reads its sys.boot_completed as "$said" (exit ${result.exitCode}: '
      '${'${result.stderr}'.trim()}).',
    );
  }
}
