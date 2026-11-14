/// Reads the defines of one target of a plugin's `Package.swift`, evaluated
/// for the app being built (`swiftpm_app_settings.bzl`).
///
/// The build evaluates the manifest with `swift package dump-package` twice:
/// once when it fetches the plugin, which the plugin's library is built from,
/// and once per app, in an action, which only the defines are taken from.
/// This compares the two: they may differ in their `.define` settings and in
/// nothing else, since the sources, header search paths, dependencies and
/// linker settings of the library are fixed when the build is analysed. Any
/// other difference fails, naming it.
///
/// It writes the target's defines for one platform and SwiftPM configuration:
/// a header of `#define`s, which each C-family compile of the target includes
/// first, and a response file of `-D` flags for its Swift compile.
///
///     dart swiftpm_app_settings.dart --dump <app.json> --reference <fetch.json>
///         --target <name> --platform ios|macos --configuration debug|release
///         --package <pub package> --manifest <path, for messages>
///         --header <out.h> --swift-params <out.params>
library;

import 'dart:convert';
import 'dart:io';

/// What a target's defines come to.
class TargetDefines {
  /// Creates the defines.
  const TargetDefines({required this.clang, required this.swift});

  /// The C, C++ and Objective-C defines, as `NAME` or `NAME=VALUE`.
  final List<String> clang;

  /// The Swift conditions.
  final List<String> swift;

  /// The header the C-family compiles include.
  String get header {
    final lines = [
      '// The defines of this target, from its Package.swift as evaluated for',
      '// the app being built. Written by rules_flutter.',
      '#pragma once',
      for (final define in clang) _defineLine(define),
    ];
    return '${lines.join('\n')}\n';
  }

  /// The response file of the Swift compile: one flag a line.
  String get swiftParams => swift.map((name) => '-D$name\n').join();

  static String _defineLine(String define) {
    final at = define.indexOf('=');
    if (at < 0) return '#define $define 1';
    return '#define ${define.substring(0, at)} ${define.substring(at + 1)}';
  }
}

/// Thrown when the app's evaluation differs from the fetch-time one in more
/// than its defines.
class ManifestMismatch implements Exception {
  /// Creates the failure.
  ManifestMismatch(this.differences);

  /// What differs, one entry each.
  final List<String> differences;

  @override
  String toString() => differences.join('\n');
}

/// The defines of [target] for [platform] and [configuration] in [dump],
/// after checking [dump] against [reference].
///
/// Throws [ManifestMismatch] when they differ in anything but defines, and
/// [FormatException] when [target] is not in [dump].
TargetDefines targetDefines({
  required Map<String, Object?> dump,
  required Map<String, Object?> reference,
  required String target,
  required String platform,
  required String configuration,
}) {
  final differences = <String>[];
  _compare(_withoutDefines(reference), _withoutDefines(dump), '', differences);
  if (differences.isNotEmpty) throw ManifestMismatch(differences);

  final targets = (dump['targets'] as List<Object?>? ?? const [])
      .cast<Map<String, Object?>>();
  final found = targets.where((t) => t['name'] == target).toList();
  if (found.isEmpty) {
    throw FormatException('the manifest has no target `$target`');
  }
  final clang = <String>[];
  final swift = <String>[];
  for (final setting
      in (found.single['settings'] as List<Object?>? ?? const [])
          .cast<Map<String, Object?>>()) {
    final define = _define(setting);
    if (define == null || !_applies(setting, platform, configuration)) {
      continue;
    }
    // SwiftPM gives a target's C and C++ defines to each of its C-family
    // compiles.
    final into = setting['tool'] == 'swift' ? swift : clang;
    if (!into.contains(define)) into.add(define);
  }
  return TargetDefines(clang: clang, swift: swift);
}

String? _define(Map<String, Object?> setting) {
  final kind = setting['kind'];
  if (kind is! Map || kind['define'] is! Map) return null;
  return (kind['define'] as Map)['_0'] as String?;
}

bool _applies(
  Map<String, Object?> setting,
  String platform,
  String configuration,
) {
  final condition = setting['condition'];
  if (condition is! Map) return true;
  final platforms = condition['platformNames'];
  if (platforms is List &&
      platforms.isNotEmpty &&
      !platforms.contains(platform)) {
    return false;
  }
  final config = condition['config'];
  return config == null || config == configuration;
}

/// [dump] without what may differ: its defines, and the paths of where it
/// was evaluated (the package's directory, and a local dependency's, which
/// SwiftPM makes absolute).
Object? _withoutDefines(Map<String, Object?> dump) {
  final copy = jsonDecode(jsonEncode(dump)) as Map<String, Object?>
    ..remove('packageKind');
  for (final target
      in (copy['targets'] as List<Object?>? ?? const [])
          .cast<Map<String, Object?>>()) {
    final settings = target['settings'];
    if (settings is List) {
      settings.removeWhere(
        (s) => s is Map<String, Object?> && _define(s) != null,
      );
    }
  }
  for (final dependency
      in (copy['dependencies'] as List<Object?>? ?? const [])
          .cast<Map<String, Object?>>()) {
    for (final entry
        in (dependency['fileSystem'] as List<Object?>? ?? const [])
            .cast<Map<String, Object?>>()) {
      entry.remove('path');
    }
  }
  return copy;
}

void _compare(Object? before, Object? after, String at, List<String> out) {
  if (before is Map && after is Map) {
    for (final key in {...before.keys, ...after.keys}) {
      final name = _key(before, key) ?? _key(after, key) ?? '$key';
      _compare(before[key], after[key], at.isEmpty ? name : '$at.$name', out);
    }
  } else if (before is List && after is List) {
    if (before.length != after.length) {
      out.add(
        '$at: ${jsonEncode(before)} at fetch time, '
        '${jsonEncode(after)} for the app',
      );
      return;
    }
    for (var i = 0; i < before.length; i++) {
      final item = before[i];
      final label = item is Map && item['name'] is String
          ? '${item['name']}'
          : '$i';
      _compare(before[i], after[i], '$at[$label]', out);
    }
  } else if (jsonEncode(before) != jsonEncode(after)) {
    out.add(
      '$at: ${jsonEncode(before)} at fetch time, '
      '${jsonEncode(after)} for the app',
    );
  }
}

String? _key(Map<Object?, Object?> map, Object? key) =>
    map.containsKey(key) ? '$key' : null;

Map<String, String> _parse(List<String> args) {
  final values = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (!args[i].startsWith('--') || i + 1 >= args.length) {
      throw ArgumentError('unexpected argument ${args[i]}');
    }
    values[args[i].substring(2)] = args[i + 1];
  }
  return values;
}

Map<String, Object?> _read(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

void main(List<String> args) {
  final options = _parse(args);
  final package = options['package']!;
  final manifest = options['manifest']!;
  final TargetDefines defines;
  try {
    defines = targetDefines(
      dump: _read(options['dump']!),
      reference: _read(options['reference']!),
      target: options['target']!,
      platform: options['platform']!,
      configuration: options['configuration']!,
    );
  } on ManifestMismatch catch (e) {
    stderr.writeln(
      'package:$package: its $manifest, evaluated for this app, differs '
      'from its evaluation when the package was fetched in more than its '
      'defines:\n    ${e.differences.join('\n    ')}\n'
      'rules_flutter builds an Apple plugin as the fetch-time evaluation '
      'describes it, and takes only the defines from the evaluation for each '
      'app. Give $package a plugin overlay (`flutter_pub.plugin_overlays` in '
      'MODULE.bazel) that builds it for your app with '
      '`flutter_apple_plugin_library`.',
    );
    exit(1);
  } on FormatException catch (e) {
    stderr.writeln('package:$package: $manifest: ${e.message}');
    exit(1);
  }
  File(options['header']!).writeAsStringSync(defines.header);
  File(options['swift-params']!).writeAsStringSync(defines.swiftParams);
}
