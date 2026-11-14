/// Turning the `-d` ids a user passes into [Device]s.
///
/// An id has to say what kind of device it names: a keyword (`macos`,
/// `ios-simulator`, `android`, ...) or a kind-prefixed form
/// (`ios-simulator:<udid>`, `ios:<udid>`, `android:<serial>`). Anything else is
/// refused rather than guessed at: a guess that picks the wrong kind sends the
/// id to the wrong tool, whose error names neither the id nor the flag, and
/// guessing right would mean asking `simctl`, `devicectl` and `adb` on every
/// launch. The prefix costs the user a few characters.
///
/// Refusing is where the tool may spend time: [resolveDevices] then asks those
/// same three tools, concurrently and each under a short bound, whether they
/// know the id, and says which prefix it needs. None of that runs when every id
/// resolves.
library;

import 'dart:async';

import 'android_sdk.dart';
import 'dev_tool_exception.dart';
import 'device.dart';
import 'device_discovery.dart';

/// The ids `-d` accepts, as the refusal lists them.
const acceptedDeviceIdForms = [
  'macos',
  'linux',
  'windows',
  'chrome',
  'ios-simulator',
  'ios-simulator:<udid>',
  'ios',
  'ios:<udid>',
  'android',
  'android:<serial>',
];

/// Resolve `-d` ids to [Device] instances.
///
/// With no [ids], one device for the current platform. Otherwise each id must
/// be one of [acceptedDeviceIdForms]; the prefixed forms name one device of
/// that kind, the bare keywords whichever one is booted or attached.
///
/// An id that names no kind throws a [DevToolException]. Only then are
/// `simctl`, `devicectl` and `adb` asked about it — the [DeviceDiscovery]
/// `flutter_bazel devices` lists from, through [runProbe], each bounded by
/// [deviceLookupBound] — so the message can give the exact form to pass.
///
/// An Android device is driven with the tools of [androidSdk], the
/// workspace's: an Android id in a workspace with none is refused, saying so,
/// and the lookups leave Android out there rather than build anything for it.
Future<List<Device>> resolveDevices(
  List<String> ids, {
  required AndroidSdk androidSdk,
  ProcessRunSync? runProbe,
  bool? appleHost,
}) async {
  if (ids.isEmpty) return [detectDevice()];
  final devices = <Device>[];
  final refused = <String>[];
  for (final id in ids) {
    final device = await _resolveDevice(id, androidSdk);
    if (device == null) {
      refused.add(id);
    } else {
      devices.add(device);
    }
  }
  if (refused.isEmpty) return devices;
  final known = await DeviceDiscovery(
    androidSdk: androidSdk,
    run: runProbe,
    appleHost: appleHost,
  ).lookUp();
  throw DevToolException(
    [for (final id in refused) _explainRefusal(id, known)].join('\n\n'),
  );
}

/// The device [id] names, or null when it names no kind of device.
Future<Device?> _resolveDevice(String id, AndroidSdk androidSdk) async {
  switch (id) {
    case 'macos':
      return MacOSDevice();
    case 'linux':
      return LinuxDevice();
    case 'windows':
      return WindowsDevice();
    case 'chrome':
      return WebDevice();
    case 'ios-simulator':
      return IOSSimulatorDevice.booted();
    case 'ios':
      return IOSDevice();
    // Whichever device `adb` itself picks, which is the one attached when there
    // is one and a named refusal from adb when there are several.
    case 'android':
      final tools = await androidSdk.require();
      return AndroidDevice(adbPath: tools.adb, aapt2Path: tools.aapt2);
  }
  final colon = id.indexOf(':');
  if (colon < 0) return null;
  final kind = id.substring(0, colon);
  final rest = id.substring(colon + 1);
  final Future<Device> Function(String)? make = switch (kind) {
    'ios-simulator' => (String udid) async => IOSSimulatorDevice(udid: udid),
    'ios' => (String udid) async => IOSDevice(udid: udid),
    // The prefix is stripped, never passed on: a colon in `adb -s` means a
    // network device, so the server reads the serial as `android` and the rest
    // as a service name, and answers `unknown host service
    // '<serial>:features'` — a sentence naming neither the id nor the flag.
    'android' => (String serial) async {
      final tools = await androidSdk.require();
      return AndroidDevice(
        deviceId: serial,
        adbPath: tools.adb,
        aapt2Path: tools.aapt2,
      );
    },
    _ => null,
  };
  if (make == null) return null;
  if (rest.isEmpty) {
    throw DevToolException(
      '-d $id names no device: put its id after the colon, or pass '
      '-d $kind for the one that is ${kind == 'ios-simulator' ? 'booted' : 'attached'}.',
    );
  }
  return make(rest);
}

String _explainRefusal(String id, DeviceLookup lookup) {
  // A prefix with a typo in it is still worth looking up by what follows it.
  final colon = id.indexOf(':');
  final keys = {id, if (colon >= 0) id.substring(colon + 1)};
  final matches = [
    for (final device in lookup.devices)
      for (final key in keys)
        if (device.answersTo.contains(key)) (key: key, device: device),
  ];
  final head =
      '-d $id does not say what kind of device it is, so it is refused '
      'rather than guessed at.';
  if (matches.isNotEmpty) {
    return [
      head,
      for (final m in matches)
        '${m.key} is ${m.device.description}; pass -d ${m.device.kind}:${m.key}',
    ].join('\n');
  }
  final bare = keys.last;
  return [
    head,
    if (lookup.answered.isNotEmpty)
      'No device that ${lookup.answered.join(' or ')} lists has that id.',
    if (lookup.unanswered.isNotEmpty)
      '${lookup.unanswered.keys.join(', ')} could not be asked '
          '(LOG_LEVEL=fine says why).',
    'For an Android serial pass -d android:$bare, for an iOS simulator '
        '-d ios-simulator:$bare, for an iOS device -d ios:$bare.',
    'Accepted forms: ${acceptedDeviceIdForms.join(', ')}. '
        '`flutter_bazel devices` lists each device with its id.',
  ].join('\n');
}
