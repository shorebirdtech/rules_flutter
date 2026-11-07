/// `bazel run @<hub>//swift:resolve`: pins the Swift packages a lock's Apple
/// plugins depend on, in the hub's `Package.resolved`.
///
/// As `flutter build` does with Swift Package Manager, for each of iOS and
/// macOS this lays out a package that depends on every plugin's package
/// (`FlutterGeneratedPluginSwiftPackage`), beside a stand-in for the Flutter
/// framework's package (`FlutterFramework`), which the plugins' manifests
/// name by path, and resolves it with Xcode's `swift package resolve`. The
/// two platforms' pins must agree: a build has one version of each package.
library;

import 'dart:convert';
import 'dart:io';

import 'pub_runfiles.dart';

const _config = String.fromEnvironment('rules_flutter.swift_resolve.config');

/// The deployment targets the generated package declares. Resolution does not
/// depend on them, but SwiftPM refuses a dependency whose minimum is above the
/// root package's, so they are above any plugin's.
const _platforms = <String, String>{
  'ios': '.iOS("26.0")',
  'macos': '.macOS("26.0")',
};

Never _fail(String message) {
  stderr.writeln('swift:resolve: $message');
  exit(1);
}

Future<void> main(List<String> args) async {
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null || workspace.isEmpty) {
    _fail('BUILD_WORKSPACE_DIRECTORY is not set. Use `bazel run`.');
  }
  final runfiles = Runfiles.discover(
    Platform.environment,
    Platform.resolvedExecutable,
  );
  String find(String path) =>
      runfiles.rlocation(path) ?? _fail('missing runfile $path');
  final config = jsonDecode(
    File(find(_config)).readAsStringSync(),
  ) as Map<String, dynamic>;
  final hub = config['hub'] as String;
  final output = config['output'] as String;
  if (output.isEmpty) {
    _fail(
      'the `swift_package_resolved` of `flutter_pub.from_lock(name = '
      '"$hub")` is not a file of this workspace, so there is nowhere to '
      'write it.',
    );
  }

  // Each platform's plugins: package name to its manifest's directory.
  final plugins = <String, Map<String, String>>{};
  for (final listing in (config['manifests'] as List).cast<String>()) {
    final info = jsonDecode(
      File(find(listing)).readAsStringSync(),
    ) as Map<String, dynamic>;
    final package = info['package'] as String;
    final base = listing.substring(0, listing.lastIndexOf('/'));
    final platforms = (info['platforms'] as Map).cast<String, String>();
    for (final MapEntry(key: platform, value: directory) in platforms.entries) {
      final manifest = find('$base/$directory/Package.swift');
      (plugins[platform] ??= {})[package] = File(manifest).parent.path;
    }
  }
  if (plugins.isEmpty) {
    stdout.writeln(
      'swift:resolve: no Apple plugin of @$hub has a Package.swift; '
      'nothing to resolve.',
    );
  }

  final pins = <String, Map<String, dynamic>>{};
  final pinnedBy = <String, String>{};
  final temp = Directory.systemTemp.createTempSync('swift_resolve');
  try {
    for (final MapEntry(key: platform, value: packages)
        in plugins.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      final root = Directory('${temp.path}/$platform')..createSync();
      final generated = _layOut(root, platform, packages);
      stdout.writeln(
        'swift:resolve: resolving ${packages.length} $platform plugin '
        'package(s): ${(packages.keys.toList()..sort()).join(', ')}',
      );
      final result = await Process.start(
        'xcrun',
        [
          'swift',
          'package',
          '--package-path',
          generated.path,
          '--scratch-path',
          '${temp.path}/scratch-$platform',
          'resolve',
        ],
        mode: ProcessStartMode.inheritStdio,
      );
      if (await result.exitCode != 0) {
        _fail('`swift package resolve` failed for $platform.');
      }
      final resolved = File('${generated.path}/Package.resolved');
      if (!resolved.existsSync()) continue; // nothing remote
      final data =
          jsonDecode(resolved.readAsStringSync()) as Map<String, dynamic>;
      for (final pin in (data['pins'] as List).cast<Map<String, dynamic>>()) {
        final identity = pin['identity'] as String;
        final other = pins[identity];
        if (other != null &&
            jsonEncode(other['state']) != jsonEncode(pin['state'])) {
          _fail(
            'the $platform plugins resolve `$identity` to ${pin['state']}, '
            'the ${pinnedBy[identity]} plugins to ${other['state']}. A build '
            'has one version of each package: align the plugins that '
            'depend on it.',
          );
        }
        pins[identity] = pin;
        pinnedBy[identity] = platform;
      }
    }
  } finally {
    temp.deleteSync(recursive: true);
  }

  final file = File('$workspace/$output');
  final sorted = pins.keys.toList()..sort();
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'pins': [for (final id in sorted) pins[id]],
      'version': 2,
    })}\n',
  );
  stdout.writeln('swift:resolve: wrote ${sorted.length} pin(s) to $output');
}

/// Lays out [packages] under [root] as Flutter does, and returns the
/// generated package that depends on them all.
Directory _layOut(
  Directory root,
  String platform,
  Map<String, String> packages,
) {
  for (final MapEntry(key: name, value: directory) in packages.entries) {
    final copy = Directory('${root.path}/$name')..createSync();
    File(
      '$directory/Package.swift',
    ).copySync('${copy.path}/Package.swift');
  }
  if (!packages.containsKey('FlutterFramework')) {
    final framework = Directory('${root.path}/FlutterFramework')..createSync();
    File('${framework.path}/Package.swift').writeAsStringSync('''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlutterFramework",
    products: [.library(name: "FlutterFramework", targets: ["FlutterFramework"])],
    targets: [.target(name: "FlutterFramework")]
)
''');
  }
  final generated = Directory('${root.path}/FlutterGeneratedPluginSwiftPackage')
    ..createSync();
  final names = packages.keys.toList()..sort();
  File('${generated.path}/Package.swift').writeAsStringSync('''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [${_platforms[platform]}],
    products: [
        .library(name: "FlutterGeneratedPluginSwiftPackage", type: .static, targets: ["FlutterGeneratedPluginSwiftPackage"]),
    ],
    dependencies: [
${names.map((n) => '        .package(name: "$n", path: "../$n"),').join('\n')}
    ],
    targets: [
        .target(
            name: "FlutterGeneratedPluginSwiftPackage",
            dependencies: [
${names.map((n) => '                .product(name: "${n.replaceAll('_', '-')}", package: "$n"),').join('\n')}
            ]
        ),
    ]
)
''');
  return generated;
}
