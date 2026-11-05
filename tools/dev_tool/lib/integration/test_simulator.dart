/// The iOS simulator an integration test runs on.
///
/// One is made for each test run and deleted when it ends, as rules_apple's
/// test runner does: a test then shares no state with another or with the
/// simulators of the person running it (a first-launch dialog, an installed
/// copy of the app, a booted device someone is using), and needs no lock.
library;

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

/// The name of the simulator made for the test [label], for the run of process
/// [pid]: rules_flutter's, so that it is recognised in `simctl list`, with the
/// test and the run in it so that two runs' simulators do not share a name.
String testSimulatorName(String label, int pid) {
  final test = label
      .replaceAll(RegExp(r'^@*[^/]*//'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
  return 'rules_flutter-$test-$pid';
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
