/// A hosted package's pubspec is read the way pub reads it, by rules_dart's
/// `read_pubspec`, and rules_flutter projects its `flutter:` block.
///
/// **The properties:**
///
///  1. A pubspec pub refuses (YAML that does not load, a `name` that is not
///     the package's, none, a dependency or a constraint of the wrong type)
///     fails the fetch of the package's repository, naming the package and
///     saying what pub says. It never yields a build of something else.
///  2. The `flutter:` block is read from the document, not from its layout: a
///     plugin and the assets written in YAML's flow style reach the package's
///     Android library and its files exactly as the block style does.
///
/// The workspaces are generated (`pub_inputs_fixture.dart`): a real
/// `flutter.pub()` hub over packages served from `file://`.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

String _pubspec(String name, String body) =>
    'name: $name\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n$body';

void main() {
  group('a pubspec pub refuses', () {
    // Package name to the pubspec in its archive, and what pub says.
    final refused = <String, (String, String)>{
      'bad_yaml': (
        'name: bad_yaml\ndependencies: [unclosed\n',
        'pub would refuse',
      ),
      'other_name': ('name: someone_else\n', "doesn't match expected name"),
      'unnamed': ('version: 1.0.0\n', 'Missing the required "name" field'),
      'empty': ('', 'Missing the required "name" field'),
      'list_deps': (
        'name: list_deps\ndependencies: [a, b]\n',
        '"dependencies" field must be a map',
      ),
      'numeric_sdk': (
        'name: numeric_sdk\nenvironment:\n  sdk: 3\n',
        'A version constraint must be a string',
      ),
      'self_dep': (
        'name: self_dep\ndependencies:\n  self_dep: any\n',
        'may not list itself as a dependency',
      ),
    };
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          for (final entry in refused.entries)
            HostedPackage(entry.key, pubspec: entry.value.$1),
        ],
      ).materialize();
    });

    for (final entry in refused.entries) {
      test('${entry.key} fails the fetch, naming the package', () async {
        final result = await ws.loadSpoke(entry.key);
        expect(result.succeeded, isFalse, reason: 'built from it:\n$result');
        expect(
          refusedAtFetch(result),
          isTrue,
          reason: 'the failure should be the fetch refusing it:\n$result',
        );
        expect(
          namesPackage(result.output, entry.key),
          isTrue,
          reason: 'the refusal does not name the package:\n$result',
        );
        expect(
          result.output,
          contains(entry.value.$2),
          reason: 'the refusal does not say what pub says:\n$result',
        );
      });
    }
  });

  group('the flutter block in YAML flow style', () {
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          HostedPackage(
            'flow_assets',
            pubspec: _pubspec(
              'flow_assets',
              'flutter: {assets: [assets/a.txt, {path: assets/b.txt}], '
                  'fonts: [{family: F, fonts: [{asset: fonts/f.ttf, weight: 700}]}]}\n',
            ),
            files: {
              'assets/a.txt': 'a',
              'assets/b.txt': 'b',
              'fonts/f.ttf': 'f',
            },
          ),
          HostedPackage(
            'flow_plugin',
            pubspec: _pubspec(
              'flow_plugin',
              'flutter: {plugin: {platforms: {android: '
                  '{package: dev.example.flow_plugin, pluginClass: Plugin}}}}\n',
            ),
            files: {
              'android/src/main/kotlin/dev/example/Plugin.kt':
                  'package dev.example\nclass Plugin\n',
            },
          ),
        ],
      ).materialize();
    });

    test('declares its assets and fonts under their names', () async {
      final build = await ws.bazel([
        'query',
        '--output=build',
        '@pubhub__flow_assets//:flow_assets',
      ]);
      expect(build.succeeded, isTrue, reason: '$build');
      for (final file in ['assets/a.txt', 'assets/b.txt', 'fonts/f.ttf']) {
        expect(build.output, contains(file), reason: '$build');
      }
    });

    test('registers its Android plugin', () async {
      expect((await ws.loadSpoke('flow_plugin')).succeeded, isTrue);
      final dir = await ws.spokeDirectory('flow_plugin');
      final build = File(
        p.join(dir.path, 'android', 'BUILD.bazel'),
      ).readAsStringSync();
      expect(build, contains('custom_package = "dev.example.flow_plugin"'));
    });
  });
}
