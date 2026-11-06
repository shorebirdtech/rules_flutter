/// The iOS simulator an integration test runs on.
///
/// One is made for each test run and deleted when it ends, as rules_apple's
/// test runner does: a test then shares no state with another or with the
/// simulators of the person running it (a first-launch dialog, an installed
/// copy of the app, a booted device someone is using), and needs no lock.
library;

import 'dart:convert';

import '../device.dart';

/// A simulator created for one test run.
class TestSimulator {
  TestSimulator._(this.udid, this.name, this._run);

  /// The simulator's identifier, which every `simctl` command addresses it by.
  final String udid;

  /// The name it was created under: what `simctl list` shows it as.
  final String name;

  final ProcessRunSync _run;

  /// Creates a simulator called [name] of [deviceType] (a name `simctl list
  /// devicetypes` lists, such as `iPhone 16`) on [runtime].
  ///
  /// An empty [runtime] is the newest one installed that suits the device type,
  /// which is `simctl`'s own choice. Booting it is the launch's, which waits on
  /// the boot's completion rather than a clock.
  ///
  /// Throws a [StateError] saying what to install or change when `simctl`
  /// refuses: no runtime to run on, a runtime or a device type it does not
  /// know.
  static Future<TestSimulator> create({
    required String name,
    required String deviceType,
    required String runtime,
    required ProcessRunSync run,
  }) async {
    final result = await run('xcrun', [
      'simctl',
      'create',
      name,
      deviceType,
      if (runtime.isNotEmpty) runtime,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        _creationFailure(
          '${result.stderr}'.trim(),
          result.exitCode,
          deviceType: deviceType,
          runtime: runtime,
        ),
      );
    }
    return TestSimulator._('${result.stdout}'.trim(), name, run);
  }

  /// Shuts the simulator down and deletes it.
  ///
  /// Both are tried whatever the first says, so a simulator that would not shut
  /// down is still deleted. A simulator that is already shut down is not a
  /// failure of the shutdown. Throws a [StateError] naming the simulator and
  /// what `simctl` said when either failed: a simulator left behind is
  /// reported, not unnoticed.
  Future<void> remove() async {
    final problems = <String>[];
    final shutdown = await _run('xcrun', ['simctl', 'shutdown', udid]);
    if (shutdown.exitCode != 0 &&
        !'${shutdown.stderr}'.contains('current state: Shutdown')) {
      problems.add(
        '`simctl shutdown` exited ${shutdown.exitCode}: '
        '${'${shutdown.stderr}'.trim()}',
      );
    }
    final delete = await _run('xcrun', ['simctl', 'delete', udid]);
    if (delete.exitCode != 0) {
      problems.add(
        '`simctl delete` exited ${delete.exitCode}: '
        '${'${delete.stderr}'.trim()}',
      );
    }
    if (problems.isNotEmpty) {
      throw StateError(
        'the simulator $name ($udid) was not removed cleanly: '
        '${problems.join('; ')}. `xcrun simctl delete $udid` removes it.',
      );
    }
  }
}

String _creationFailure(
  String said,
  int exitCode, {
  required String deviceType,
  required String runtime,
}) {
  if (said.contains('Invalid device type')) {
    return 'the simulator\'s device type "$deviceType" is not one simctl '
        'knows: `xcrun simctl list devicetypes` lists them ($said).';
  }
  if (said.toLowerCase().contains('runtime')) {
    return 'no iOS simulator runtime installed'
        '${runtime.isEmpty ? '' : ' that is "$runtime" (`xcrun simctl list runtimes` lists the installed ones)'}: '
        '`xcodebuild -downloadPlatform iOS` installs one ($said).';
  }
  return '`simctl create` for the device type "$deviceType" exited '
      '$exitCode: $said';
}

/// The run that owns a simulator: a process, told from a later process that
/// reuses its id by when it started.
class SimulatorOwner {
  const SimulatorOwner(this.pid, this.startedAt);

  final int pid;

  /// When the process started, in whole seconds since the epoch: what `ps`
  /// reports, and so what the owner and anyone checking it agree on.
  final int startedAt;

  @override
  bool operator ==(Object other) =>
      other is SimulatorOwner &&
      other.pid == pid &&
      other.startedAt == startedAt;

  @override
  int get hashCode => Object.hash(pid, startedAt);

  @override
  String toString() => '$pid started at $startedAt';
}

/// The name of the simulator made for the test [label], for the run [owner]:
/// rules_flutter's, so that it is recognised in `simctl list`, with the test in
/// it so that two tests' simulators are told apart, and the owner in it so that
/// a later run can tell whether the run that made it is still there. The owner
/// is in the name, not beside it, so that the same `simctl create` that makes
/// the simulator records it: a run killed at any moment leaves either no
/// simulator or one that names its owner.
String testSimulatorName(String label, SimulatorOwner owner) {
  final test = label
      .replaceAll(RegExp(r'^@*[^/]*//'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
  return 'rules_flutter-$test-${owner.pid}-${owner.startedAt}';
}

final _ownedName = RegExp(r'^rules_flutter-.+-(\d+)-(\d+)$');

/// The owner [name] records, or null for a name that is not a test simulator's
/// (a person's own, or one made before names recorded their owner), which is
/// then left alone.
SimulatorOwner? simulatorOwnerOf(String name) {
  final match = _ownedName.firstMatch(name);
  if (match == null) return null;
  return SimulatorOwner(int.parse(match[1]!), int.parse(match[2]!));
}

/// The start time `ps` reports for process [pid], or null when there is no
/// such process. Throws a [StateError] when `ps` fails otherwise or says
/// something that is not a time.
Future<int?> processStartTime(int pid, ProcessRunSync run) async {
  final result = await run('ps', ['-o', 'lstart=', '-p', '$pid']);
  final said = '${result.stdout}'.trim();
  if (result.exitCode == 1 && said.isEmpty) return null;
  if (result.exitCode != 0) {
    throw StateError(
      '`ps -o lstart= -p $pid` exited ${result.exitCode}: '
      '${'${result.stderr}'.trim()}',
    );
  }
  return _parseLstart(said);
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `Fri Nov  6 10:25:55 2026`, in the local time zone, as whole epoch seconds.
int _parseLstart(String said) {
  final parts = said.split(RegExp(r'\s+'));
  final month = parts.length == 5 ? _months.indexOf(parts[1]) : -1;
  final clock = parts.length == 5 ? parts[3].split(':') : const <String>[];
  if (month < 0 || clock.length != 3) {
    throw StateError('`ps` gave a start time that is not one: "$said".');
  }
  return DateTime(
        int.parse(parts[4]),
        month + 1,
        int.parse(parts[2]),
        int.parse(clock[0]),
        int.parse(clock[1]),
        int.parse(clock[2]),
      ).millisecondsSinceEpoch ~/
      1000;
}

/// The owner of the run of process [pid], which is running.
Future<SimulatorOwner> simulatorOwnerOfProcess(
  int pid,
  ProcessRunSync run,
) async {
  final started = await processStartTime(pid, run);
  if (started == null) {
    throw StateError('the running process $pid has no start time to `ps`.');
  }
  return SimulatorOwner(pid, started);
}

/// Deletes the test simulators whose runs are gone: ones a SIGKILL (Bazel's
/// timeout escalation, a killed Bazel server) kept the run from deleting.
///
/// A simulator is reclaimed only when its owner's process id is not running,
/// or is running with another start time (the id was reused). A run that is
/// alive, such as another test of the same Bazel invocation, keeps its
/// simulator. Simulators whose names do not record an owner are never touched.
/// Each reclaim is logged through [log]. Throws a [StateError] when a
/// reclaimed simulator could not be deleted.
Future<void> reclaimOrphanedSimulators({
  required ProcessRunSync run,
  required void Function(String message) log,
}) async {
  for (final device in await _listDevices(run)) {
    final owner = simulatorOwnerOf(device.name);
    if (owner == null) continue;
    if (await processStartTime(owner.pid, run) == owner.startedAt) continue;
    log(
      'deleting the simulator ${device.name} (${device.udid}): its run '
      '(process ${owner.pid}) is gone',
    );
    try {
      await TestSimulator._(device.udid, device.name, run).remove();
    } on StateError {
      // Another run reclaiming the same simulator may have got there first.
      final left = await _listDevices(run);
      if (left.any((d) => d.udid == device.udid)) rethrow;
    }
  }
}

Future<List<({String name, String udid})>> _listDevices(
  ProcessRunSync run,
) async {
  final listed = await run('xcrun', ['simctl', 'list', 'devices', '-j']);
  if (listed.exitCode != 0) {
    throw StateError(
      '`simctl list devices` exited ${listed.exitCode}: '
      '${'${listed.stderr}'.trim()}',
    );
  }
  final byRuntime =
      (jsonDecode('${listed.stdout}') as Map<String, Object?>)['devices']
          as Map<String, Object?>;
  return [
    for (final runtime in byRuntime.values)
      for (final device in (runtime as List).cast<Map<String, Object?>>())
        (name: device['name'] as String, udid: device['udid'] as String),
  ];
}

/// The simulator device of a test: the one [TestSimulator] made, which exists
/// only once the run has taken what it needs of the host.
///
/// Every `simctl` command of the device addresses [udid], so the device is
/// built before the simulator is, and addresses it once [simulator] is set.
class TestSimulatorDevice extends IOSSimulatorDevice {
  /// A device with no simulator yet.
  TestSimulatorDevice() : super(udid: 'unassigned');

  TestSimulator? _simulator;

  /// The simulator the app is launched on. Set once, by the preparation.
  set simulator(TestSimulator simulator) => _simulator = simulator;

  @override
  String get udid =>
      _simulator?.udid ??
      (throw StateError(
        'the test\'s simulator has not been created: the host preparation '
        'creates it before anything is launched.',
      ));
}
