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

  group('unpinnedMavenInstalls', () {
    const header = '''
maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
''';

    test('names an install with no lock_file', () {
      expect(
        unpinnedMavenInstalls('''
${header}maven.install(
    name = "a",
    artifacts = ["g:a:1"],
)
'''),
        ['a'],
      );
    });

    test('accepts one with a lock_file, in any attribute order', () {
      expect(
        unpinnedMavenInstalls('''
${header}maven.install(
    lock_file = "//:a_install.json",
    name = "a",
)
maven.install(name = "b", artifacts = ["g:a:1"], lock_file = "//:b.json")
'''),
        isEmpty,
      );
    });

    test('judges each install on its own', () {
      expect(
        unpinnedMavenInstalls('''
${header}maven.install(name = "a", lock_file = "//:a.json")
maven.install(name = "b")
maven.install(name = "c", lock_file = "//:c.json")
'''),
        ['b'],
      );
    });

    test('ignores parentheses and lock_file in comments and strings', () {
      expect(
        unpinnedMavenInstalls('''
${header}maven.install(
    name = "a",  # lock_file = "//:no.json" (not this one)
    artifacts = ["g:a:1", "x(y"],  # (
)
'''),
        ['a'],
      );
    });

    test('follows the name the extension is bound to', () {
      expect(
        unpinnedMavenInstalls('''
jvm = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
jvm.install(name = "a")
'''),
        ['a'],
      );
    });

    test('ignores other extensions and artifact tags', () {
      expect(
        unpinnedMavenInstalls('''
${header}maven.artifact(name = "a", group = "g", artifact = "a", version = "1")
other = use_extension("@other//:x.bzl", "other")
other.install(name = "b")
'''),
        isEmpty,
      );
    });
  });

  group('pinnedMavenInstalls', () {
    test('names the installs that have a lock_file', () {
      expect(
        pinnedMavenInstalls('''
maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(name = "a", lock_file = "//:a.json")
maven.install(name = "b")
'''),
        ['a'],
      );
    });
  });

  group('repinTargets', () {
    test('finds the pin target Bazel asks for', () {
      const output = '''
Error in fail: rules_android_maven_install.json contains an invalid input signature (changes: a:b: 1 vs 2) and must be regenerated. PLEASE DO NOT MODIFY THIS FILE DIRECTLY! To generate a new rules_android_maven_install.json and re-pin the artifacts, please run:
 REPIN=1 bazel run @rules_android_maven//:pin
''';
      expect(repinTargets(output), ['@rules_android_maven//:pin']);
    });

    test('lists each once, sorted', () {
      const output = '''
 REPIN=1 bazel run @b//:pin
 REPIN=1 bazel run @a//:pin
 REPIN=1 bazel run @b//:pin
''';
      expect(repinTargets(output), ['@a//:pin', '@b//:pin']);
    });

    test('finds nothing in unrelated output', () {
      expect(repinTargets('ERROR: no such package'), isEmpty);
    });
  });
}
