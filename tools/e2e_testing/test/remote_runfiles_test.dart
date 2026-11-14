import 'package:rules_flutter_e2e_testing/remote_runfiles.dart';
import 'package:test/test.dart';

void main() {
  group('PathMap', () {
    final paths = PathMap({
      '/out/bin/t.runfiles': '/r/runfiles',
      '/out/_tmp/abc': '/r/tmp',
      '/out/testlogs/t': '/r/testlogs',
    });

    test('moves a path under a root, and the root itself', () {
      expect(paths.map('/out/bin/t.runfiles'), '/r/runfiles');
      expect(paths.map('/out/testlogs/t/test.xml'), '/r/testlogs/test.xml');
    });

    test('moves each path of a list and the value of a flag', () {
      expect(
        paths.map('.:/out/_tmp/abc/bin:/usr/bin'),
        '.:/r/tmp/bin:/usr/bin',
      );
      expect(paths.map('--dir=/out/_tmp/abc'), '--dir=/r/tmp');
    });

    test('leaves a path that only shares a prefix with a root', () {
      expect(paths.map('/out/_tmp/abcd'), '/out/_tmp/abcd');
      expect(paths.map('x/out/_tmp/abc'), 'x/out/_tmp/abc');
      expect(paths.map('./t'), './t');
    });
  });

  group('rewriteManifestLine', () {
    test('points an entry at its copy under the root', () {
      expect(
        rewriteManifestLine('_main/app.zip /exec/bin/app.zip', '/r/runfiles'),
        '_main/app.zip /r/runfiles/_main/app.zip',
      );
    });

    test('keeps an escaped key escaped', () {
      expect(
        rewriteManifestLine(r' _main/a\sb /exec/a\sb', '/r/runfiles'),
        r' _main/a\sb /r/runfiles/_main/a\sb',
      );
    });

    test('keeps an empty file and drops a blank line', () {
      expect(
        rewriteManifestLine('_main/__init__.py ', '/r'),
        '_main/__init__.py ',
      );
      expect(
        rewriteManifestLine('_main/__init__.py', '/r'),
        '_main/__init__.py',
      );
      expect(rewriteManifestLine('', '/r'), isNull);
    });
  });
}
