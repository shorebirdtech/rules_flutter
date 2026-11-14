/// Which attached Android device an integration test runs on: the one
/// `ANDROID_SERIAL` names, else the only one attached. A host with none, or
/// with several and no choice made, fails the test naming `adb devices` and the
/// variable that picks one, rather than installing the app on whichever device
/// `adb` happened to answer for.
library;

import 'dart:io';

import 'package:flutter_bazel_dev_tool/integration/android_serial.dart';
import 'package:test/test.dart';

/// An `adb` that answers `devices` with [stdout], and records how it was run.
class _Adb {
  _Adb(this.stdout, {this.exitCode = 0, this.stderr = ''});

  final String stdout;
  final int exitCode;
  final String stderr;
  final calls = <List<String>>[];

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    return ProcessResult(0, exitCode, stdout, stderr);
  }
}

String _listing(Map<String, String> devices) =>
    'List of devices attached\n'
    '${devices.entries.map((e) => '${e.key}\t${e.value}\n').join()}\n';

void main() {
  test('the only attached device is the one the test runs on', () async {
    final adb = _Adb(_listing({'58051JEBF01271': 'device'}));

    final serial = await chooseAndroidSerial(
      adb: '/sdk/platform-tools/adb',
      requested: null,
      run: adb.call,
    );

    expect(serial, '58051JEBF01271');
    expect(adb.calls, [
      ['/sdk/platform-tools/adb', 'devices'],
    ]);
  });

  test('a daemon starting is not a device', () async {
    final adb = _Adb(
      '* daemon not running; starting now at tcp:5037\n'
      '* daemon started successfully\n'
      '${_listing({'emulator-5554': 'device'})}',
    );

    expect(
      await chooseAndroidSerial(adb: 'adb', requested: null, run: adb.call),
      'emulator-5554',
    );
  });

  test('a serial that is asked for is used when it is attached, whatever else '
      'is', () async {
    final adb = _Adb(
      _listing({'58051JEBF01271': 'device', 'emulator-5554': 'device'}),
    );

    expect(
      await chooseAndroidSerial(
        adb: 'adb',
        requested: 'emulator-5554',
        run: adb.call,
      ),
      'emulator-5554',
    );
  });

  test('a device that is attached but not usable is not one to run on, and '
      'the failure says what state it is in', () async {
    final adb = _Adb(_listing({'58051JEBF01271': 'unauthorized'}));

    await expectLater(
      chooseAndroidSerial(adb: 'adb', requested: null, run: adb.call),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('no Android device is ready'),
            contains('58051JEBF01271 (unauthorized)'),
            contains('`adb devices`'),
          ),
        ),
      ),
    );
  });

  test('no device attached fails, naming `adb devices`', () async {
    final adb = _Adb(_listing({}));

    await expectLater(
      chooseAndroidSerial(adb: 'adb', requested: null, run: adb.call),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('no Android device is attached'),
            contains('`adb devices`'),
            contains('boot an emulator'),
          ),
        ),
      ),
    );
  });

  test('several devices and no serial fails, naming them, `adb devices` and '
      'the variable that picks one', () async {
    final adb = _Adb(
      _listing({'58051JEBF01271': 'device', 'emulator-5554': 'device'}),
    );

    await expectLater(
      chooseAndroidSerial(adb: 'adb', requested: null, run: adb.call),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('2 Android devices are attached'),
            contains('58051JEBF01271'),
            contains('emulator-5554'),
            contains('`adb devices`'),
            contains('ANDROID_SERIAL'),
          ),
        ),
      ),
    );
  });

  test(
    'a serial that is asked for and not attached fails, saying which are',
    () async {
      final adb = _Adb(_listing({'58051JEBF01271': 'device'}));

      await expectLater(
        chooseAndroidSerial(
          adb: 'adb',
          requested: 'emulator-9999',
          run: adb.call,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('ANDROID_SERIAL is emulator-9999'),
              contains('58051JEBF01271'),
              contains('`adb devices`'),
            ),
          ),
        ),
      );
    },
  );

  test('an empty ANDROID_SERIAL asks for nothing', () async {
    final adb = _Adb(_listing({'58051JEBF01271': 'device'}));

    expect(
      await chooseAndroidSerial(adb: 'adb', requested: '', run: adb.call),
      '58051JEBF01271',
    );
  });

  test('an adb that fails is reported with what it said', () async {
    final adb = _Adb('', exitCode: 1, stderr: 'adb server version mismatch');

    await expectLater(
      chooseAndroidSerial(adb: 'adb', requested: null, run: adb.call),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('`adb devices` exited 1'),
            contains('adb server version mismatch'),
          ),
        ),
      ),
    );
  });
}
