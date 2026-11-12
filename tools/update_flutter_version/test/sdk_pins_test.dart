import 'package:test/test.dart';

import '../sdk_pins.dart';

void main() {
  test(
    'exact versions in dependencies are pins, ranges and others are not',
    () {
      final pins = exactPins({
        'flutter_test': '''
name: flutter_test
dependencies:
  flutter:
    sdk: flutter
  test_api: 0.7.12
  matcher: 0.12.20
  path: ^1.9.0
  meta: ">=1.0.0 <2.0.0"
  clock: any
dev_dependencies:
  fake: 1.2.3
''',
        'flutter': '''
name: flutter
dependencies:
  material_color_utilities: 0.13.0
  vector_math: ^2.4.0
''',
        'integration_test': 'name: integration_test\ndependencies:\n  flutter:\n    sdk: flutter\n',
        'broken': 'name: broken\n',
        'flutter_tools': 'name: flutter_tools\ndependencies:\n  args: 2.7.0\n',
      });

      expect(pins, {
        'flutter': {'material_color_utilities': '0.13.0'},
        'flutter_test': {'matcher': '0.12.20', 'test_api': '0.7.12'},
      });
    },
  );

  test('a prerelease or build suffix is still exact', () {
    final pins = exactPins({
      'a': 'name: a\ndependencies:\n  b: 1.0.0-dev.1\n  c: 2.0.0+3\n',
    });
    expect(pins['a'], {'b': '1.0.0-dev.1', 'c': '2.0.0+3'});
  });

  test('packages render as the sorted Starlark entry of versions.bzl', () {
    expect(
      renderPackages('3.47.9', ['integration_test', 'flutter', 'flutter_test']),
      '    "3.47.9": [\n'
      '        "flutter",\n'
      '        "flutter_test",\n'
      '        "integration_test",\n'
      '    ],\n',
    );
  });

  test('pins render as the Starlark entry of versions.bzl', () {
    expect(
      renderPins('3.47.9', {
        'flutter_test': {'matcher': '0.12.20', 'test_api': '0.7.12'},
      }),
      '    "3.47.9": {\n'
      '        "flutter_test": {\n'
      '            "matcher": "0.12.20",\n'
      '            "test_api": "0.7.12",\n'
      '        },\n'
      '    },\n',
    );
  });
}
