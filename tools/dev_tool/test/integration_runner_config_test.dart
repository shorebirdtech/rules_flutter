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
  'source': '_main/pkg/t_test.dart',
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
    expect(config.source, '_main/pkg/t_test.dart');
    expect(config.includeTags, isEmpty);
    expect(config.excludeTags, isEmpty);
  });

  test('tag selectors are read as given', () {
    final config = IntegrationRunnerConfig.parse(
      _with({
        'includeTags': ['a', 'b || c'],
        'excludeTags': ['flaky'],
      }),
    );

    expect(config.includeTags, ['a', 'b || c']);
    expect(config.excludeTags, ['flaky']);
  });

  test('a source that is missing or empty, or tags that are not lists of '
      'strings, name their key', () {
    for (final (config, key) in [
      (_with({}, without: ['source']), 'source'),
      (_with({'source': ''}), 'source'),
      (_with({'includeTags': 'a'}), 'includeTags'),
      (
        _with({
          'excludeTags': [1],
        }),
        'excludeTags',
      ),
    ]) {
      expect(
        () => IntegrationRunnerConfig.parse(config),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('"$key"'),
          ),
        ),
      );
    }
  });

  test('a test without a golden comparator has none, and one with it names '
      'the service, what it is started with and the test\'s source', () {
    expect(IntegrationRunnerConfig.parse(_with({})).goldens, isNull);

    final goldens = IntegrationRunnerConfig.parse(
      _with({
        'goldens': {
          'executable': '_main/__t_goldens',
          'environment': {'FLUTTER_TEST_DILL': '_main/g.dill'},
          'testSource': 'pkg/t_test.dart',
        },
      }),
    ).goldens!;

    expect(goldens.executable, '_main/__t_goldens');
    expect(goldens.environment, {'FLUTTER_TEST_DILL': '_main/g.dill'});
    expect(goldens.testSource, 'pkg/t_test.dart');
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
      'goldens that is a list': (
        config: _with({'goldens': <String>[]}),
        key: 'goldens',
        says: 'object',
      ),
      'goldens without an executable': (
        config: _with({
          'goldens': {
            'environment': <String, String>{},
            'testSource': 't.dart',
          },
        }),
        key: 'goldens.executable',
        says: 'non-empty string',
      ),
      'goldens without the test\'s source': (
        config: _with({
          'goldens': {'executable': 'x', 'environment': <String, String>{}},
        }),
        key: 'goldens.testSource',
        says: 'non-empty string',
      ),
      'goldens with an environment of numbers': (
        config: _with({
          'goldens': {
            'executable': 'x',
            'testSource': 't.dart',
            'environment': {'A': 1},
          },
        }),
        key: 'goldens.environment',
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

  group('the browser of a web test', () {
    test('is the runfiles path the runner named', () {
      final config = IntegrationRunnerConfig.parse(
        _with({'family': 'web'}),
      );

      expect(config.chromePath, '_main/chrome');
    });

    for (final launcher in <Map<String, Object?>>[
      {},
      {'chrome': ''},
      {'chrome': 7},
    ]) {
      test('a launcher of ${json.encode(launcher)} names launcher.chrome', () {
        final config = IntegrationRunnerConfig.parse(
          _with({'family': 'web', 'launcher': launcher}),
        );

        expect(
          () => config.chromePath,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('"launcher.chrome"'),
                contains('non-empty string'),
              ),
            ),
          ),
        );
      });
    }
  });

  group('the adb of an Android test', () {
    test('is the runfiles path the runner named', () {
      final config = IntegrationRunnerConfig.parse(
        _with({
          'family': 'android',
          'launcher': {'adb': '_main/external/androidsdk/platform-tools/adb'},
        }),
      );

      expect(config.adbPath, '_main/external/androidsdk/platform-tools/adb');
    });

    for (final launcher in <Map<String, Object?>>[
      {},
      {'adb': ''},
      {'adb': 7},
    ]) {
      test('a launcher of ${json.encode(launcher)} names launcher.adb', () {
        final config = IntegrationRunnerConfig.parse(
          _with({'family': 'android', 'launcher': launcher}),
        );

        expect(
          () => config.adbPath,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('"launcher.adb"'), contains('non-empty string')),
            ),
          ),
        );
      });
    }
  });

  group('the simulator of an iOS test', () {
    Map<String, Object?> iosConfig(Map<String, Object?> launcher) =>
        _valid()..addAll({'family': 'ios_simulator', 'launcher': launcher});

    test('is the device type and the runtime the runner named', () {
      final config = IntegrationRunnerConfig.parse(
        json.encode(
          iosConfig({'deviceType': 'iPhone 16', 'runtime': 'iOS 27.2'}),
        ),
      );

      expect(config.simulatorDeviceType, 'iPhone 16');
      expect(config.simulatorRuntime, 'iOS 27.2');
    });

    test('may name no runtime, which is the newest installed', () {
      final config = IntegrationRunnerConfig.parse(
        json.encode(iosConfig({'deviceType': 'iPhone 16', 'runtime': ''})),
      );

      expect(config.simulatorRuntime, '');
    });

    for (final launcher in <Map<String, Object?>>[
      {'runtime': ''},
      {'deviceType': '', 'runtime': ''},
      {'deviceType': 3, 'runtime': ''},
    ]) {
      test(
        'a launcher of ${json.encode(launcher)} names launcher.deviceType',
        () {
          final config = IntegrationRunnerConfig.parse(
            json.encode(iosConfig(launcher)),
          );

          expect(
            () => config.simulatorDeviceType,
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('"launcher.deviceType"'),
                  contains('non-empty string'),
                ),
              ),
            ),
          );
        },
      );
    }

    for (final launcher in <Map<String, Object?>>[
      {'deviceType': 'iPhone 16'},
      {'deviceType': 'iPhone 16', 'runtime': 9},
    ]) {
      test('a launcher of ${json.encode(launcher)} names launcher.runtime', () {
        final config = IntegrationRunnerConfig.parse(
          json.encode(iosConfig(launcher)),
        );

        expect(
          () => config.simulatorRuntime,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('"launcher.runtime"'), contains('string')),
            ),
          ),
        );
      });
    }
  });
}
