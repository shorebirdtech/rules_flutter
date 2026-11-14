/// Creates a SPOT Linux VM for the e2e suites and visual verification:
/// overhead's Linux VM (`@overhead//vm:create_linux_vm`) plus what
/// rules_flutter needs on it.
///
///     bazel run //tools/vm:create_linux_vm -- [vm-name] \
///         [--machine-type=e2-standard-4] [--disk-size=60GB]
///
/// Beyond overhead's: the GTK3 runtime (`libgtk-3-0`: without it a Flutter
/// runner dies with `libgtk-3.so.0: cannot open shared object file`), Xvfb and
/// the X tools the window checks use, and the Dart SDK `@rules_dart//dart`
/// resolves to, for the verification scripts.
library;

import 'package:overhead_vm/create_vm.dart';

import 'hermetic_dart.dart';

/// The Linux VM rules_flutter runs on, with the Dart SDK at [dartVersion].
LinuxVm flutterLinuxVm(String dartVersion) => LinuxVm(
  defaultName: 'flutter-linux-test',
  aptPackages: const [
    'libegl1',
    'libgles2',
    'libgl1-mesa-dri',
    'libgtk-3-0',
    'x11-utils',
    'xvfb',
    'xdotool',
    'scrot',
  ],
  startup:
      '''
if ! command -v dart &>/dev/null; then
  curl -fsSL https://storage.googleapis.com/dart-archive/channels/stable/release/$dartVersion/sdk/dartsdk-linux-x64-release.zip -o /tmp/dart.zip
  unzip -q -o /tmp/dart.zip -d /opt
  ln -sf /opt/dart-sdk/bin/dart /usr/local/bin/dart
  rm /tmp/dart.zip
fi
''',
);

Future<void> main(List<String> args) async =>
    createLinuxVm(args, vm: flutterLinuxVm(await hermeticDartVersion()));
