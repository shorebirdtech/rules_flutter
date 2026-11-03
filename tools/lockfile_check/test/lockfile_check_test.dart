import 'dart:io';

import 'package:test/test.dart';

import '../lockfile_check.dart';

void main() {
  group('findWorkspaces', () {
    late Directory tmp;
    late Directory e2e;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('find_workspaces');
      e2e = Directory('${tmp.path}/e2e')..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void module(String dir) {
      Directory('${e2e.path}/$dir').createSync(recursive: true);
      File('${e2e.path}/$dir/MODULE.bazel').writeAsStringSync('');
    }

    test('finds workspaces at any depth, sorted', () {
      module('smoke');
      module('_overlay_tests/link_hooks');
      module('app');
      expect(findWorkspaces(e2e), [
        'e2e/_overlay_tests/link_hooks',
        'e2e/app',
        'e2e/smoke',
      ]);
    });

    test('ignores directories with no MODULE.bazel', () {
      module('app');
      Directory('${e2e.path}/_compare').createSync();
      expect(findWorkspaces(e2e), ['e2e/app']);
    });

    test('does not look inside a workspace', () {
      module('app');
      module('app/macos/vendored');
      expect(findWorkspaces(e2e), ['e2e/app']);
    });

    test('skips node_modules and bazel output links', () {
      module('node_modules/pkg');
      module('bazel-out/x');
      module('app');
      expect(findWorkspaces(e2e), ['e2e/app']);
    });
  });

  group('withoutUserRc', () {
    test('drops the import of .bazelrc.user, keeps everything else', () {
      const rc = '''
common --lockfile_mode=error

try-import %workspace%/.bazelrc.user
common --foo
''';
      expect(withoutUserRc(rc), '''
common --lockfile_mode=error

common --foo
''');
    });

    test('drops a plain import too', () {
      expect(withoutUserRc('import %workspace%/.bazelrc.user\na'), 'a');
    });

    test('keeps imports of other files', () {
      const rc = 'import %workspace%/tools/preset.bazelrc\n';
      expect(withoutUserRc(rc), rc);
    });
  });

  group('bazelArgs', () {
    test('requires the lock complete, after the command', () {
      expect(bazelArgs(['mod', 'deps'], rcFile: '/t/x.bazelrc'), [
        '--noworkspace_rc',
        '--bazelrc=/t/x.bazelrc',
        'mod',
        '--lockfile_mode=error',
        '--noshow_progress',
        '--curses=no',
        '--color=no',
        'deps',
      ]);
    });

    test('without an rc file passes none', () {
      expect(
        bazelArgs(['build', '//...']),
        isNot(contains(startsWith('--bazelrc'))),
      );
    });

    test('takes another lockfile mode', () {
      expect(
        bazelArgs(['mod', 'tidy'], lockfileMode: 'refresh'),
        contains('--lockfile_mode=refresh'),
      );
    });
  });
}
