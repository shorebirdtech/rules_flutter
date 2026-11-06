/// The simulator an iOS integration test runs on is made for that test and
/// gone when it ends, so tests do not share state with each other or with the
/// simulators of the person running them. A host with no iOS runtime fails the
/// test saying how to install one, rather than reporting the tool's own words
/// about a device type.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/integration/test_simulator.dart';
import 'package:test/test.dart';

/// A `simctl` that records what it was asked and answers as [reply] says.
class _Simctl {
  _Simctl(this.reply);

  final ProcessResult Function(List<String> arguments) reply;
  final calls = <List<String>>[];

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    expect(executable, 'xcrun');
    expect(arguments.first, 'simctl');
    calls.add(arguments.skip(1).toList());
    return reply(arguments.skip(1).toList());
  }
}

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');

ProcessResult _fails(int code, String stderr) =>
    ProcessResult(0, code, '', stderr);

void main() {
  group('a simulator for a test', () {
    test('is created under the test\'s own name, of the device type, on the '
        'newest runtime when none is named', () async {
      final simctl = _Simctl((_) => _ok('A1B2-C3D4\n'));

      final simulator = await TestSimulator.create(
        name: 'rules_flutter-pkg_app_test-42',
        deviceType: 'iPhone 16',
        runtime: '',
        run: simctl.call,
      );

      expect(simulator.udid, 'A1B2-C3D4');
      expect(simctl.calls, [
        ['create', 'rules_flutter-pkg_app_test-42', 'iPhone 16'],
      ]);
    });

    test('is created on the runtime that is named', () async {
      final simctl = _Simctl((_) => _ok('A1B2\n'));

      await TestSimulator.create(
        name: 'n',
        deviceType: 'iPhone 16',
        runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2',
        run: simctl.call,
      );

      expect(simctl.calls.single, [
        'create',
        'n',
        'iPhone 16',
        'com.apple.CoreSimulator.SimRuntime.iOS-27-2',
      ]);
    });

    test('is not made on a host with no iOS runtime, and the failure says how '
        'to install one', () async {
      final simctl = _Simctl(
        (_) => _fails(
          145,
          "Could not find an available runtime for device type 'iPhone 16'",
        ),
      );

      await expectLater(
        TestSimulator.create(
          name: 'n',
          deviceType: 'iPhone 16',
          runtime: '',
          run: simctl.call,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('no iOS simulator runtime installed'),
              contains('xcodebuild -downloadPlatform iOS'),
              contains('Could not find an available runtime'),
            ),
          ),
        ),
      );
    });

    test('is not made on a runtime that is not installed, and the failure '
        'names it and what is', () async {
      final simctl = _Simctl(
        (_) => _fails(145, 'Invalid runtime: com.apple.X-99'),
      );

      await expectLater(
        TestSimulator.create(
          name: 'n',
          deviceType: 'iPhone 16',
          runtime: 'com.apple.X-99',
          run: simctl.call,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('no iOS simulator runtime installed'),
              contains('com.apple.X-99'),
              contains('xcrun simctl list runtimes'),
            ),
          ),
        ),
      );
    });

    test('is not made of a device type simctl does not know, and the failure '
        'says where the known ones are listed', () async {
      final simctl = _Simctl(
        (_) => _fails(146, 'Invalid device type: iPhone 99'),
      );

      await expectLater(
        TestSimulator.create(
          name: 'n',
          deviceType: 'iPhone 99',
          runtime: '',
          run: simctl.call,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"iPhone 99"'),
              contains('xcrun simctl list devicetypes'),
            ),
          ),
        ),
      );
    });

    test('is shut down and then deleted when the test is over', () async {
      final simctl = _Simctl(
        (args) => _ok(args.first == 'create' ? 'U1\n' : ''),
      );
      final simulator = await TestSimulator.create(
        name: 'n',
        deviceType: 'iPhone 16',
        runtime: '',
        run: simctl.call,
      );
      simctl.calls.clear();

      await simulator.remove();

      expect(simctl.calls, [
        ['shutdown', 'U1'],
        ['delete', 'U1'],
      ]);
    });

    test('is deleted though it was never booted: a shutdown of a shut-down '
        'device is not a failure', () async {
      final simctl = _Simctl(
        (args) => switch (args.first) {
          'create' => _ok('U1\n'),
          'shutdown' => _fails(
            164,
            'An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\n'
            'Unable to shutdown device in current state: Shutdown',
          ),
          _ => _ok(),
        },
      );
      final simulator = await TestSimulator.create(
        name: 'n',
        deviceType: 'iPhone 16',
        runtime: '',
        run: simctl.call,
      );

      await simulator.remove();

      expect(simctl.calls.last, ['delete', 'U1']);
    });

    test('is deleted though shutting it down failed, and the failure of '
        'either is reported', () async {
      final simctl = _Simctl(
        (args) => switch (args.first) {
          'create' => _ok('U1\n'),
          'shutdown' => _fails(1, 'CoreSimulatorService connection invalid'),
          _ => _ok(),
        },
      );
      final simulator = await TestSimulator.create(
        name: 'n',
        deviceType: 'iPhone 16',
        runtime: '',
        run: simctl.call,
      );

      await expectLater(
        simulator.remove(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('U1'),
              contains('shutdown'),
              contains('CoreSimulatorService connection invalid'),
            ),
          ),
        ),
      );
      expect(simctl.calls.last, ['delete', 'U1'], reason: 'still deleted');
    });

    test('that cannot be deleted is reported, naming it, so it is not left '
        'behind unnoticed', () async {
      final simctl = _Simctl(
        (args) => switch (args.first) {
          'create' => _ok('U1\n'),
          'delete' => _fails(1, 'busy'),
          _ => _ok(),
        },
      );
      final simulator = await TestSimulator.create(
        name: 'rules_flutter-x-1',
        deviceType: 'iPhone 16',
        runtime: '',
        run: simctl.call,
      );

      await expectLater(
        simulator.remove(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('rules_flutter-x-1'),
              contains('U1'),
              contains('busy'),
            ),
          ),
        ),
      );
    });
  });

  group('the name of a test\'s simulator', () {
    test('says it is rules_flutter\'s, which test it is for and which run', () {
      expect(
        testSimulatorName(
          '//e2e:ios_pass_test',
          const SimulatorOwner(4242, 99),
        ),
        'rules_flutter-e2e_ios_pass_test-4242-99',
      );
    });

    test('has nothing in it simctl or a person reading `simctl list` would '
        'trip on', () {
      expect(
        testSimulatorName(r'@@repo+//a b/c:d$e', const SimulatorOwner(7, 8)),
        matches(RegExp(r'^rules_flutter-[A-Za-z0-9_.-]+-7-8$')),
      );
    });

    test('gives back the owner it records, whatever the test\'s own name ends '
        'in', () {
      const owner = SimulatorOwner(4242, 1793960755);
      expect(
        simulatorOwnerOf(testSimulatorName('//a:t-12-34', owner)),
        owner,
      );
    });

    test('of a person\'s simulator, or of one made before names recorded '
        'their owner, records no owner', () {
      expect(simulatorOwnerOf('iPhone 16'), isNull);
      expect(simulatorOwnerOf('rules_flutter-e2e_ios_pass_test-4242'), isNull);
    });
  });

  group('reclaiming the simulators of runs that are gone', () {
    // Process 100 started at 1000; 200 is gone; 300 now runs, started at 5000.
    final started = {100: '1000', 200: '', 300: '5000'};

    /// A host with [devices] (name to udid) and the processes of [started].
    /// `ps` answers in the local-time format real `ps` does.
    Future<ProcessResult> Function(String, List<String>) host(
      Map<String, String> devices,
      List<List<String>> calls, {
      Set<String> undeletable = const {},
    }) {
      final present = {...devices};
      return (executable, arguments) async {
        if (executable == 'ps') {
          final epoch = started[int.parse(arguments.last)];
          if (epoch == null || epoch.isEmpty)
            return ProcessResult(0, 1, '', '');
          final t = DateTime.fromMillisecondsSinceEpoch(
            int.parse(epoch) * 1000,
          );
          const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
          const months = [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
          ];
          String two(int n) => n.toString().padLeft(2, '0');
          return ProcessResult(
            0,
            0,
            '${days[t.weekday - 1]} ${months[t.month - 1]} '
                '${t.day.toString().padLeft(2)} '
                '${two(t.hour)}:${two(t.minute)}:${two(t.second)} ${t.year}\n',
            '',
          );
        }
        final simctl = arguments.skip(1).toList();
        calls.add(simctl);
        if (simctl.first == 'list') {
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'devices': {
                'iOS-27-2': [
                  for (final e in present.entries)
                    {'name': e.key, 'udid': e.value, 'state': 'Shutdown'},
                ],
              },
            }),
            '',
          );
        }
        if (simctl.first == 'delete') {
          if (undeletable.contains(simctl.last)) {
            return ProcessResult(0, 1, '', 'busy');
          }
          present.removeWhere((_, udid) => udid == simctl.last);
        }
        return ProcessResult(0, 0, '', '');
      };
    }

    test('deletes the simulator of a run whose process is gone, shutting it '
        'down first, and says so', () async {
      final calls = <List<String>>[];
      final logged = <String>[];

      await reclaimOrphanedSimulators(
        run: host({'rules_flutter-t-200-1000': 'U-GONE'}, calls),
        log: logged.add,
      );

      expect(calls.where((c) => c.first != 'list'), [
        ['shutdown', 'U-GONE'],
        ['delete', 'U-GONE'],
      ]);
      expect(
        logged.single,
        allOf(contains('rules_flutter-t-200-1000'), contains('U-GONE')),
      );
    });

    test('keeps the simulator of a run that is still there, so that tests '
        'running at once do not delete each other\'s', () async {
      final calls = <List<String>>[];
      final logged = <String>[];

      await reclaimOrphanedSimulators(
        run: host({'rules_flutter-t-100-1000': 'U-LIVE'}, calls),
        log: logged.add,
      );

      expect(calls.where((c) => c.first != 'list'), isEmpty);
      expect(logged, isEmpty);
    });

    test('deletes the simulator of a run whose process id another process '
        'has since taken', () async {
      final calls = <List<String>>[];

      await reclaimOrphanedSimulators(
        run: host({'rules_flutter-t-300-1000': 'U-REUSED'}, calls),
        log: (_) {},
      );

      expect(calls.last, ['delete', 'U-REUSED']);
    });

    test('leaves alone every simulator that is not a test run\'s, or does '
        'not record its owner', () async {
      final calls = <List<String>>[];

      await reclaimOrphanedSimulators(
        run: host({
          'iPhone 16': 'U1',
          'my-sim-200-1000': 'U2',
          'rules_flutter-old-200': 'U3',
        }, calls),
        log: (_) {},
      );

      expect(calls.where((c) => c.first != 'list'), isEmpty);
    });

    test(
      'is not undone by another run having deleted the simulator first',
      () async {
        var listed = 0;
        final calls = <List<String>>[];
        final inner = host({'rules_flutter-t-200-1000': 'U-GONE'}, calls);
        await reclaimOrphanedSimulators(
          run: (executable, arguments) async {
            if (arguments.length > 1 && arguments[1] == 'delete') {
              return ProcessResult(0, 1, '', 'Invalid device');
            }
            // The second listing, after the failed delete, shows it gone.
            if (arguments.length > 1 &&
                arguments[1] == 'list' &&
                ++listed > 1) {
              return ProcessResult(0, 0, jsonEncode({'devices': {}}), '');
            }
            return inner(executable, arguments);
          },
          log: (_) {},
        );
      },
    );

    test('that cannot be deleted is reported', () async {
      await expectLater(
        reclaimOrphanedSimulators(
          run: host(
            {'rules_flutter-t-200-1000': 'U-GONE'},
            [],
            undeletable: {'U-GONE'},
          ),
          log: (_) {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('U-GONE'), contains('busy')),
          ),
        ),
      );
    });

    test(
      'the owner of a running process is its id and `ps`\'s start time',
      () async {
        final owner = await simulatorOwnerOfProcess(
          100,
          host({}, []),
        );
        expect(owner, const SimulatorOwner(100, 1000));
      },
    );
  });
}
