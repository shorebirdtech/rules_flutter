// Reading a test file's library annotations, as `flutter test` reads them.
import 'package:flutter_rule_tools/suite_annotations.dart';
import 'package:test/test.dart';

SuiteAnnotations _parse(String annotations) => SuiteAnnotations.parse(
  'a_test.dart',
  '''
$annotations
library;

import 'package:test/test.dart';

void main() {}
''',
);

void main() {
  group('tags', () {
    test('reads a list of tags', () {
      expect(_parse("@Tags(['a', 'b'])").tags, {'a', 'b'});
    });

    test('reads an import-prefixed annotation', () {
      final annotations = SuiteAnnotations.parse('a_test.dart', '''
@test.Tags(['a'])
library;

import 'package:test/test.dart' as test;

void main() {}
''');
      expect(annotations.tags, {'a'});
    });

    test('a file with no annotation has no tags', () {
      expect(
        SuiteAnnotations.parse('a_test.dart', 'void main() {}\n').tags,
        isEmpty,
      );
    });

    test('a file with the other annotations still parses', () {
      final annotations = _parse('''
@TestOn('vm')
@OnPlatform({'windows': Skip('no')})
@Tags(['a'])''');
      expect(annotations.tags, {'a'});
    });

    test('a file without main is refused', () {
      expect(
        () => SuiteAnnotations.parse('a_test.dart', '''
@Tags(['a'])
library;

import 'package:test/test.dart';
'''),
        throwsFormatException,
      );
    });

    test('tags that are not strings are refused', () {
      expect(() => _parse('@Tags([1])'), throwsFormatException);
    });

    test('a @TestOn selector that names no platform is refused', () {
      expect(
        () => _parse("@TestOn('no-such-platform')"),
        throwsFormatException,
      );
    });
  });

  group('@Skip', () {
    test('reaches the handshake with its reason', () {
      final metadata = _parse("@Skip('not here')").handshakeMetadata('60');
      expect(metadata['skip'], isTrue);
      expect(metadata['skipReason'], 'not here');
    });

    test('a bare @Skip has no reason', () {
      final metadata = _parse('@Skip()').handshakeMetadata('60');
      expect(metadata['skip'], isTrue);
      expect(metadata['skipReason'], isNull);
    });

    test('no annotation skips nothing', () {
      expect(_parse('').handshakeMetadata('60')['skip'], isNull);
    });
  });

  group('@OnPlatform', () {
    test('reaches the handshake for the program to resolve', () {
      final metadata = _parse("@OnPlatform({'mac-os': Skip('mac')})")
          .handshakeMetadata('60');
      final onPlatform = metadata['onPlatform']! as List;
      expect(onPlatform, hasLength(1));
      expect((onPlatform.single as List).first, 'mac-os');
      expect(((onPlatform.single as List).last as Map)['skip'], isTrue);
    });

    test('a selector that names no platform is refused', () {
      expect(
        () => _parse("@OnPlatform({'no-such-platform': Skip()})"),
        throwsFormatException,
      );
    });
  });

  group('@TestOn', () {
    test('a selector that matches the host excludes nothing', () {
      expect(_parse("@TestOn('vm')").exclusion, isNull);
    });

    test('no selector excludes nothing', () {
      expect(_parse('').exclusion, isNull);
    });

    test('a selector that does not match names itself and the platform', () {
      final exclusion = _parse("@TestOn('browser')").exclusion;
      expect(exclusion, contains('@TestOn("browser")'));
      expect(exclusion, contains('vm on '));
    });

    test('the platform is the host operating system', () {
      // The host is one of these three, so the union matches it and the
      // complement cannot.
      expect(_parse("@TestOn('windows || linux || mac-os')").exclusion, isNull);
      expect(
        _parse("@TestOn('!windows && !linux && !mac-os')").exclusion,
        isNotNull,
      );
    });
  });

  group('@Timeout', () {
    Object timeoutOf(String annotations, String? bazel) =>
        _parse(annotations).handshakeMetadata(bazel)['timeout']!;

    Duration? durationOf(Object serialized) => serialized is Map
        ? Duration(microseconds: serialized['duration']! as int)
        : null;

    test('without one, Bazel\'s limit stands', () {
      expect(durationOf(timeoutOf('', '120')), const Duration(seconds: 120));
    });

    test('a duration replaces Bazel\'s limit', () {
      expect(
        durationOf(timeoutOf('@Timeout(Duration(seconds: 5))', '120')),
        const Duration(seconds: 5),
      );
    });

    test('a factor scales Bazel\'s limit', () {
      expect(
        durationOf(timeoutOf('@Timeout.factor(2)', '120')),
        const Duration(seconds: 240),
      );
    });

    test('Timeout.none removes the limit', () {
      expect(timeoutOf('@Timeout.none', '120'), 'none');
    });

    test('outside Bazel there is no limit', () {
      expect(timeoutOf('', null), 'none');
    });

    test('outside Bazel a duration still applies', () {
      expect(
        durationOf(timeoutOf('@Timeout(Duration(seconds: 5))', null)),
        const Duration(seconds: 5),
      );
    });
  });

  group('mergeTimeout', () {
    test('is Timeout.merge when Bazel states a limit', () {
      const library = Timeout.factor(3);
      expect(
        mergeTimeout('10', library),
        const Timeout(Duration(seconds: 10)).merge(library),
      );
    });

    test('ignores a zero or unreadable limit', () {
      expect(mergeTimeout('0', const Timeout.factor(1)), Timeout.none);
      expect(mergeTimeout('x', const Timeout.factor(1)), Timeout.none);
    });
  });
}
