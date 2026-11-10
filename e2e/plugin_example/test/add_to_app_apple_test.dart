/// Checks the xcframeworks of Apple add-to-app against what `flutter build
/// ios-framework` and `macos-framework` make.
///
/// Usage: `add_to_app_apple_test --platform=P --mode=M XCFRAMEWORK...`, `P`
/// `ios` or `macos`, `M` `debug`, `profile` or `release`, each
/// `XCFRAMEWORK` a runfiles path of an `.xcframework`.
///
/// It reads each xcframework where the build wrote it, which it finds through
/// the link to its `Info.plist`: a sandbox's copy of a versioned framework has
/// lost the framework's own links.
///
/// Properties, per xcframework:
///
/// * `App.xcframework`: a slice per library identifier of its `Info.plist`
///   (iOS: the device and the simulator; macOS: arm64). The device or macOS
///   binary is the AOT snapshot in profile and release, with its dSYM in
///   `dSYMs/`, and a stub without one in debug, the kernel and VM snapshots
///   then in `flutter_assets/`. The iOS simulator slice is a debug build in
///   every mode. Every binary's install name is `@rpath/App.framework/App`,
///   and it is built for its platform. A macOS framework is versioned, its
///   links in place.
/// * `Flutter.xcframework` and `FlutterMacOS.xcframework`: Flutter's
///   signature verifies, so the copy is byte for byte and link for link the
///   one Flutter signed.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/plist.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

final _failures = <String>[];

void _check(bool ok, String message) {
  if (!ok) _failures.add(message);
}

String _run(String executable, List<String> args) {
  final result = Process.runSync(executable, args);
  if (result.exitCode != 0) {
    _failures.add('$executable ${args.join(' ')} failed:\n${result.stderr}');
  }
  return result.stdout.toString();
}

/// The `LC_BUILD_VERSION` platform number of [binary]: 1 macOS, 2 iOS, 7
/// the iOS simulator.
String _platformOf(String binary) {
  final match = RegExp(
    r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)',
  ).firstMatch(_run('otool', ['-l', binary]));
  return match?.group(1) ?? 'none';
}

String _installName(String binary) =>
    _run('otool', ['-D', binary]).trim().split('\n').last;

bool _hasSnapshot(String binary) =>
    _run('nm', [binary]).contains('_kDartSnapshot');

void _checkApp(String xcframework, String platform, String mode) {
  final libraries = [
    for (final l
        in Plist.read('$xcframework/Info.plist').values['AvailableLibraries']!
            as List<Object?>)
      l! as Map<String, Object?>,
  ];
  final ids = {for (final l in libraries) l['LibraryIdentifier']! as String};
  final expected = platform == 'ios'
      ? {'ios-arm64', 'ios-arm64-simulator'}
      : {'macos-arm64'};
  _check(
    ids.length == expected.length && ids.containsAll(expected),
    'App.xcframework has the slices $ids, not $expected',
  );
  for (final library in libraries) {
    final id = library['LibraryIdentifier']! as String;
    final slice = '$xcframework/$id';
    final binary = '$slice/${library['BinaryPath']}';
    final simulator = id.endsWith('-simulator');
    final debug = mode == 'debug' || simulator;
    _check(
      File(binary).existsSync(),
      '$id has no binary at ${library['BinaryPath']}',
    );
    if (!File(binary).existsSync()) continue;
    _check(
      _installName(binary) == '@rpath/App.framework/App',
      '$id: the install name of App is ${_installName(binary)}',
    );
    final want = platform == 'macos' ? '1' : (simulator ? '7' : '2');
    _check(
      _platformOf(binary) == want,
      '$id: App is built for platform ${_platformOf(binary)}, not $want',
    );
    _check(
      _hasSnapshot(binary) == !debug,
      '$id: App ${debug ? 'is not a stub' : 'has no AOT snapshot'} in $mode',
    );
    final assets = platform == 'macos'
        ? '$slice/App.framework/Versions/A/Resources/flutter_assets'
        : '$slice/App.framework/flutter_assets';
    for (final name in [
      'kernel_blob.bin',
      'vm_snapshot_data',
      'isolate_snapshot_data',
    ]) {
      _check(
        File('$assets/$name').existsSync() == debug,
        '$id: flutter_assets/$name is ${debug ? 'missing' : 'there'} in $mode',
      );
    }
    _check(
      File('$assets/AssetManifest.bin').existsSync(),
      '$id: flutter_assets has no AssetManifest.bin',
    );
    final dsym = Directory('$slice/dSYMs/App.framework.dSYM');
    _check(
      dsym.existsSync() == !debug,
      '$id: dSYMs/App.framework.dSYM is ${debug ? 'there' : 'missing'} in $mode',
    );
    _check(
      (library['DebugSymbolsPath'] == 'dSYMs') == !debug,
      '$id: Info.plist DebugSymbolsPath is ${library['DebugSymbolsPath']}',
    );
    if (platform == 'macos') _checkVersioned('$slice/App.framework', 'App');
  }
}

/// The links of a versioned framework: `Versions/Current -> A`, and the
/// binary and `Resources` through it.
void _checkVersioned(String framework, String name) {
  String? target(String path) {
    final link = Link('$framework/$path');
    return link.existsSync() ? link.targetSync() : null;
  }

  _check(
    target('Versions/Current') == 'A',
    '$framework: Versions/Current is not a link to A',
  );
  _check(
    target(name) == 'Versions/Current/$name',
    '$framework: $name is not a link into Versions/Current',
  );
  _check(
    target('Resources') == 'Versions/Current/Resources',
    '$framework: Resources is not a link into Versions/Current',
  );
}

void _checkEngine(String xcframework, String platform) {
  final result = Process.runSync('codesign', [
    '--verify',
    '--deep',
    '--strict',
    xcframework,
  ]);
  _check(
    result.exitCode == 0,
    '${xcframework.split('/').last}: Flutter signature does not verify:\n'
    '${result.stderr}',
  );
  if (platform == 'macos') {
    _checkVersioned(
      '$xcframework/macos-arm64_x86_64/FlutterMacOS.framework',
      'FlutterMacOS',
    );
  }
}

void main(List<String> args) {
  String? platform;
  String? mode;
  final xcframeworks = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--platform=')) {
      platform = arg.substring('--platform='.length);
    } else if (arg.startsWith('--mode=')) {
      mode = arg.substring('--mode='.length);
    } else {
      // Its `Info.plist` links to the file the build wrote, whose directory
      // has the links.
      final plist = File(
        '${requireRunfile(arg, what: 'xcframework')}/Info.plist',
      );
      xcframeworks.add(
        plist.resolveSymbolicLinksSync().replaceAll(
          RegExp(r'/Info\.plist$'),
          '',
        ),
      );
    }
  }
  if (platform == null || mode == null || xcframeworks.isEmpty) {
    stderr.writeln(
      'usage: --platform=<ios|macos> '
      '--mode=<debug|profile|release> <xcframework>...',
    );
    exit(64);
  }
  for (final xcframework in xcframeworks) {
    switch (xcframework.split('/').last) {
      case 'App.xcframework':
        _checkApp(xcframework, platform, mode);
      case 'Flutter.xcframework' || 'FlutterMacOS.xcframework':
        _checkEngine(xcframework, platform);
      case final other:
        _failures.add('$other: no checks for this xcframework');
    }
  }
  if (_failures.isNotEmpty) {
    stderr.writeln(_failures.join('\n'));
    exit(1);
  }
  stdout.writeln(
    '${xcframeworks.length} $platform xcframeworks ($mode) are as '
    'upstream makes them.',
  );
}
