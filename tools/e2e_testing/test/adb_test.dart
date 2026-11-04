import 'dart:io';

import 'package:rules_flutter_e2e_testing/adb.dart';
import 'package:test/test.dart';

/// The adb is a shell script, and Windows has no `sh`.
final _noSh = Platform.isWindows ? 'needs sh' : null;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('adb_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// An `adb` that answers `devices` with [listing] and appends the arguments
  /// of every call to `calls`, one call a line.
  AdbApp appWith(String listing, {Map<String, String> env = const {}}) {
    File('${tmp.path}/listing').writeAsStringSync(listing);
    final adb = File('${tmp.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$*" >> "${tmp.path}/calls"\n'
        'for a in "\$@"; do\n'
        '  if [ "\$a" = devices ]; then cat "${tmp.path}/listing"; fi\n'
        'done\n',
      );
    Process.runSync('chmod', ['+x', adb.path]);
    return AdbApp(
      packageName: 'com.example.app',
      apkPath: '/app.apk',
      adbPath: adb.path,
      environment: env,
    );
  }

  List<String> calls() => File('${tmp.path}/calls').readAsLinesSync();

  const header = 'List of devices attached\n';
  const pixel = 'PIXEL123\tdevice\n';
  const emulator = 'emulator-5554\tdevice\n';

  group('chooseDevice', () {
    test('takes the only attached device', () {
      final app = appWith('$header$pixel');
      expect(app.chooseDevice(), 'PIXEL123');
    }, skip: _noSh);

    test('takes the device ANDROID_SERIAL names among several', () {
      final app = appWith(
        '$header$pixel$emulator',
        env: {'ANDROID_SERIAL': 'emulator-5554'},
      );
      expect(app.chooseDevice(), 'emulator-5554');
    }, skip: _noSh);

    test('refuses several devices with no ANDROID_SERIAL, naming each and '
        'how to choose', () {
      final app = appWith('$header$pixel$emulator');
      expect(
        app.chooseDevice,
        throwsA(
          isA<AdbDeviceChoiceError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('PIXEL123'),
              contains('emulator-5554'),
              contains('ANDROID_SERIAL'),
              contains('--test_env=ANDROID_SERIAL='),
            ),
          ),
        ),
      );
    }, skip: _noSh);

    test('refuses an ANDROID_SERIAL no attached device has, naming those '
        'that are', () {
      final app = appWith('$header$pixel', env: {'ANDROID_SERIAL': 'nope'});
      expect(
        app.chooseDevice,
        throwsA(
          isA<AdbDeviceChoiceError>().having(
            (e) => e.message,
            'message',
            allOf(contains('nope'), contains('PIXEL123')),
          ),
        ),
      );
    }, skip: _noSh);

    test('refuses an ANDROID_SERIAL whose device is not ready, saying '
        'its state', () {
      final app = appWith(
        '$header$pixel'
        'emulator-5554\toffline\n',
        env: {'ANDROID_SERIAL': 'emulator-5554'},
      );
      expect(
        app.chooseDevice,
        throwsA(
          isA<AdbDeviceChoiceError>().having(
            (e) => e.message,
            'message',
            allOf(contains('emulator-5554'), contains('offline')),
          ),
        ),
      );
    }, skip: _noSh);

    test('refuses an empty bench', () {
      final app = appWith(header);
      expect(app.chooseDevice, throwsA(isA<AdbDeviceChoiceError>()));
    }, skip: _noSh);
  });

  test('every adb call after the choice names the chosen device', () {
    final app = appWith(
      '$header$pixel$emulator',
      env: {'ANDROID_SERIAL': 'PIXEL123'},
    );
    app.chooseDevice();
    app.install();
    app.adb(['shell', 'true']);
    expect(
      calls().skip(1),
      everyElement(startsWith('-s PIXEL123 ')),
      reason: 'a bare adb call fails with "more than one device"',
    );
    expect(calls(), contains('-s PIXEL123 install -r /app.apk'));
  }, skip: _noSh);
}
