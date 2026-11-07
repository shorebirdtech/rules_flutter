import 'dart:io';

import 'package:test/test.dart';

import '../pub_runfiles.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('pub_runfiles_'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('a manifest', () {
    test('maps a runfiles path to the real path', () {
      final r = Runfiles.fromManifest(
        '_main/flutter/private/tools/pub.dart C:/src/pub.dart\n'
        '+flutter+dev_root/bin/cache/flutter.version.json D:/sdk/v.json\n',
      );
      expect(
        r.rlocation('_main/flutter/private/tools/pub.dart'),
        'C:/src/pub.dart',
      );
      expect(
        r.rlocation('+flutter+dev_root/bin/cache/flutter.version.json'),
        'D:/sdk/v.json',
      );
      expect(r.rlocation('_main/other.dart'), isNull);
    });

    test('resolves a file under a directory it lists as one entry', () {
      final r = Runfiles.fromManifest('+flutter+sdk D:/cache/sdk\n');
      expect(
        r.rlocation('+flutter+sdk/bin/dart.exe'),
        'D:/cache/sdk/bin/dart.exe',
      );
      expect(r.rlocation('+flutter+other/bin/dart.exe'), isNull);
    });

    test('reads Windows line endings, spaces and the escapes for them', () {
      final r = Runfiles.fromManifest(
        'a/b C:/with space/b\r\n'
        ' a/c\\sd C:/x\\sy\\bz\r\n',
      );
      expect(r.rlocation('a/b'), 'C:/with space/b');
      expect(r.rlocation('a/c d'), r'C:/x y\z');
    });
  });

  group('a runfiles tree', () {
    test('has a file at its path or none', () {
      File('${temp.path}/_main/x.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      final r = Runfiles.inDirectory(temp.path);
      expect(r.rlocation('_main/x.dart'), '${temp.path}/_main/x.dart');
      expect(r.rlocation('_main/y.dart'), isNull);
    });
  });

  group('discovery', () {
    test('reads the manifest RUNFILES_MANIFEST_FILE names', () {
      final manifest = File('${temp.path}/m')
        ..writeAsStringSync('p/q /real/q\n');
      final r = Runfiles.discover({
        'RUNFILES_MANIFEST_FILE': manifest.path,
      }, '${temp.path}/runner');
      expect(r.rlocation('p/q'), '/real/q');
    });

    test(
      'uses the manifest beside the executable when the environment has none',
      () {
        File('${temp.path}/runner.exe.runfiles_manifest')
            .writeAsStringSync('p/q /real/q\n');
        final r = Runfiles.discover({}, '${temp.path}/runner');
        expect(r.rlocation('p/q'), '/real/q');
      },
    );

    test('uses RUNFILES_DIR when there is no manifest', () {
      Directory('${temp.path}/tree').createSync();
      final r = Runfiles.discover({
        'RUNFILES_DIR': '${temp.path}/tree',
      }, '${temp.path}/runner');
      expect(r.rlocation('missing'), isNull);
    });

    test('says what it looked at when there are no runfiles', () {
      expect(
        () => Runfiles.discover({}, '${temp.path}/runner'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('${temp.path}/runner.runfiles'),
          ),
        ),
      );
    });
  });
}
