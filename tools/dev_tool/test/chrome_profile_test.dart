/// `ChromeProfile` and `ChromeProfiles`: a run's throwaway browser profile,
/// and the next run's clearing away of one whose run was killed.
///
/// What cannot be shown here is another process holding the lock: POSIX locks
/// belong to the process, so a second handle opened by this test process would
/// take a lock this process already holds. The cross-process half — a lock
/// held by a live process refuses a second process, and is dropped when the
/// holder is killed with SIGKILL — was measured by hand with two `dart`
/// processes, and what this file covers is every decision the reaper makes
/// around it.
library;

import 'dart:io';

import 'package:flutter_bazel_dev_tool/chrome_profile.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Set<int> running;
  late ChromeProfiles profiles;
  late List<LogRecord> records;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chrome_profile_test_');
    running = {};
    profiles = ChromeProfiles(
      parent: root,
      isRunning: (pid) async => running.contains(pid),
    );
    records = [];
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await sub.cancel();
      await root.delete(recursive: true);
    });
  });

  /// What a run killed with no chance to clean up leaves: a profile directory
  /// holding its owner file, unlocked because nothing holds the lock now.
  Directory leftBehind(String name, {String? lockTarget}) {
    final dir = Directory(p.join(root.path, name))..createSync();
    File(p.join(dir.path, ChromeProfile.ownerFileName)).writeAsStringSync('');
    File(p.join(dir.path, 'Local State')).writeAsStringSync('{}');
    if (lockTarget != null) {
      Link(p.join(dir.path, 'SingletonLock')).createSync(lockTarget);
    }
    return dir;
  }

  group('ChromeProfile', () {
    test('creates a fresh directory with the owner file inside', () async {
      final profile = await profiles.create();
      addTearDown(profile.release);

      expect(p.dirname(profile.directory.path), root.path);
      expect(p.basename(profile.directory.path), startsWith('flutter_chrome_'));
      expect(
        File(
          p.join(profile.directory.path, ChromeProfile.ownerFileName),
        ).existsSync(),
        isTrue,
      );
    });

    test(
      'release deletes the profile and Chrome\'s socket directory',
      () async {
        final profile = await profiles.create();
        // What Chrome makes beside the profile: a directory of its own in the
        // temp folder, linked from the profile.
        final socketDir = Directory(
          p.join(root.path, 'com.google.Chrome.AbCdEf'),
        )..createSync();
        File(p.join(socketDir.path, 'SingletonSocket')).writeAsStringSync('');
        File(p.join(socketDir.path, 'SingletonCookie')).writeAsStringSync('');
        Link(
          p.join(profile.directory.path, 'SingletonSocket'),
        ).createSync(p.join(socketDir.path, 'SingletonSocket'));

        await profile.release();

        expect(profile.directory.existsSync(), isFalse);
        expect(socketDir.existsSync(), isFalse);
      },
    );

    test('release leaves a directory that is not Chrome\'s socket directory '
        'alone', () async {
      final profile = await profiles.create();
      final elsewhere = Directory(p.join(root.path, 'sub', 'dir'))
        ..createSync(recursive: true);
      File(p.join(elsewhere.path, 'SingletonSocket')).writeAsStringSync('');
      final holdsOtherThings = Directory(p.join(root.path, 'precious'))
        ..createSync();
      File(p.join(holdsOtherThings.path, 'SingletonSocket'))
          .writeAsStringSync('');
      File(p.join(holdsOtherThings.path, 'notes.txt'))
          .writeAsStringSync('keep');

      Link(
        p.join(profile.directory.path, 'SingletonSocket'),
      ).createSync(p.join(elsewhere.path, 'SingletonSocket'));
      await profile.release();
      expect(
        elsewhere.existsSync(),
        isTrue,
        reason: 'not a child of the temp folder',
      );

      final second = await profiles.create();
      Link(
        p.join(second.directory.path, 'SingletonSocket'),
      ).createSync(p.join(holdsOtherThings.path, 'SingletonSocket'));
      await second.release();
      expect(
        holdsOtherThings.existsSync(),
        isTrue,
        reason: 'it holds something Chrome does not put there',
      );
    });
  });

  group('ChromeProfiles.reapAbandoned', () {
    test('removes a profile whose run and browser are gone', () async {
      final dir = leftBehind(
        'flutter_chrome_dead',
        lockTarget: 'host.local-4242',
      );
      final socketDir = Directory(p.join(root.path, 'com.google.Chrome.Zz9'))
        ..createSync();
      File(p.join(socketDir.path, 'SingletonSocket')).writeAsStringSync('');
      Link(
        p.join(dir.path, 'SingletonSocket'),
      ).createSync(p.join(socketDir.path, 'SingletonSocket'));

      final reaped = await profiles.reapAbandoned();

      expect(reaped.map((d) => d.path), [dir.path]);
      expect(dir.existsSync(), isFalse);
      expect(socketDir.existsSync(), isFalse);
      expect(
        records.where((r) => r.level == Level.INFO).map((r) => r.message),
        isNotEmpty,
        reason: 'what was removed is said',
      );
    });

    test(
      'removes a profile that never got as far as starting a browser',
      () async {
        final dir = leftBehind('flutter_chrome_nobrowser');

        await profiles.reapAbandoned();

        expect(dir.existsSync(), isFalse);
      },
    );

    test(
      'keeps a profile whose browser is still running, and says so',
      () async {
        final dir = leftBehind(
          'flutter_chrome_orphan',
          lockTarget: 'host.local-777',
        );
        running.add(777);

        final reaped = await profiles.reapAbandoned();

        expect(reaped, isEmpty);
        expect(dir.existsSync(), isTrue);
        final warning = records.singleWhere((r) => r.level == Level.WARNING);
        expect(
          (warning.object as Map)['text'],
          allOf(contains('777'), contains(dir.path)),
        );
      },
    );

    test('keeps a profile that has no owner file', () async {
      // Not provably ours: another program's, or a run's in the instant
      // between making the directory and locking it.
      final dir = Directory(p.join(root.path, 'flutter_chrome_unmarked'))
        ..createSync();
      File(p.join(dir.path, 'Local State')).writeAsStringSync('{}');

      await profiles.reapAbandoned();

      expect(dir.existsSync(), isTrue);
    });

    test('keeps what this process holds', () async {
      // A second handle in the holding process would take the lock, so the
      // process's own live profiles are recognised by the registry instead.
      final live = await profiles.create();
      addTearDown(live.release);

      final reaped = await profiles.reapAbandoned();

      expect(reaped, isEmpty);
      expect(live.directory.existsSync(), isTrue);
    });

    test('only looks at flutter_chrome_ directories', () async {
      final other = leftBehind('somebody_elses_profile');
      final file = File(p.join(root.path, 'flutter_chrome_file'))
        ..writeAsStringSync('');

      await profiles.reapAbandoned();

      expect(other.existsSync(), isTrue);
      expect(file.existsSync(), isTrue);
    });

    test('a released profile is reaped nowhere: it is already gone', () async {
      final profile = await profiles.create();
      await profile.release();

      expect(await profiles.reapAbandoned(), isEmpty);
    });
  }, skip: Platform.isWindows ? 'the reaper does not run on Windows' : null);

  group('ChromeProfile.releaseAllNow', () {
    test('ends the browser and clears the profile', () async {
      final browser = await Process.start('sleep', ['60']);
      addTearDown(() => browser.kill(ProcessSignal.sigkill));
      final profile = await profiles.create();
      profile.browserStarted(browser.pid);

      ChromeProfile.releaseAllNow();

      expect(await browser.exitCode, isNot(0));
      expect(profile.directory.existsSync(), isFalse);
    });
  }, skip: Platform.isWindows ? 'needs POSIX sleep' : null);
}
