import 'package:test/test.dart';

import '../debian_packages.dart';

String _stanza(
  String name, {
  String depends = '',
  String preDepends = '',
  String provides = '',
  bool essential = false,
}) =>
    '''
Package: $name
Version: 1.0-1
${essential ? 'Essential: yes\n' : ''}${preDepends.isEmpty ? '' : 'Pre-Depends: $preDepends\n'}${depends.isEmpty ? '' : 'Depends: $depends\n'}${provides.isEmpty ? '' : 'Provides: $provides\n'}Filename: pool/main/x/$name/${name}_1.0-1_amd64.deb
SHA256: ${'a' * 64}
''';

Map<String, DebianPackage> _index(List<String> stanzas) =>
    parsePackagesIndex(stanzas.join('\n'));

List<String> _names(List<DebianPackage> packages) => [
  for (final p in packages) p.name,
];

void main() {
  group('parsePackagesIndex', () {
    test('reads each stanza\'s relations as alternatives of names, without '
        'versions or architectures', () {
      final index = _index([
        _stanza(
          'gtk',
          preDepends: 'base (>= 1)',
          depends: 'glib (>= 2.74) | glib-alt, cairo:any (>= 1.16)',
          provides: 'gtk-runtime (= 3)',
        ),
      ]);

      final gtk = index['gtk']!;
      expect(gtk.depends, [
        ['base'],
        ['glib', 'glib-alt'],
        ['cairo'],
      ]);
      expect(gtk.provides, ['gtk-runtime']);
      expect(gtk.filename, 'pool/main/x/gtk/gtk_1.0-1_amd64.deb');
      expect(gtk.sha256, 'a' * 64);
    });

    test('refuses a stanza without a digest, naming the package', () {
      expect(
        () => parsePackagesIndex('Package: x\nVersion: 1\nFilename: f\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'package x has no SHA256',
          ),
        ),
      );
    });
  });

  group('resolveClosure', () {
    test('is the roots and what they depend on, transitively, in name '
        'order', () {
      final index = _index([
        _stanza('app', depends: 'gtk'),
        _stanza('gtk', depends: 'glib, cairo'),
        _stanza('glib'),
        _stanza('cairo', depends: 'glib'),
        _stanza('unrelated'),
      ]);

      expect(
        _names(resolveClosure(index, roots: ['app'], excluded: {})),
        ['app', 'cairo', 'glib', 'gtk'],
      );
    });

    test('takes the first alternative the index has, by name or by what a '
        'package provides', () {
      final index = _index([
        _stanza('app', depends: 'missing | virtual, other'),
        _stanza('real', provides: 'virtual'),
        _stanza('other'),
      ]);

      expect(
        _names(resolveClosure(index, roots: ['app'], excluded: {})),
        ['app', 'other', 'real'],
      );
    });

    test('leaves out excluded and essential packages and what only they '
        'bring', () {
      final index = _index([
        _stanza('app', depends: 'libc6, settings, coreutils, lib'),
        _stanza('libc6'),
        _stanza('settings', depends: 'daemon'),
        _stanza('daemon'),
        _stanza('coreutils', essential: true),
        _stanza('lib', depends: 'libc6'),
      ]);

      expect(
        _names(
          resolveClosure(
            index,
            roots: ['app'],
            excluded: {'libc6', 'settings'},
          ),
        ),
        ['app', 'lib'],
      );
    });

    test('refuses a dependency the index has nothing for, naming both', () {
      final index = _index([_stanza('app', depends: 'gone | also-gone')]);

      expect(
        () => resolveClosure(index, roots: ['app'], excluded: {}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('app depends on gone | also-gone'),
          ),
        ),
      );
    });

    test('refuses a root the index does not have', () {
      expect(
        () => resolveClosure(_index([]), roots: ['xvfb'], excluded: {}),
        throwsStateError,
      );
    });
  });

  test('renderPins writes each architecture\'s packages with the floor and '
      'the snapshot they are of', () {
    final pkg = _index([_stanza('glib')])['glib']!;
    final pins = renderPins('20261104T000000Z', {
      'arm64': [pkg],
      'amd64': [pkg],
    });

    expect(pins, contains('snapshot = "20261104T000000Z"'));
    expect(pins, contains('"GLIBC": "2.39"'));
    expect(
      pins.indexOf('"amd64": ['),
      lessThan(pins.indexOf('"arm64": [')),
    );
    expect(
      pins,
      contains(
        '("glib", "1.0-1", "pool/main/x/glib/glib_1.0-1_amd64.deb", '
        '"${'a' * 64}"),',
      ),
    );
  });
}
