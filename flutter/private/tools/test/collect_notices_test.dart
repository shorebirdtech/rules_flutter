// Expectations are flutter_tools' `LicenseCollector.obtainLicenses`
// (`packages/flutter_tools/lib/src/license_collector.dart`, 3.47.9), worked out
// by hand; the line each case follows is named beside it.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../collect_notices.dart';

final sep = licenseSeparator; // '\n' + 80 hyphens + '\n' (:32)

PackageLicence lic(String package, String text) =>
    PackageLicence(package, '$package/LICENSE', text);

void main() {
  test('the separator is the one the framework splits at', () {
    expect(sep, '\n${'-' * 80}\n');
    expect('-' * 80, hasLength(80));
  });

  group('mergeNotices', () {
    test('a one-component file is named by its package, text untrimmed', () {
      // :72-75
      expect(mergeNotices([lic('foo', 'MIT\n')], []), 'foo\n\nMIT\n');
    });

    test('a one-component file with a blank line is still all text', () {
      // :65 needs more than one component before it looks for a name block.
      expect(
        mergeNotices([lic('foo', 'Copyright\n\nPermission')], []),
        'foo\n\nCopyright\n\nPermission',
      );
    });

    test('a multi-component file names each component by its header', () {
      // :65-70
      final file = 'a\nb\n\nText one${sep}c\n\nText two';
      expect(
        mergeNotices([lic('foo', file)], []),
        'a\nb\n\nText one${sep}c\n\nText two',
      );
    });

    test('a component of a multi-component file without a blank line is '
        'named by the package', () {
      // :72-75
      final file = 'a\n\nText one${sep}no blank line';
      expect(
        mergeNotices([lic('foo', file)], []),
        'a\n\nText one${sep}foo\n\nno blank line',
      );
    });

    test('identical texts are one entry naming every package, sorted', () {
      // :76, :84
      expect(
        mergeNotices([lic('zed', 'MIT'), lic('alpha', 'MIT')], []),
        'alpha\nzed\n\nMIT',
      );
    });

    test('texts differing in a trailing newline are different entries', () {
      // :76: the map key is the text as read.
      expect(
        mergeNotices([lic('a', 'MIT'), lic('b', 'MIT\n')], []),
        'a\n\nMIT${sep}b\n\nMIT\n',
      );
    });

    test('entries sort by the whole string: the names decide first', () {
      // :87
      expect(
        mergeNotices([lic('b', 'Apache'), lic('a', 'Zlib')], []),
        'a\n\nZlib${sep}b\n\nApache',
      );
    });

    test('entries with the same names sort by text', () {
      // :87
      final file = 'a\n\nZlib${sep}a\n\nApache';
      expect(
        mergeNotices([lic('p', file)], []),
        'a\n\nApache${sep}a\n\nZlib',
      );
    });

    test('capitals sort before lower case, as String.compareTo does', () {
      expect(
        mergeNotices([lic('a', 'x'), lic('B', 'y')], []),
        'B\n\ny${sep}a\n\nx',
      );
    });

    test('additional licences follow the entries, untouched, in order', () {
      // :127-129
      expect(
        mergeNotices([lic('foo', 'MIT')], ['second\n', 'first']),
        'foo\n\nMIT${sep}second\n${sep}first',
      );
    });

    test('nothing in gives the empty text', () {
      expect(mergeNotices([], []), '');
    });

    test('only additional licences give just those', () {
      expect(mergeNotices([], ['x', 'y']), 'x${sep}y');
    });

    test('one package twice with the same text is one package', () {
      expect(
        mergeNotices([lic('foo', 'MIT'), lic('foo', 'MIT')], []),
        'foo\n\nMIT',
      );
    });

    test('one package twice with different text fails naming both files', () {
      expect(
        () => mergeNotices([
          PackageLicence('foo', 'hub1/foo/LICENSE', 'MIT'),
          PackageLicence('foo', 'hub2/foo/LICENSE', 'BSD'),
        ], []),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('hub1/foo/LICENSE'), contains('hub2/foo/LICENSE')),
          ),
        ),
      );
    });
  });

  group('the file written', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('collect_notices'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(String name, List<int> bytes) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return f.path;
    }

    File run(Map<String, Object?> config) {
      final out = '${dir.path}/out/NOTICES';
      collect(config, out);
      return File(out);
    }

    test('is gzip whose text is the merge, with a header naming no host', () {
      final mit = write('LICENSE', utf8.encode('MIT'));
      final engine = write('ENGINE', utf8.encode('Engine text'));
      final z = run({
        'packages': [
          {'name': 'foo', 'file': mit},
        ],
        'engine': {'name': 'sky_engine', 'file': engine},
        'web': false,
      }).readAsBytesSync();
      expect(z.sublist(0, 2), [0x1f, 0x8b], reason: 'a gzip stream');
      expect(z.sublist(4, 10), [
        0,
        0,
        0,
        0,
        2,
        255,
      ], reason: 'MTIME 0, level 9, OS unknown');
      expect(
        utf8.decode(gzip.decode(z)),
        'foo\n\nMIT${sep}sky_engine\n\nEngine text',
      );
    });

    test('is the plain UTF-8 text for the web', () {
      final mit = write('LICENSE', utf8.encode('MIT ©'));
      final bytes = run({
        'packages': [
          {'name': 'foo', 'file': mit},
        ],
        'web': true,
      }).readAsBytesSync();
      expect(bytes, utf8.encode('foo\n\nMIT ©'));
    });

    test('still is a file with no input', () {
      final f = run({'web': true});
      expect(f.existsSync(), isTrue);
      expect(f.readAsBytesSync(), isEmpty);
      expect(gzip.decode(run({}).readAsBytesSync()), isEmpty);
    });

    test('carries the additional files after the entries', () {
      final mit = write('LICENSE', utf8.encode('MIT'));
      final a = write('A', utf8.encode('extra a'));
      final b = write('B', utf8.encode('extra b'));
      final text = utf8.decode(
        run({
          'packages': [
            {'name': 'foo', 'file': mit},
          ],
          'additional': [
            {
              'name': 'foo',
              'files': [a],
            },
            {
              'name': 'bar',
              'files': [b],
            },
          ],
          'web': true,
        }).readAsBytesSync(),
      );
      expect(text, 'foo\n\nMIT${sep}extra a${sep}extra b');
    });

    test('a licence that is not UTF-8 fails naming the file and package', () {
      final bad = write('LICENSE', [0xff, 0xfe, 0x41]);
      expect(
        () => run({
          'packages': [
            {'name': 'foo', 'file': bad},
          ],
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains(bad), contains('foo')),
          ),
        ),
      );
    });

    test('the same licences give the same bytes', () {
      final mit = write('LICENSE', utf8.encode('MIT' * 1000));
      final config = {
        'packages': [
          {'name': 'foo', 'file': mit},
        ],
      };
      expect(run(config).readAsBytesSync(), run(config).readAsBytesSync());
    });
  });
}
