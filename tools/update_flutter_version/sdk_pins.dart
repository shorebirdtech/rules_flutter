/// The exact version pins in the pubspecs of the Flutter SDK's own packages.
///
/// `flutter_test` depends on `test_api: 0.7.12` and `matcher: 0.12.20`, not on
/// a range, so pub resolves any app that uses it to those versions. A build
/// with one copy of each package has to know them, or another lock could move
/// a package past a pin and build `flutter_test` against a version it forbids.
/// `flutter/private/versions.bzl` records them per Flutter version
/// (`FLUTTER_SDK_EXACT_PINS`).
library;

import 'package:yaml/yaml.dart';

/// A version number as pub writes an exact constraint: no operator, range,
/// caret or `any`.
final _exactVersion = RegExp(
  r'^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$',
);

/// The hosted packages each package of [pubspecs] (name to its `pubspec.yaml`
/// text) depends on exactly, by `dependencies:` entry. Packages that pin
/// nothing are left out; keys are sorted, so the result renders the same way
/// every time.
Map<String, Map<String, String>> exactPins(Map<String, String> pubspecs) {
  final pins = <String, Map<String, String>>{};
  for (final package in pubspecs.keys.toList()..sort()) {
    final yaml = loadYaml(pubspecs[package]!);
    final dependencies = yaml is YamlMap ? yaml['dependencies'] : null;
    if (dependencies is! YamlMap) continue;
    final exact = <String, String>{};
    for (final name in dependencies.keys.cast<String>().toList()..sort()) {
      final constraint = dependencies[name];
      if (constraint is String && _exactVersion.hasMatch(constraint.trim())) {
        exact[name] = constraint.trim();
      }
    }
    if (exact.isNotEmpty) pins[package] = exact;
  }
  return pins;
}

/// The entry of `FLUTTER_SDK_EXACT_PINS` for [version], as Starlark.
String renderPins(String version, Map<String, Map<String, String>> pins) {
  final out = StringBuffer('    "$version": {\n');
  for (final package in pins.keys) {
    out.writeln('        "$package": {');
    for (final entry in pins[package]!.entries) {
      out.writeln('            "${entry.key}": "${entry.value}",');
    }
    out.writeln('        },');
  }
  out.writeln('    },');
  return out.toString();
}
