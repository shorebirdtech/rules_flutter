/// The config an integration test rule hands the host runner is read strictly:
/// a bad value is named by its key, in a message that says what was expected.
/// A runner that read a missing `appArtifacts` as an empty list would launch
/// nothing and report a pass.
library;

import 'dart:convert';

import 'package:flutter_bazel_dev_tool/integration/integration_runner_config.dart';
import 'package:test/test.dart';

Map<String, Object?> _valid() => {
  'family': 'desktop',
  'appArtifacts': ['_main/app.zip'],
  'launcher': {'chrome': '_main/chrome'},
  'testDisplayName': '//pkg:app_test',
  'env': {'A': 'b'},
};

String _with(
  Map<String, Object?> overrides, {
  List<String> without = const [],
}) {
  final config = {..._valid(), ...overrides};
  without.forEach(config.remove);
  return json.encode(config);
}

void main() {
  test('a complete config is read in full', () {
    final config = IntegrationRunnerConfig.parse(_with({}));

    expect(config.family, IntegrationFamily.desktop);
    expect(config.appArtifacts, ['_main/app.zip']);
    expect(config.launcher, {'chrome': '_main/chrome'});
    expect(config.testDisplayName, '//pkg:app_test');
    expect(config.env, {'A': 'b'});
  });

  test('every family the rules write is one the runner knows', () {
    for (final family in ['web', 'desktop', 'ios_simulator', 'android']) {
      expect(
        IntegrationRunnerConfig.parse(_with({'family': family})).family.key,
        family,
      );
    }
  });

  group('a malformed config names the bad key', () {
    final cases = <String, ({String config, String key, String says})>{
      'a missing family': (
        config: _with({}, without: ['family']),
        key: 'family',
        says: 'non-empty string',
      ),
      'a family nobody writes': (
        config: _with({'family': 'fuchsia'}),
        key: 'family',
        says: '"web", "desktop", "ios_simulator", "android"',
      ),
      'appArtifacts that is a string': (
        config: _with({'appArtifacts': 'app.zip'}),
        key: 'appArtifacts',
        says: 'list',
      ),
      'appArtifacts that is empty': (
        config: _with({'appArtifacts': <String>[]}),
        key: 'appArtifacts',
        says: 'non-empty list',
      ),
      'appArtifacts holding a number': (
        config: _with({
          'appArtifacts': [1],
        }),
        key: 'appArtifacts',
        says: 'list',
      ),
      'a launcher that is a list': (
        config: _with({'launcher': <String>[]}),
        key: 'launcher',
        says: 'object',
      ),
      'a missing testDisplayName': (
        config: _with({}, without: ['testDisplayName']),
        key: 'testDisplayName',
        says: 'non-empty string',
      ),
      'an env with a non-string value': (
        config: _with({
          'env': {'A': 1},
        }),
        key: 'env',
        says: 'object of strings',
      ),
      'a missing env': (
        config: _with({}, without: ['env']),
        key: 'env',
        says: 'object of strings',
      ),
    };

    for (final MapEntry(:key, :value) in cases.entries) {
      test(key, () {
        expect(
          () => IntegrationRunnerConfig.parse(value.config, origin: 'c.json'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('the config c.json'),
                contains('"${value.key}"'),
                contains(value.says),
              ),
            ),
          ),
        );
      });
    }

    test('text that is not JSON, and JSON that is not an object', () {
      expect(
        () => IntegrationRunnerConfig.parse('{'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('is not JSON'),
          ),
        ),
      );
      expect(
        () => IntegrationRunnerConfig.parse('[]'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not a JSON object'),
          ),
        ),
      );
    });
  });
}
