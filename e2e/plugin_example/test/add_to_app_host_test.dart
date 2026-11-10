/// Builds a native app with Xcode that embeds the add-to-app module, runs it,
/// and checks that its Flutter screen ran and every plugin answered.
///
/// Usage: `add_to_app_host_test --platform=P --configuration=C TARGET HOST`.
/// `TARGET` is the `flutter_ios_xcframeworks` or `flutter_macos_xcframeworks`
/// of the workspace's root package whose `bazel run` program the test runs,
/// and `HOST` the runfiles path of the host's Xcode project directory
/// (`add_to_app_host/ios`). The test:
///
/// 1. writes the module into the host's `Flutter/`, as `bazel run` does;
/// 2. builds the host with `xcodebuild` in configuration `C`, the host taking
///    the module through its Swift package (`Flutter/FlutterPluginRegistrant`);
/// 3. runs it, on the booted iOS simulator or on this Mac, until the module
///    reports `add_to_app_results` with every plugin's answer, and the host
///    its call into the Swift half of the mixed plugin;
/// 4. saves a screenshot in the test's undeclared outputs.
///
/// Tagged `manual`: it needs Xcode, a booted iOS simulator for iOS, and an
/// unlocked GUI session.
library;

// This script reports what it found to the test log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/add_to_app.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

const _bundleId = 'com.example.addtoapp.host';
const _timeout = Duration(seconds: 90);

/// What the mixed plugin answers: its Objective-C half's greeting, which its
/// Swift half passes on and its Objective-C half answers the channel with.
const _mixedGreeting = 'Hello from Objective-C, through Swift';

/// What the module and the host must report.
const _expected = [
  'mixed=$_mixedGreeting',
  'appName=HostApp',
  'launch=launch ok',
  'prefs=roundtrip ok',
  'audio=audio ok',
  'documents=path ok',
];

Future<void> main(List<String> args) async {
  final options = {
    for (final a in args.where((a) => a.startsWith('--')))
      a.substring(2, a.indexOf('=')): a.substring(a.indexOf('=') + 1),
  };
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final platform = options['platform'];
  final configuration = options['configuration'];
  if (platform == null || configuration == null || positional.length != 2) {
    stderr.writeln(
      'usage: --platform=<ios|macos> --configuration=<Debug|Release> '
      'TARGET HOST',
    );
    exit(64);
  }
  final work = Directory.systemTemp.createTempSync('add_to_app_host');
  final host = '${work.path}/host';
  _copy(Directory(requireRunfile(positional[1], what: 'The host')), host);
  exportXcframeworks(positional[0], output: '$host/Flutter');

  final derived = '${work.path}/derived';
  final udid = platform == 'ios' ? _bootedSimulator() : null;
  final build = Process.runSync('xcodebuild', [
    '-project',
    '$host/HostApp.xcodeproj',
    '-scheme',
    'HostApp',
    '-configuration',
    configuration,
    '-destination',
    if (udid != null)
      'platform=iOS Simulator,id=$udid'
    else
      'platform=macOS,arch=arm64',
    '-derivedDataPath',
    derived,
    // SwiftPM cannot sandbox the package's manifest inside the test's
    // sandbox.
    '-IDEPackageSupportDisableManifestSandbox=YES',
    // The frameworks have arm64 slices only.
    'ARCHS=arm64',
    'CODE_SIGN_IDENTITY=-',
    'build',
  ]);
  if (build.exitCode != 0) {
    stderr.writeln('xcodebuild failed:\n${build.stdout}\n${build.stderr}');
    exit(1);
  }
  print('xcodebuild built the host.');
  final products =
      '$derived/Build/Products/$configuration${udid != null ? '-iphonesimulator' : ''}';
  final screenshot =
      '${Platform.environment['TEST_UNDECLARED_OUTPUTS_DIR'] ?? work.path}/'
      'host_${platform}_$configuration.png';
  final output = udid != null
      ? await _runOnSimulator(udid, '$products/HostApp.app', screenshot)
      : await _runOnMac('$products/HostApp.app', screenshot);

  final line = output
      .split('\n')
      .firstWhere((l) => l.contains('add_to_app_results'), orElse: () => '');
  final missing = [
    for (final e in _expected)
      if (!line.contains(e)) e,
  ];
  if (missing.isNotEmpty) {
    stderr.writeln('The module did not report $missing. It reported:\n$line');
    exit(1);
  }
  print('The module reported: $line');
  print('Screenshot: $screenshot');
}

void _copy(Directory source, String destination) {
  Directory(destination).createSync(recursive: true);
  for (final entry in source.listSync()) {
    final name = entry.path.split('/').last;
    if (entry is Directory) {
      _copy(entry, '$destination/$name');
    } else {
      File(entry.resolveSymbolicLinksSync()).copySync('$destination/$name');
    }
  }
}

String _bootedSimulator() {
  final result = Process.runSync('xcrun', [
    'simctl',
    'list',
    'devices',
    'booted',
    '-j',
  ]);
  final devices =
      (jsonDecode(result.stdout.toString()) as Map<String, Object?>)['devices']!
          as Map<String, Object?>;
  for (final runtime in devices.values) {
    for (final device in runtime! as List<Object?>) {
      return (device! as Map<String, Object?>)['udid']! as String;
    }
  }
  stderr.writeln(
    'No booted iOS simulator: boot one (xcrun simctl boot <udid>).',
  );
  exit(1);
}

/// Runs [app] on simulator [udid] until it reports, and screenshots it.
Future<String> _runOnSimulator(
  String udid,
  String app,
  String screenshot,
) async {
  Process.runSync('xcrun', ['simctl', 'uninstall', udid, _bundleId]);
  final install = Process.runSync('xcrun', ['simctl', 'install', udid, app]);
  if (install.exitCode != 0) {
    stderr.writeln('simctl install failed: ${install.stderr}');
    exit(1);
  }
  final log = await Process.start('xcrun', [
    'simctl',
    'spawn',
    udid,
    'log',
    'stream',
    '--style',
    'compact',
    '--predicate',
    'process == "HostApp"',
  ]);
  try {
    final reported = _waitFor(log.stdout, 'add_to_app_results');
    final launch = Process.runSync('xcrun', [
      'simctl',
      'launch',
      udid,
      _bundleId,
    ]);
    if (launch.exitCode != 0) {
      stderr.writeln('simctl launch failed: ${launch.stderr}');
      exit(1);
    }
    final line = await reported;
    // The screen has drawn the results it reported.
    await Future<void>.delayed(const Duration(seconds: 2));
    _simulatorScreenshot(udid, screenshot);
    return line;
  } finally {
    log.kill();
    Process.runSync('xcrun', ['simctl', 'terminate', udid, _bundleId]);
  }
}

/// Saves a screenshot of simulator [udid] at [path]. A simulator with more
/// than one display (a foldable) names them in its answer; the primary one is
/// taken.
void _simulatorScreenshot(String udid, String path) {
  List<String> command([String? display]) => [
    'simctl',
    'io',
    udid,
    'screenshot',
    if (display != null) '--display=$display',
    path,
  ];
  var taken = Process.runSync('xcrun', command());
  if (taken.exitCode != 0) {
    final primary = RegExp(
      r'--display=(\S+)\s.*\(primary\)',
    ).firstMatch('${taken.stdout}${taken.stderr}');
    if (primary != null) {
      taken = Process.runSync('xcrun', command(primary.group(1)));
    }
  }
  if (taken.exitCode != 0) {
    stderr.writeln('simctl io screenshot failed: ${taken.stderr}');
    exit(1);
  }
}

/// Runs [app] on this Mac until it reports, and screenshots its window.
Future<String> _runOnMac(String app, String screenshot) async {
  final process = await Process.start('$app/Contents/MacOS/HostApp', const []);
  try {
    final host = Completer<void>();
    final lines =
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream()
          ..listen((l) {
            if (l.contains('add_to_app_host $_mixedGreeting') &&
                !host.isCompleted) {
              host.complete();
            }
          });
    final reported = _waitFor(lines, 'add_to_app_results');
    final line = await reported;
    await host.future.timeout(_timeout);
    await Future<void>.delayed(const Duration(seconds: 2));
    final window = Process.runSync('xcrun', [
      'swift',
      '-e',
      _windowOfProcess(process.pid),
    ]).stdout.toString().trim();
    if (window.isNotEmpty) {
      Process.runSync('/usr/sbin/screencapture', [
        '-x',
        '-o',
        '-l',
        window,
        screenshot,
      ]);
    }
    return line;
  } finally {
    process.kill();
  }
}

/// A Swift script printing the number of the first on-screen window of
/// process [pid], which `screencapture -l` takes.
String _windowOfProcess(int pid) =>
    '''
import CoreGraphics
let options: CGWindowListOption = [.optionOnScreenOnly]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
for w in windows as! [[String: Any]] {
  if (w[kCGWindowOwnerPID as String] as? Int) == $pid {
    print(w[kCGWindowNumber as String]!)
    break
  }
}
''';

/// The first line of [stream] containing [marker], within [_timeout].
Future<String> _waitFor(Stream<Object> stream, String marker) {
  final lines = stream is Stream<String>
      ? stream
      : (stream as Stream<List<int>>)
            .transform(utf8.decoder)
            .transform(const LineSplitter());
  return lines
      .firstWhere((l) => l.contains(marker))
      .timeout(
        _timeout,
        onTimeout: () {
          stderr.writeln(
            'Nothing reported $marker within ${_timeout.inSeconds}s.',
          );
          exit(1);
        },
      );
}
