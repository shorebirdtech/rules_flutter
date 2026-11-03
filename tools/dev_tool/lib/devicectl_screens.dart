/// The screens of an iOS device or simulator, and capturing one, through
/// `devicectl`.
///
/// One mechanism for a simulator and for hardware: `devicectl device info
/// displays` lists the screens and `devicectl device capture screenshot`
/// captures one. `simctl io screenshot` is not used because it cannot choose
/// between a multi-screen simulator's displays, and on a powered-off one it
/// never returns. Both `devicectl` commands first shipped in Xcode 27.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'screen.dart';

/// Runs a process to completion, as `Process.run` does.
typedef DevicectlRun = Future<ProcessResult> Function(String, List<String>);

/// The screens in the output of `devicectl device info displays --json-output`.
///
/// Apple documents that JSON as versioned and stable. A display the JSON
/// describes without a `name` or a `type` is refused rather than filled in:
/// the type is what decides whether it is ever the default.
List<Screen> parseDevicectlDisplays(String source) {
  final Object? decoded;
  try {
    decoded = json.decode(source);
  } on FormatException catch (e) {
    throw StateError('devicectl displays JSON could not be read: $e');
  }
  final displays = switch (decoded) {
    {'result': {'displays': final List<Object?> displays}} => displays,
    _ => throw StateError(
      'devicectl displays JSON has no result.displays list.',
    ),
  };
  return [for (final display in displays) _parseDisplay(display)];
}

Screen _parseDisplay(Object? display) {
  if (display is! Map<String, Object?>) {
    throw StateError('devicectl displays JSON has a display that is $display.');
  }
  final name = display['name'];
  if (name is! String) {
    throw StateError('devicectl displays JSON has a display without a name.');
  }
  // `{"integrated": {}}`: the type is the one key.
  final type = switch (display['type']) {
    final Map<String, Object?> t when t.length == 1 => t.keys.single,
    final String t => t,
    _ => throw StateError(
      'devicectl displays JSON has a display ($name) without a type.',
    ),
  };
  final uniqueId = display['uniqueId'];
  final displayId = display['displayId'];
  final size = display['nativeSize'];
  final active = display['active'];
  if (uniqueId is! String && displayId is! int) {
    throw StateError(
      'devicectl displays JSON has a display ($name) with neither a uniqueId '
      'nor a displayId.',
    );
  }
  return Screen(
    id: uniqueId is String ? uniqueId : 'displayId:$displayId',
    name: name,
    type: type,
    displayId: displayId is int ? displayId : null,
    width: size is List && size.length == 2 ? (size[0] as num).toInt() : null,
    height: size is List && size.length == 2 ? (size[1] as num).toInt() : null,
    active: active is bool ? active : null,
    primary: display['primary'] == true,
    captureId: uniqueId is String ? uniqueId : null,
  );
}

/// The `devicectl` calls that list and capture the screens of one device.
class DevicectlScreens {
  DevicectlScreens({
    required DevicectlRun run,
    required String Function() device,
    required String Function() deviceName,
    this.isSimulator = false,
  }) : _run = run,
       _device = device,
       _deviceName = deviceName;

  /// Whether the device is a simulator, whose UDID came from `simctl`. A
  /// `devicectl` that then does not know it has no simulator support.
  final bool isSimulator;

  final DevicectlRun _run;

  /// What `--device` is given, read when a command runs: a simulator that
  /// launches on `booted` has no UDID until then.
  final String Function() _device;

  /// What an error calls the device.
  final String Function() _deviceName;

  /// The device's screens as it reports them now.
  Future<List<Screen>> list(ScreenshotDeadline deadline) {
    return deadline.within('listing the screens of ${_deviceName()}', () {
      return _list(deadline);
    });
  }

  Future<List<Screen>> _list(ScreenshotDeadline deadline) async {
    // Synchronous file calls, unlike `withTempDir`: nothing here waits on the
    // file system, so the listing is only as asynchronous as `devicectl` and a
    // test can run it under `fakeAsync`, where real I/O never completes.
    final dir = Directory.systemTemp.createTempSync('flutter_displays_');
    try {
      final path = p.join(dir.path, 'displays.json');
      final result = await _run('xcrun', [
        'devicectl',
        'device',
        'info',
        'displays',
        '--device',
        _device(),
        '--json-output',
        path,
        '--timeout',
        '${deadline.seconds}',
        '--quiet',
      ]);
      if (result.exitCode != 0) {
        throw _failure(
          'list the screens of',
          result,
          'devicectl device info displays',
        );
      }
      final file = File(path);
      if (!file.existsSync()) {
        throw StateError(
          'devicectl listed the screens of ${_deviceName()} but wrote no JSON '
          'to $path.',
        );
      }
      return parseDevicectlDisplays(file.readAsStringSync());
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  /// Captures [screen] to the PNG at [outputPath].
  ///
  /// A screen with a unique id is named by it. One without is captured by
  /// naming nothing, which devicectl documents as capturing the primary
  /// display; [Screen.capturable] has already refused any other.
  Future<void> capture(
    Screen screen,
    String outputPath,
    ScreenshotDeadline deadline,
  ) =>
      deadline.within('capturing ${screen.name} of ${_deviceName()}', () async {
        final result = await _run('xcrun', [
          'devicectl',
          'device',
          'capture',
          'screenshot',
          '--device',
          _device(),
          '--destination',
          outputPath,
          if (screen.captureId != null) ...[
            '--display-unique-id',
            screen.captureId!,
          ],
          '--timeout',
          '${deadline.seconds}',
          '--quiet',
        ]);
        if (result.exitCode == 0) return;
        throw _failure(
          'capture ${screen.name} of',
          result,
          'devicectl device capture screenshot',
        );
      });

  StateError _failure(String what, ProcessResult result, String command) {
    final output = '${result.stderr}${result.stdout}';
    if (_lacksSubcommand(result.exitCode, output, command)) {
      return StateError(
        'iOS screenshots need Xcode 27 or later (`$command`). The selected '
        'Xcode\'s devicectl does not have it; select a newer one with '
        '`xcode-select` or DEVELOPER_DIR.',
      );
    }
    // Not a message about an old Xcode that one was seen to print: it is what
    // is detectable. This devicectl was asked about a simulator `simctl` named
    // and says it has no such device.
    if (isSimulator && output.contains('The specified device was not found')) {
      return StateError(
        'devicectl does not know the simulator ${_device()}, so it cannot '
        '$what it. Screenshots of an iOS simulator need a devicectl that '
        'lists simulators, which Xcode 27 or later has: `xcrun devicectl list '
        'devices` shows the simulators it knows. If it lists this one, the '
        'device went away between the launch and the screenshot.',
      );
    }
    return StateError('devicectl could not $what ${_deviceName()}: $output');
  }

  /// Whether devicectl refused the command line as a usage error (exit 64,
  /// `EX_USAGE`) without knowing [command].
  ///
  /// The arguments are right for every devicectl that has the command, so a
  /// usage error means it does not. A devicectl without the subcommand stops
  /// parsing at `device`, rejects the first option after it ("Unknown option
  /// '--device'") and prints `devicectl device`'s usage. A command that runs
  /// and fails exits 1 with a CoreDevice error instead, and one that knows the
  /// subcommand and dislikes an argument prints that subcommand's own usage.
  static bool _lacksSubcommand(int exitCode, String output, String command) =>
      exitCode == 64 && !output.contains('Usage: $command');
}
