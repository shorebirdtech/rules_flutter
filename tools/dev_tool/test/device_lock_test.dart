/// A device lock is taken without waiting when nothing holds it, and a test
/// that has to wait says so once, so that it is not mistaken for a hung one.
library;

import 'dart:io';

import 'package:flutter_bazel_dev_tool/integration/device_lock.dart';
import 'package:test/test.dart';

/// A lock file that someone else holds until [heldFor] attempts at a blocking
/// lock have been made.
class _Held implements RandomAccessFile {
  final calls = <FileLock>[];
  var unlocked = false;
  var closed = false;

  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async {
    calls.add(mode);
    if (mode == FileLock.exclusive) {
      throw const FileSystemException('held by another process');
    }
    return this;
  }

  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async {
    unlocked = true;
    return this;
  }

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('device_lock_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('is taken at once when nothing holds it, and says nothing', () async {
    final messages = <String>[];

    final lock = await DeviceLock.acquire(
      'macos-gui',
      directory: dir,
      log: messages.add,
    );
    await lock.release();

    expect(messages, isEmpty);
    expect(File('${dir.path}/macos-gui.lock').existsSync(), isTrue);
  });

  test('waits for whoever holds it, saying once which key and why', () async {
    final held = _Held();
    final messages = <String>[];

    final lock = await DeviceLock.acquire(
      'android-emulator-5554',
      directory: dir,
      log: messages.add,
      open: (_) async => held,
    );

    expect(held.calls, [FileLock.exclusive, FileLock.blockingExclusive]);
    expect(messages, [
      'waiting for android-emulator-5554, held by another test',
    ]);

    await lock.release();
    expect(held.unlocked, isTrue);
    expect(held.closed, isTrue);
  });

  test('keeps a lock a second holder in the same process cannot tell '
      'apart: each key is its own file', () async {
    final a = await DeviceLock.acquire('a', directory: dir);
    final b = await DeviceLock.acquire('b', directory: dir);

    expect(
      dir.listSync().map((e) => e.uri.pathSegments.last).toSet(),
      {'a.lock', 'b.lock'},
    );
    await a.release();
    await b.release();
  });
}
