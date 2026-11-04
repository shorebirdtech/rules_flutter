@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// An app that dies under a connected `run` ends the run, failed, with the
/// platform's account of why.
///
/// Before this the run kept asking a VM service that was gone and printing
/// "still waiting" until it was killed. The app here is killed from outside,
/// after the tool reports it connected and drivable, so the death arrives as
/// the connection closing and the process going.
void main() {
  /// The run ended on its own, failed, and said the app died.
  Future<void> expectRunFailedWithAppDeath(
    DevToolProcess dt, {
    required String appId,
    required Pattern platformWords,
  }) async {
    final code = await dt.exitCodeWithin(
      const Duration(seconds: 90),
      stillRunning:
          'the app the run was connected to died, and the run did not end. '
          'Nothing on the connected path observed the app going away',
    );
    expect(code, isNot(0), reason: 'a dead app is a failed run');

    final stop = await dt.waitForEventWhere(
      'app.stop',
      test: (params) => params['appId'] == appId,
      what: 'an app.stop for the dead app',
      timeout: const Duration(seconds: 5),
    );
    final error = (stop['params'] as Map)['error'];
    expect(
      error,
      isA<String>().having((e) => e, 'error', contains(platformWords)),
      reason: 'app.stop must carry why the app stopped',
    );
  }

  group('macOS', () {
    test(
      'an app killed after the run connected ends the run, failed',
      () async {
        final dt = await startDevTool(
          workspace: e2eWorkspace('macos_example'),
          target: ':app',
          device: 'macos',
        );
        await dt.waitForEvent('app.started');
        await dt.waitForHttpControl();

        // The app is the tool's own child: the tool starts the executable
        // itself, so its process is the one the death is read from.
        final children = await Process.run('pgrep', [
          '-P',
          '${dt.process.pid}',
        ]);
        final pids = '${children.stdout}'
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .map(int.parse)
            .toList();
        expect(pids, isNotEmpty, reason: 'the run has no child process');
        for (final pid in pids) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }

        await expectRunFailedWithAppDeath(
          dt,
          appId: dt.appId!,
          platformWords: 'killed by signal 9',
        );
      },
      skip: !Platform.isMacOS ? 'macOS only' : null,
    );
  });

  group('iOS Simulator', () {
    test(
      'an app that exits after the run connected ends the run, failed',
      () async {
        final dt = await startDevTool(
          workspace: e2eWorkspace('ios_example'),
          target: ':app',
          device: 'ios-simulator',
        );
        await dt.waitForEvent('app.started');
        await dt.waitForHttpControl();

        // Every booted simulator is asked: which one the run chose is the
        // tool's business, and the app is on exactly one of them.
        final listed = await Process.run('xcrun', [
          'simctl',
          'list',
          'devices',
          'booted',
          '-j',
        ]);
        final udids = [
          for (final runtime
              in (jsonDecode('${listed.stdout}')['devices'] as Map).values)
            for (final d in runtime as List) (d as Map)['udid'] as String,
        ];
        var terminated = 0;
        for (final udid in udids) {
          final result = await Process.run('xcrun', [
            'simctl',
            'terminate',
            udid,
            'com.rulesflutter.ios.example',
          ]);
          if (result.exitCode == 0) terminated++;
        }
        expect(terminated, 1, reason: 'the app runs on exactly one simulator');

        await expectRunFailedWithAppDeath(
          dt,
          appId: dt.appId!,
          platformWords: 'exited after announcing its VM service',
        );
      },
      skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
    );
  });
}
