import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_bazel_dev_tool/android_sdk.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/device_discovery.dart';
import 'package:test/test.dart';

/// An [AndroidSdk] that answers [tools].
class _FakeAndroidSdk extends AndroidSdk {
  final AndroidSdkTools? tools;

  const _FakeAndroidSdk(this.tools);

  @override
  Future<AndroidSdkTools?> find() async => tools;

  @override
  String get absence => 'this workspace has no Android SDK (fake).';
}

const _adbDevices =
    'List of devices attached\n'
    'emulator-5554          device product:sdk_gphone64_arm64 '
    'model:sdk_gphone64_arm64 device:emu64a transport_id:1\n'
    'R5CT000000   unauthorized usb:1-1 transport_id:2\n';

const _emulatorProps =
    '[ro.build.version.release]: [16]\n'
    '[ro.build.version.sdk]: [36]\n'
    '[ro.hardware]: [ranchu]\n'
    '[ro.product.cpu.abi]: [arm64-v8a]\n'
    '[ro.product.cpu.abilist]: [arm64-v8a]\n'
    '[ro.product.model]: [sdk_gphone64_arm64]\n';

void main() {
  group('parseSimctlDevices', () {
    test('every simulator, booted ones available, by -d id', () {
      final devices = parseSimctlDevices(
        json.encode({
          'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-27-2': [
              {'udid': 'BOOTED', 'name': 'iPhone 17', 'state': 'Booted'},
              {'udid': 'OFF', 'name': 'iPad', 'state': 'Shutdown'},
            ],
          },
        }),
      );
      expect(
        [for (final d in devices) d.id],
        [
          'ios-simulator:BOOTED',
          'ios-simulator:OFF',
        ],
      );
      expect([for (final d in devices) d.available], [true, false]);
      expect(devices.first.row, [
        'iPhone 17 (mobile)',
        'ios-simulator:BOOTED',
        'ios',
        // An Intel Mac's simulator is one rules_flutter does not build for.
        _arm64Mac
            ? 'com.apple.CoreSimulator.SimRuntime.iOS-27-2 (simulator)'
            : 'com.apple.CoreSimulator.SimRuntime.iOS-27-2 (unsupported) '
                  '(simulator)',
      ]);
      expect(devices.last.description, "the iOS simulator 'iPad' (Shutdown)");
    });
  });

  group('Android', () {
    test('parses adb devices -l in any state', () {
      expect(parseAdbDevices(_adbDevices), [
        (serial: 'emulator-5554', state: 'device', model: 'sdk_gphone64_arm64'),
        (serial: 'R5CT000000', state: 'unauthorized', model: null),
      ]);
    });

    test('an emulator, described by its properties as upstream does', () {
      final device = androidDeviceFrom(
        parseAdbDevices(_adbDevices).first,
        parseAdbProperties(_emulatorProps),
      );
      expect(device.row, [
        'sdk gphone64 arm64 (mobile)',
        'android:emulator-5554',
        'android-arm64',
        'Android 16 (API 36) (emulator)',
      ]);
      expect(device.toJson(), {
        'name': 'sdk gphone64 arm64',
        'id': 'android:emulator-5554',
        'isSupported': true,
        'targetPlatform': 'android-arm64',
        'emulator': true,
        'sdk': 'Android 16 (API 36)',
        'capabilities': {
          'hotReload': true,
          'hotRestart': true,
          'screenshot': true,
          'flutterExit': true,
          'hardwareRendering': true,
          'startPaused': true,
        },
      });
    });

    test('an ABI rules_flutter does not build for is unsupported', () {
      final device = androidDeviceFrom(
        (serial: 'X', state: 'device', model: 'old'),
        {'ro.product.cpu.abi': 'x86', 'ro.product.cpu.abilist': 'x86'},
      );
      expect(device.supported, isFalse);
      expect(device.targetPlatform, 'android-x86');
    });

    test('a device paired over Wi-Fi is wireless', () {
      final device = androidDeviceFrom((
        serial: 'adb-R5CT-abc._adb-tls-connect._tcp',
        state: 'device',
        model: null,
      ), const {});
      expect(device.connection, DeviceConnection.wireless);
    });
  });

  test('an iOS device by its UDID, wireless over the network', () {
    final device = iosDeviceFrom(
      IOSDeviceInfo(
        udid: '00008101-001C',
        coreDeviceId: 'CORE',
        name: "Aran's iPhone",
        transport: IOSDeviceTransport.wireless,
        hostnames: const [],
        osVersion: '27.2 24B119',
      ),
    );
    expect(device.row, [
      "Aran's iPhone (mobile)",
      'ios:00008101-001C',
      'ios',
      'iOS 27.2 24B119',
    ]);
    expect(device.answersTo, {'00008101-001C', 'CORE'});
    expect(device.connection, DeviceConnection.wireless);
  });

  group('DeviceDiscovery.lookUp', () {
    test('asks adb each ready device\'s properties, in one call', () async {
      final calls = <String>[];
      Future<ProcessResult> run(String exe, List<String> args) async {
        calls.add([exe, ...args].join(' '));
        return ProcessResult(
          0,
          0,
          args.contains('getprop') ? _emulatorProps : _adbDevices,
          '',
        );
      }

      final lookup = await DeviceDiscovery(
        androidSdk: const _FakeAndroidSdk(
          AndroidSdkTools(adb: '/adb', aapt2: '/aapt2'),
        ),
        run: run,
        appleHost: false,
      ).lookUp();
      expect(calls, [
        '/adb devices -l',
        '/adb -s emulator-5554 shell getprop',
      ]);
      expect(
        [for (final d in lookup.devices) (d.id, d.available)],
        [
          ('android:emulator-5554', true),
          ('android:R5CT000000', false),
        ],
      );
      expect(lookup.answered, ['adb']);
    });

    test('a lookup that does not answer is named, with why', () async {
      final lookup = await DeviceDiscovery(
        androidSdk: const _FakeAndroidSdk(null),
        run: (exe, args) async =>
            throw StateError('`xcrun` did not answer within 1000ms'),
        appleHost: true,
      ).lookUp();
      expect(lookup.devices, isEmpty);
      expect(lookup.unanswered.keys, ['simctl', 'devicectl']);
      expect(lookup.unanswered['simctl'], contains('did not answer'));
      expect(lookup.androidAbsence, contains('no Android SDK'));
    });
  });
}

final _arm64Mac = Abi.current() == Abi.macosArm64;
