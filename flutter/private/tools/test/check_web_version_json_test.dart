import 'dart:io';

import 'package:test/test.dart';

import '../check_web_version_json.dart';

/// What an application that sets no version reports.
const _defaults = {
  'version': Reported('1.0.0', isDefault: true),
  'build_number': Reported('1', isDefault: true),
};

List<String> _problems(
  String text, {
  Map<String, Reported> expected = _defaults,
}) => versionJsonProblems(
  text: text,
  name: 'web/version.json',
  bundle: '//app:web',
  application: '//app:app',
  expected: expected,
);

void main() {
  group('versionJsonProblems', () {
    test("accepts the application's default version", () {
      expect(
        _problems(
          '{"app_name": "app", "version": "1.0.0", "build_number": "1", '
          '"package_name": "app"}',
        ),
        isEmpty,
      );
    });

    test("accepts the version the application sets", () {
      expect(
        _problems(
          '{"version": "2.1.0", "build_number": "42"}',
          expected: const {
            'version': Reported('2.1.0', isDefault: false),
            'build_number': Reported('42', isDefault: false),
          },
        ),
        isEmpty,
      );
    });

    test('rejects a version an application without one does not report, '
        'naming both', () {
      final problems = _problems('{"version": "9.9.9", "build_number": "1"}');
      expect(problems, hasLength(1));
      final problem = problems.single;
      expect(problem, contains('//app:web'));
      expect(problem, contains('web/version.json gives `version` "9.9.9"'));
      expect(problem, contains('//app:app reports "1.0.0"'));
      expect(problem, contains('`build_name`, unset and so the default'));
      expect(problem, contains('`appBuildName`'));
    });

    test("rejects a build number that is not the application's", () {
      final problems = _problems(
        '{"version": "2.1.0", "build_number": "7"}',
        expected: const {
          'version': Reported('2.1.0', isDefault: false),
          'build_number': Reported('42', isDefault: false),
        },
      );
      expect(problems, hasLength(1));
      expect(problems.single, contains('gives `build_number` "7"'));
      expect(problems.single, contains('reports "42" (its `build_number`, as'));
      expect(problems.single, isNot(contains('default')));
    });

    test('reports both fields', () {
      expect(
        _problems('{"version": "9.9.9", "build_number": "9"}'),
        hasLength(2),
      );
    });

    test('rejects a missing field, which the app reports as empty', () {
      final problems = _problems('{"app_name": "app", "version": "1.0.0"}');
      expect(problems, hasLength(1));
      expect(problems.single, contains('gives no `build_number`'));
    });

    test('rejects a value that is not a string', () {
      final problems = _problems('{"version": "1.0.0", "build_number": 1}');
      expect(problems, hasLength(1));
      expect(problems.single, contains('`build_number` as 1, which is not'));
    });

    test('rejects text that is not a JSON object', () {
      expect(_problems('not json').single, contains('is not JSON'));
      expect(_problems('[]').single, contains('is not a JSON object'));
    });
  });

  group('run', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('web_version_json'));
    tearDown(() => dir.deleteSync(recursive: true));

    int check(String text) {
      File('${dir.path}/version.json').writeAsStringSync(text);
      return run([
        '--version-json',
        '${dir.path}/version.json',
        '--name',
        'web/version.json',
        '--bundle',
        '//app:web',
        '--application',
        '//app:app',
        '--version',
        '2.1.0',
        '--version-default',
        'false',
        '--build-number',
        '1',
        '--build-number-default',
        'true',
        '--stamp',
        '${dir.path}/stamp',
      ]);
    }

    test('writes the stamp for a file that agrees', () {
      expect(check('{"version": "2.1.0", "build_number": "1"}'), 0);
      expect(File('${dir.path}/stamp').existsSync(), isTrue);
    });

    test('writes no stamp for a file that disagrees', () {
      expect(check('{"version": "2.1.1", "build_number": "1"}'), 1);
      expect(File('${dir.path}/stamp').existsSync(), isFalse);
    });

    test('requires every option', () {
      expect(run(['--name', 'web/version.json']), 2);
    });
  });
}
