/// The throwaway Chrome profile directories a run creates, and what happens to
/// one whose run did not get to delete it.
///
/// A run gives every browser a fresh `--user-data-dir` under the system temp
/// directory. Every orderly ending deletes it (see `ChromeSession`), but a
/// run can also end with no chance to: a `SIGKILL`, the machine's out-of-memory
/// killer, a test harness that gives up waiting, a crash. Those leave the
/// directory — tens of megabytes of Chrome's caches — behind for good, so this
/// file makes the next run clear it away.
///
/// ## Proving a directory is abandoned
///
/// Deleting a directory that belongs to a run still going would pull a live
/// browser's profile out from under it, so a directory is only removed on
/// proof, and the proof comes in two halves:
///
///  * **Its run is gone.** Each profile holds an exclusive lock on a file inside
///    it (see [ChromeProfile.ownerFileName]) for as long as its run lives. The
///    operating system drops a process's locks however the process ends, so a
///    lock that can be taken is a run that no longer exists. A pid written to a
///    file would prove less: pids are reused, and a run killed hard cannot
///    update it.
///  * **Its browser is gone.** A run that died by `SIGKILL` did not take its
///    Chrome with it, and a live browser's profile is not abandoned whatever
///    became of the tool that started it. Chrome records its own pid in the
///    profile (`SingletonLock`), and a profile whose recorded pid is still a
///    running process is left alone and reported.
///
/// A directory with no lock file is never touched: it is either not one of
/// ours, or a run's in the instant between creating it and locking it.
///
/// Not done on Windows. Chrome records no pid there, and the other evidence
/// that a browser still has its profile open — the files it holds open cannot
/// be deleted — would have a reaper delete half of a live profile before
/// finding out. A leak there stays a leak until someone clears the temp
/// folder.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'logging.dart';
import 'temp_dir.dart';

final _logger = Logger('dev_tool.chrome_profile');

/// Whether a process with [pid] is running on this machine.
typedef ProcessLiveness = Future<bool> Function(int pid);

/// `ps -p`, which both macOS and Linux have and which exits 0 only for a
/// process that exists.
Future<bool> processIsRunning(int pid) async =>
    (await Process.run('ps', ['-p', '$pid', '-o', 'pid='])).exitCode == 0;

/// One run's Chrome profile directory, held for as long as the run lives.
class ChromeProfile {
  /// The lock file every profile holds, and the proof of ownership
  /// [ChromeProfiles.reapAbandoned] relies on.
  static const ownerFileName = '.dev_tool_owner';

  /// Every profile this process holds, by path.
  ///
  /// POSIX file locks belong to the process, not to the file handle: a second
  /// handle in the same process takes the lock the first one holds without
  /// complaint. A reaper in a process that holds profiles of its own (a run
  /// with two browsers; a test) would find every one of them "abandoned".
  static final Set<String> _held = {};

  /// Profiles whose browsers are running, for [releaseAllNow].
  static final Set<ChromeProfile> _live = {};

  final Directory directory;
  RandomAccessFile? _owner;
  int? _browserPid;

  ChromeProfile._(this.directory, this._owner);

  /// Create a fresh profile under [parent], locked to this process.
  static Future<ChromeProfile> create(Directory parent) async {
    final dir = await parent.createTemp('flutter_chrome_');
    try {
      final owner = await File(
        p.join(dir.path, ownerFileName),
      ).open(mode: FileMode.write);
      try {
        await owner.lock(FileLock.exclusive);
      } catch (_) {
        await owner.close();
        rethrow;
      }
      final profile = ChromeProfile._(dir, owner);
      _held.add(dir.path);
      _live.add(profile);
      return profile;
    } catch (_) {
      await deleteTempDir(dir);
      rethrow;
    }
  }

  /// Record the browser started on this profile, so that [releaseAllNow] can
  /// end it.
  void browserStarted(int pid) => _browserPid = pid;

  /// Let go of the profile: drop the lock and delete the directory.
  ///
  /// Called once the browser has exited. Chrome's own `SingletonSocket`
  /// directory, which lives beside the profile rather than in it, goes too:
  /// Chrome removes it only when it quits by itself, and a browser this tool
  /// ends with `SIGTERM` never does.
  ///
  /// A directory that cannot be deleted (a browser's helper processes can
  /// still be writing for a moment after the browser itself is gone) is
  /// reported by [deleteTempDir] and stays behind with its lock dropped — which
  /// is what makes it the next run's to reap.
  Future<void> release() async {
    final socketDir = _singletonSocketDir(directory);
    await _unlock();
    await deleteTempDir(directory);
    if (socketDir != null) await deleteTempDir(socketDir);
  }

  Future<void> _unlock() async {
    _live.remove(this);
    final owner = _owner;
    _owner = null;
    _held.remove(directory.path);
    await owner?.close();
  }

  /// End every browser this process started and clear away its profile,
  /// without waiting for anything.
  ///
  /// For the moments the process is about to end with no time to be orderly: a
  /// second signal that asks for an immediate exit, an uncaught error. A
  /// browser left running when the tool goes is an orphan holding a profile
  /// nothing can reap, and — see `ChromeSession` — a stale window a later run
  /// can be screenshotted against.
  ///
  /// The deletion is best effort: Chrome's helper processes may still be
  /// exiting and writing, and a directory that is not empty yet is then left
  /// to the next run's [ChromeProfiles.reapAbandoned], which can take it once
  /// the browser is really gone.
  static void releaseAllNow() {
    for (final profile in _live.toList()) {
      if (profile._browserPid case final pid?) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
      _live.remove(profile);
      _held.remove(profile.directory.path);
      try {
        profile._owner?.closeSync();
        profile._owner = null;
        final socketDir = _singletonSocketDir(profile.directory);
        profile.directory.deleteSync(recursive: true);
        socketDir?.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        _logger.warning({
          'message': 'chrome_profile_left_behind',
          'text':
              'Could not remove ${profile.directory.path} while exiting '
              '(${e.osError?.message ?? e.message}). The next run clears it '
              'away once the browser is gone.',
          'path': profile.directory.path,
        });
      }
    }
  }
}

/// Where run-owned Chrome profiles live, and the clearing away of abandoned
/// ones. A seam so that tests can use a directory of their own and a pid table
/// of their own.
class ChromeProfiles {
  final Directory parent;
  final ProcessLiveness _isRunning;

  ChromeProfiles({Directory? parent, ProcessLiveness? isRunning})
    : parent = parent ?? Directory.systemTemp,
      _isRunning = isRunning ?? processIsRunning;

  Future<ChromeProfile> create() => ChromeProfile.create(parent);

  /// Delete every profile under [parent] whose run and browser are both gone.
  /// Returns the ones deleted.
  ///
  /// See the library docs for what is proven first. A profile whose run is
  /// gone but whose browser is not is left and reported: nothing here may
  /// delete a live browser's directory, and ending the browser is not this
  /// function's call.
  Future<List<Directory>> reapAbandoned() async {
    if (Platform.isWindows) return const [];
    final reaped = <Directory>[];
    await for (final entry in parent.list(followLinks: false)) {
      if (entry is! Directory ||
          !p.basename(entry.path).startsWith('flutter_chrome_') ||
          ChromeProfile._held.contains(entry.path)) {
        continue;
      }
      if (await _reap(entry)) reaped.add(entry);
    }
    if (reaped.isNotEmpty) {
      _logger.info({
        'message': 'chrome_profiles_reaped',
        'text':
            'Removed ${reaped.length} Chrome profile(s) left in '
            '${parent.path} by earlier runs that were killed before they could '
            'clean up: ${reaped.map((d) => p.basename(d.path)).join(', ')}.',
        'paths': [for (final d in reaped) d.path],
      });
    }
    return reaped;
  }

  Future<bool> _reap(Directory dir) async {
    final ownerFile = File(p.join(dir.path, ChromeProfile.ownerFileName));
    // Checked first because opening for append creates a file that is not
    // there, and what is not ours must not be marked as if it were.
    if (!await ownerFile.exists()) return false;
    final RandomAccessFile owner;
    try {
      owner = await ownerFile.open(mode: FileMode.append);
    } on FileSystemException {
      // The directory went in the meantime: another run's reaper took it.
      return false;
    }
    try {
      try {
        await owner.lock(FileLock.exclusive);
      } on FileSystemException {
        // Its run is alive.
        return false;
      }
      final browserPid = _recordedBrowserPid(dir);
      if (browserPid != null && await _isRunning(browserPid)) {
        _logger.warning({
          'message': 'chrome_profile_browser_orphaned',
          'text':
              'The Chrome (pid $browserPid) that a killed run started on '
              '${dir.path} is still running, so its profile is kept. Quit '
              'that browser and the next run removes the profile.',
          'pid': browserPid,
          'path': dir.path,
        });
        return false;
      }
      final socketDir = _singletonSocketDir(dir);
      // The lock is held through the deletion, so another run reaping at the
      // same moment cannot be deleting the same directory. One that will not
      // delete stays for the run after.
      await deleteTempDir(dir);
      if (socketDir != null) await deleteTempDir(socketDir);
      return !await dir.exists();
    } finally {
      await owner.close();
    }
  }
}

/// The pid Chrome wrote in [profile]'s `SingletonLock`, a symlink whose target
/// reads `<hostname>-<pid>`. Null when there is none: Chrome never got that
/// far, or quit by itself, which removes it.
int? _recordedBrowserPid(Directory profile) {
  final String target;
  try {
    target = Link(p.join(profile.path, 'SingletonLock')).targetSync();
  } on FileSystemException {
    return null;
  }
  return int.tryParse(target.substring(target.lastIndexOf('-') + 1));
}

/// The directory beside the system temp folder's other entries that holds
/// Chrome's singleton socket for [profile], or null when there is none or it
/// is not one of Chrome's.
///
/// Read off the `SingletonSocket` link in the profile rather than found by
/// name: the name is Chrome's to choose, and what is deleted must be the
/// directory this profile's browser made. Anything that is not a direct child
/// of the temp folder holding nothing but Chrome's two singleton entries is
/// left alone.
Directory? _singletonSocketDir(Directory profile) {
  final String target;
  try {
    target = Link(p.join(profile.path, 'SingletonSocket')).targetSync();
  } on FileSystemException {
    return null;
  }
  if (p.basename(target) != 'SingletonSocket') return null;
  final dir = Directory(p.dirname(target));
  if (!p.equals(p.dirname(dir.path), p.dirname(profile.path))) return null;
  try {
    final names = dir
        .listSync(followLinks: false)
        .map((e) => p.basename(e.path));
    if (names.any(
      (n) => n != 'SingletonSocket' && n != 'SingletonCookie',
    )) {
      return null;
    }
  } on FileSystemException {
    return null;
  }
  return dir;
}
