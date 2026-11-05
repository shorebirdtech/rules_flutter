/// A lock on something two integration tests cannot share, held for a whole run.
///
/// The operating system releases a file lock when the process holding it ends,
/// however it ends, so a test that was killed does not leave the device
/// locked and nothing waits on a timeout to find out: a test waits exactly as
/// long as the one ahead of it runs. The keys:
///
///  * `macos-gui`: a window that is covered stops producing frames, so two
///    tests' windows at once hang one of them;
///  * `android-<serial>`: two tests would install over each other;
///  * `ios-sim-<udid>`: when a runner reuses a simulator.
library;

import 'dart:io';

/// A held lock. Released by [release], or by the process ending.
class DeviceLock {
  DeviceLock._(this._file);

  final RandomAccessFile _file;

  /// Where the lock files are: one directory for every test on the machine,
  /// whatever `TEST_TMPDIR` each was given, since the point is that tests in
  /// different directories meet here.
  static Directory get defaultDirectory => Platform.isWindows
      ? Directory(r'C:\ProgramData\rules_flutter\locks')
      : Directory('/tmp/rules_flutter-locks');

  /// Takes the lock named [key], waiting for whoever holds it.
  ///
  /// Says once, through [log], that it is waiting, so a test that sits there
  /// is not mistaken for a hung one. [directory] is [defaultDirectory] unless a
  /// test of this says otherwise.
  static Future<DeviceLock> acquire(
    String key, {
    Directory? directory,
    void Function(String message)? log,
    LockFile open = _openLockFile,
  }) async {
    final dir = directory ?? defaultDirectory;
    dir.createSync(recursive: true);
    final file = await open('${dir.path}/$key.lock');
    try {
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      log?.call('waiting for $key, held by another test');
      await file.lock(FileLock.blockingExclusive);
    }
    return DeviceLock._(file);
  }

  /// Gives the lock up.
  Future<void> release() async {
    await _file.unlock();
    await _file.close();
  }
}

/// Opens the file a lock is taken on.
typedef LockFile = Future<RandomAccessFile> Function(String path);

Future<RandomAccessFile> _openLockFile(String path) =>
    File(path).open(mode: FileMode.append);
