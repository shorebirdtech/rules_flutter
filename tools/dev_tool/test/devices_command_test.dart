import 'dart:convert';

import 'package:flutter_bazel_dev_tool/device_discovery.dart';
import 'package:flutter_bazel_dev_tool/devices_command.dart';
import 'package:test/test.dart';

DiscoveredDevice _device(
  String id,
  String kind, {
  String name = 'Device',
  String category = 'mobile',
  String platform = 'ios',
  String sdk = 'iOS 27.2',
  bool emulator = false,
  bool available = true,
  String state = 'wired',
  DeviceConnection connection = DeviceConnection.attached,
}) => DiscoveredDevice(
  id: id,
  answersTo: {id.substring(id.indexOf(':') + 1)},
  kind: kind,
  name: name,
  category: category,
  targetPlatform: platform,
  sdk: sdk,
  emulator: emulator,
  supported: true,
  available: available,
  state: state,
  connection: connection,
);

final _macos = _device(
  'macos',
  'macos',
  name: 'macOS',
  category: 'desktop',
  platform: 'darwin-arm64',
  sdk: 'macOS 27.2 26B123 darwin-arm64',
  state: 'host',
);

final _emulator = _device(
  'android:emulator-5554',
  'android',
  name: 'sdk gphone64 arm64',
  platform: 'android-arm64',
  sdk: 'Android 16 (API 36)',
  emulator: true,
  state: 'device',
);

final _phone = _device(
  'ios:00008101-001C',
  'ios',
  name: "Aran's iPhone",
  sdk: 'iOS 27.2 24B119',
  state: 'wireless',
  connection: DeviceConnection.wireless,
);

void main() {
  test('lists upstream\'s columns, phones first, wireless apart', () {
    final report = devicesReport(
      lookup: DeviceLookup([_phone, _emulator], ['devicectl', 'adb'], {}),
      host: [_macos],
    );
    expect(
      report,
      startsWith(
        'Found 2 connected devices:\n'
        '  sdk gphone64 arm64 (mobile) • android:emulator-5554 • '
        'android-arm64 • Android 16 (API 36) (emulator)\n'
        '  macOS (desktop)             • macos                 • '
        'darwin-arm64  • macOS 27.2 26B123 darwin-arm64\n'
        '\n'
        'Found 1 wirelessly connected device:\n'
        "  Aran's iPhone (mobile) • ios:00008101-001C • ios • iOS 27.2 24B119\n",
      ),
    );
    expect(report, contains('--device-timeout'));
  });

  test('lists only devices ready to run on, and says why not the rest', () {
    final report = devicesReport(
      lookup: DeviceLookup(
        [
          _device(
            'android:R5CT',
            'android',
            available: false,
            state: 'unauthorized',
          ),
          _device('ios-simulator:OFF', 'ios-simulator', available: false),
        ],
        ['adb'],
        {'simctl': '`xcrun simctl` did not answer within 3000ms'},
      ),
      host: const [],
      timeoutGiven: true,
    );
    expect(report, startsWith('No authorized devices detected.\n'));
    expect(report, isNot(contains('ios-simulator:OFF')));
    expect(
      report,
      contains('The Android device R5CT is unauthorized, so it is not listed.'),
    );
    expect(
      report,
      contains('simctl could not be asked for its devices: `xcrun simctl`'),
    );
    expect(report, isNot(contains('--device-timeout')));
  });

  test('says when the workspace has no Android SDK', () {
    expect(
      devicesReport(
        lookup: const DeviceLookup([], [], {}, androidAbsence: 'no SDK here.'),
        host: [_macos],
      ),
      contains('No Android devices are listed: no SDK here.'),
    );
  });

  test('--device-connection keeps one kind', () {
    final report = devicesReport(
      lookup: DeviceLookup([_phone, _emulator], [], {}),
      host: [_macos],
      connection: DeviceConnection.wireless,
    );
    expect(report, contains('ios:00008101-001C'));
    expect(report, isNot(contains('emulator-5554')));
    expect(report, isNot(contains('macos ')));
  });

  test('--machine prints upstream\'s JSON, a list of devices', () {
    final report = devicesReport(
      lookup: DeviceLookup([_emulator], ['adb'], {}),
      host: [_macos],
      machine: true,
    );
    final devices = (json.decode(report) as List).cast<Map<String, dynamic>>();
    expect(
      [for (final d in devices) d['id']],
      [
        'android:emulator-5554',
        'macos',
      ],
    );
    expect(devices.first.keys, [
      'name',
      'id',
      'isSupported',
      'targetPlatform',
      'emulator',
      'sdk',
      'capabilities',
    ]);
  });

  group('DevicesCommand.parser', () {
    test('takes upstream\'s flags', () {
      final results = DevicesCommand.parser.parse([
        '--machine',
        '--device-timeout',
        '10',
        '--device-connection',
        'attached',
      ]);
      expect(results['machine'], isTrue);
      expect(results['device-timeout'], '10');
      expect(results['device-connection'], 'attached');
    });

    test('refuses an unknown connection', () {
      expect(
        () => DevicesCommand.parser.parse(['--device-connection', 'usb']),
        throwsFormatException,
      );
    });
  });
}
