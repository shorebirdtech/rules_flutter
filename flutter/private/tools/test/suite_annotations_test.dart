// Reading a test file's library `@Tags`, as `flutter test` reads them.
import 'package:flutter_rule_tools/suite_annotations.dart';
import 'package:test/test.dart';

void main() {
  group('libraryTags', () {
    test('reads a list of tags', () {
      expect(
        libraryTags('a_test.dart', '''
@Tags(['a', 'b'])
library;

import 'package:test/test.dart';

void main() {}
'''),
        {'a', 'b'},
      );
    });

    test('reads an import-prefixed annotation', () {
      expect(
        libraryTags('a_test.dart', '''
@test.Tags(['a'])
library;

import 'package:test/test.dart' as test;

void main() {}
'''),
        {'a'},
      );
    });

    test('a file with no annotation has no tags', () {
      expect(libraryTags('a_test.dart', 'void main() {}\n'), isEmpty);
    });

    test('a file with the other annotations still parses', () {
      expect(
        libraryTags('a_test.dart', '''
@TestOn('vm')
@OnPlatform({'windows': Skip('no')})
@Tags(['a'])
library;

import 'package:test/test.dart';

void main() {}
'''),
        {'a'},
      );
    });

    test('a file without main is refused', () {
      expect(
        () => libraryTags('a_test.dart', '''
@Tags(['a'])
library;

import 'package:test/test.dart';
'''),
        throwsFormatException,
      );
    });

    test('tags that are not strings are refused', () {
      expect(
        () => libraryTags('a_test.dart', '''
@Tags([1])
library;

import 'package:test/test.dart';

void main() {}
'''),
        throwsFormatException,
      );
    });
  });
}
