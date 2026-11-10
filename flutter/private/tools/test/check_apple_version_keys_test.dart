import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../check_apple_version_keys.dart';

/// The version keys of `ios/Runner/Info.plist` and `macos/Runner/Info.plist`
/// exactly as `flutter create` writes them (both templates agree), around
/// keys that are not the check's business.
const _flutterCreate = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>app</string>
	<key>CFBundleShortVersionString</key>
	<string>\$(FLUTTER_BUILD_NAME)</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>\$(FLUTTER_BUILD_NUMBER)</string>
</dict>
</plist>
''';

String _plist(String body) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$body
</dict>
</plist>
''';

/// `plutil -convert binary1` of a plist whose CFBundleShortVersionString is
/// "3.1" and whose CFBundleVersion is "$(FLUTTER_BUILD_NUMBER)".
const _binaryLiteralName =
    '62706c6973743030d2010203045f101a434642756e646c6553686f727456657273696f6e'
    '537472696e675f100f434642756e646c6556657273696f6e53332e315f10172428464c55'
    '545445525f4255494c445f4e554d42455229080d2a3c4000000000000001010000000000'
    '0000050000000000000000000000000000005a';

/// The same with CFBundleVersion the integer 7.
const _binaryIntegerNumber =
    '62706c6973743030d2010203045f101a434642756e646c6553686f727456657273696f6e'
    '537472696e675f100f434642756e646c6556657273696f6e53332e311007080d2a3c4000'
    '00000000000101000000000000000500000000000000000000000000000042';

Uint8List _hex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

/// The version file an app with the default `build_name` and `build_number`
/// gives rules_apple.
const _defaultVersion = {
  'build_version': '1',
  'short_version_string': '1.0.0',
};

List<String> _problems(
  Object plist, {
  Map<String, Object?> version = _defaultVersion,
}) => versionKeyProblems(
  bytes: plist is Uint8List
      ? plist
      : Uint8List.fromList((plist as String).codeUnits),
  name: 'ios/Runner/Info.plist',
  app: '//app:app',
  rule: 'flutter_ios_app',
  version: version,
);

void main() {
  group('versionKeyProblems', () {
    test("accepts flutter create's plist", () {
      expect(_problems(_flutterCreate), isEmpty);
    });

    test('accepts a plist without the keys', () {
      expect(
        _problems(_plist('<key>CFBundleName</key><string>app</string>')),
        isEmpty,
      );
    });

    test('accepts the braced spelling of the variables', () {
      expect(
        _problems(
          _plist(
            '<key>CFBundleShortVersionString</key><string>\${FLUTTER_BUILD_NAME}</string>'
            '<key>CFBundleVersion</key><string>\${FLUTTER_BUILD_NUMBER}</string>',
          ),
        ),
        isEmpty,
      );
    });

    test('names the plist, key, value and what to set for a literal name', () {
      final problems = _problems(
        _flutterCreate.replaceFirst('\$(FLUTTER_BUILD_NAME)', '3.1'),
      );
      expect(problems, hasLength(1));
      expect(problems.single, contains('ios/Runner/Info.plist'));
      expect(problems.single, contains('CFBundleShortVersionString'));
      expect(problems.single, contains('"3.1"'));
      expect(problems.single, contains('`build_name`'));
      expect(problems.single, contains('`version`'));
      expect(problems.single, contains('flutter_ios_app'));
      expect(problems.single, contains('//app:app'));
    });

    test('names build_number for a literal build version', () {
      final problems = _problems(
        _flutterCreate.replaceFirst('\$(FLUTTER_BUILD_NUMBER)', '42'),
      );
      expect(problems, hasLength(1));
      expect(problems.single, contains('CFBundleVersion to "42"'));
      expect(problems.single, contains('`build_number`'));
    });

    test('reports both keys', () {
      final problems = _problems(
        _flutterCreate
            .replaceFirst('\$(FLUTTER_BUILD_NAME)', '3.1')
            .replaceFirst('\$(FLUTTER_BUILD_NUMBER)', '42'),
      );
      expect(problems, hasLength(2));
    });

    test("accepts Xcode's own version variables", () {
      expect(
        _problems(
          _plist(
            '<key>CFBundleShortVersionString</key><string>\$(MARKETING_VERSION)</string>'
            '<key>CFBundleVersion</key><string>\${CURRENT_PROJECT_VERSION}</string>',
          ),
        ),
        isEmpty,
      );
    });

    test('rejects a variable that is not a version', () {
      final problems = _problems(
        _flutterCreate.replaceFirst(
          '\$(FLUTTER_BUILD_NAME)',
          '\$(PRODUCT_NAME)',
        ),
      );
      expect(problems.single, contains(r'"$(PRODUCT_NAME)"'));
    });

    test("accepts literals that are the app's version", () {
      expect(
        _problems(
          _flutterCreate
              .replaceFirst('\$(FLUTTER_BUILD_NAME)', '3.1.0')
              .replaceFirst('\$(FLUTTER_BUILD_NUMBER)', '42'),
          version: {'build_version': '42', 'short_version_string': '3.1.0'},
        ),
        isEmpty,
      );
    });

    test('rejects a literal the version would change, naming both', () {
      final problems = _problems(
        _flutterCreate.replaceFirst('\$(FLUTTER_BUILD_NAME)', '3.1'),
        version: {'build_version': '1', 'short_version_string': '3.1.0'},
      );
      expect(problems.single, contains('"3.1"'));
      expect(problems.single, contains('"3.1.0"'));
    });

    test('accepts a literal in a key the version leaves alone', () {
      // rules_apple sets only the keys its version file names, so a
      // `apple_bundle_version` without `short_version_string` keeps the
      // plist's CFBundleShortVersionString.
      expect(
        _problems(
          _flutterCreate.replaceFirst('\$(FLUTTER_BUILD_NAME)', '3.1'),
          version: {'build_version': '7'},
        ),
        isEmpty,
      );
    });

    test('rejects an empty value and a value that is not a string', () {
      expect(
        _problems(
          _flutterCreate.replaceFirst(
            '<string>\$(FLUTTER_BUILD_NAME)</string>',
            '<string/>',
          ),
        ),
        hasLength(1),
      );
      final problems = _problems(
        _flutterCreate.replaceFirst(
          '<string>\$(FLUTTER_BUILD_NUMBER)</string>',
          '<integer>7</integer>',
        ),
      );
      expect(problems.single, contains('<integer>7</integer>'));
    });

    test('reads entities in a literal', () {
      final problems = _problems(
        _flutterCreate.replaceFirst('\$(FLUTTER_BUILD_NAME)', '1&amp;2'),
      );
      expect(problems.single, contains('"1&2"'));
    });

    test('reads a binary plist', () {
      final problems = _problems(_hex(_binaryLiteralName));
      expect(problems, hasLength(1));
      expect(problems.single, contains('CFBundleShortVersionString'));
      expect(problems.single, contains('"3.1"'));
    });

    test('reads a binary plist whose value is not a string', () {
      final problems = _problems(_hex(_binaryIntegerNumber));
      expect(problems, hasLength(2));
      expect(problems.last, contains('<integer>7</integer>'));
    });
  });

  group('run', () {
    late Directory dir;
    setUp(
      () => dir = Directory.systemTemp.createTempSync('apple_version_keys'),
    );
    tearDown(() => dir.deleteSync(recursive: true));

    int check(String plistText, {String name = 'macos/Runner/Info.plist'}) {
      File('${dir.path}/Info.plist').writeAsStringSync(plistText);
      File(
        '${dir.path}/version.json',
      ).writeAsStringSync(
        '{"build_version": "42", "short_version_string": "3.1.0"}',
      );
      return run([
        '--version-file',
        '${dir.path}/version.json',
        '--plist',
        '${dir.path}/Info.plist',
        '--name',
        name,
        '--app',
        '//app:app',
        '--rule',
        'flutter_macos_app',
        '--stamp',
        '${dir.path}/stamp',
      ]);
    }

    test('writes the stamp for a good plist', () {
      expect(check(_flutterCreate), 0);
      expect(File('${dir.path}/stamp').existsSync(), isTrue);
    });

    test('writes no stamp for a literal', () {
      expect(
        check(_flutterCreate.replaceFirst('\$(FLUTTER_BUILD_NAME)', '3.1')),
        1,
      );
      expect(File('${dir.path}/stamp').existsSync(), isFalse);
    });

    test("reads the app's version from the version file", () {
      expect(
        check(_flutterCreate.replaceFirst('\$(FLUTTER_BUILD_NUMBER)', '42')),
        0,
      );
      expect(
        check(_flutterCreate.replaceFirst('\$(FLUTTER_BUILD_NUMBER)', '43')),
        1,
      );
    });

    test('fails on text that is not a plist', () {
      expect(check('not a plist'), 1);
    });
  });
}
