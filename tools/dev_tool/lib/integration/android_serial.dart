/// Which attached Android device an integration test runs on.
///
/// The one `ANDROID_SERIAL` names, else the only one attached. The test
/// installs the app on a device and drives it for as long as the suite runs, so
/// a choice made for it, by `adb` answering for whichever device it found
/// first, would put the app on a phone nobody picked: no device and several
/// devices are both failures, and name how to fix them.
library;

import 'dart:convert';

import '../device.dart' show ProcessRunSync;

/// A device `adb devices` lists, and the state it is in.
typedef _Listed = ({String serial, String state});

/// The serial of the device the test runs on.
///
/// [adb] is the `adb` to ask; [requested] is `ANDROID_SERIAL`, which is no
/// request when null or empty; [run] runs `adb`.
///
/// Throws a [StateError] saying what is wrong and what to do about it.
Future<String> chooseAndroidSerial({
  required String adb,
  required String? requested,
  required ProcessRunSync run,
}) async {
  final result = await run(adb, const ['devices']);
  if (result.exitCode != 0) {
    throw StateError(
      '`adb devices` exited ${result.exitCode}: ${result.stderr}'.trim(),
    );
  }
  final listed = _parse('${result.stdout}');
  final ready = [
    for (final device in listed)
      if (device.state == 'device') device.serial,
  ];

  if (requested != null && requested.isNotEmpty) {
    if (ready.contains(requested)) return requested;
    throw StateError(
      'ANDROID_SERIAL is $requested, which is not an attached device that is '
      'ready: ${_describe(listed)} (`adb devices` lists what is attached).',
    );
  }
  if (ready.length == 1) return ready.single;
  if (ready.isEmpty) {
    throw StateError(
      listed.isEmpty
          ? 'no Android device is attached: connect a phone, or boot an '
                'emulator, and check that `adb devices` lists it as `device`.'
          : 'no Android device is ready: ${_describe(listed)}. A device '
                'must be listed by `adb devices` as `device`.',
    );
  }
  throw StateError(
    '${ready.length} Android devices are attached (${ready.join(', ')}), and '
    'the test runs on one: choose it with ANDROID_SERIAL, as '
    '`--test_env=ANDROID_SERIAL=<serial>` (`adb devices` lists them).',
  );
}

String _describe(List<_Listed> listed) => listed.isEmpty
    ? 'none is attached'
    : 'attached: ${listed.map((d) => '${d.serial} (${d.state})').join(', ')}';

/// The devices of `adb devices`: a line of a serial and a state each.
List<_Listed> _parse(String output) {
  final devices = <_Listed>[];
  for (final line in const LineSplitter().convert(output)) {
    // The header, the daemon's own `* daemon started` lines, and blanks.
    if (line.startsWith('List of devices') || line.startsWith('*')) continue;
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length >= 2) {
      devices.add((serial: fields[0], state: fields[1]));
    }
  }
  return devices;
}
