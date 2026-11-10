import 'package:test/test.dart';

import '../e2e_matrix.dart';

void main() {
  group('the committed table', () {
    test('accounts for every system of every workspace', () {
      // What is on disk is checked by `bazel run //tools/ci_matrix`; this
      // holds the table to its own rules.
      expect(
        matrixProblems(
          e2eWorkspaces,
          e2eWorkspaces.map((w) => 'e2e/${w.name}'),
        ),
        isEmpty,
      );
    });
  });

  group('archiveProblems', () {
    const attributes = '/e2e/a/ export-ignore\n/e2e/x.json export-ignore\n';

    test('accepts a filter that leaves out every entry but smoke', () {
      expect(archiveProblems(['a/', 'x.json', 'smoke/'], attributes), isEmpty);
    });

    test('names an entry the archive would ship', () {
      expect(archiveProblems(['a/', 'x.json', 'b/'], attributes), [
        contains('e2e/b/ has no `/e2e/b/ export-ignore` line'),
      ]);
    });

    test('names a line for an entry that does not exist', () {
      expect(archiveProblems(['a/'], attributes), [
        contains('export-ignores /e2e/x.json, which does not exist'),
      ]);
    });
  });

  group('matrixProblems', () {
    const ok = E2eWorkspace(
      'a',
      runs: {Os.linux: 'what Linux adds'},
      skips: {Os.macos: 'covered by b', Os.windows: 'cannot build'},
    );
    final found = ['e2e/a'];

    test('accepts a table that matches the tree', () {
      expect(matrixProblems([ok], found), isEmpty);
    });

    test('names a workspace that no entry covers', () {
      expect(
        matrixProblems([ok], ['e2e/a', 'e2e/_overlay_tests/b']),
        [contains('e2e/_overlay_tests/b is in no entry')],
      );
    });

    test('names an entry whose workspace is gone', () {
      expect(
        matrixProblems([
          ok,
          const E2eWorkspace(
            'gone',
            skips: {Os.macos: 'x', Os.linux: 'x', Os.windows: 'x'},
          ),
        ], found),
        [contains('lists e2e/gone, which does not exist')],
      );
    });

    test('requires every system to be run or skipped', () {
      expect(
        matrixProblems([
          const E2eWorkspace('a', runs: {Os.macos: 'why'}),
        ], found),
        unorderedEquals([
          contains('neither runs on linux nor says why not'),
          contains('neither runs on windows nor says why not'),
        ]),
      );
    });

    test('requires a purpose for every system a workspace runs on', () {
      expect(
        matrixProblems([
          const E2eWorkspace(
            'a',
            runs: {Os.macos: 'why', Os.linux: ' '},
            skips: {Os.windows: 'why not'},
          ),
        ], found),
        [contains('runs on linux without saying what it exercises there')],
      );
    });

    test('rejects the same purpose on two systems', () {
      expect(
        matrixProblems([
          const E2eWorkspace(
            'a',
            runs: {Os.macos: 'the same', Os.linux: 'the same'},
            skips: {Os.windows: 'why not'},
          ),
        ], found),
        [contains('gives macos and linux the same purpose')],
      );
    });

    test('rejects a blank reason for a skip', () {
      expect(
        matrixProblems([
          const E2eWorkspace(
            'a',
            runs: {Os.macos: 'why', Os.linux: 'and why'},
            skips: {Os.windows: ' '},
          ),
        ], found),
        [contains('skipped on windows without a reason')],
      );
    });

    test('rejects a system that both runs and is skipped', () {
      expect(
        matrixProblems([
          const E2eWorkspace(
            'a',
            runs: {Os.linux: 'why'},
            skips: {Os.linux: 'why not', Os.macos: 'x', Os.windows: 'x'},
          ),
        ], found),
        [contains('both runs and is skipped on linux')],
      );
    });

    test('rejects a workspace listed twice', () {
      expect(matrixProblems([ok, ok], found), [contains('listed twice')]);
    });
  });

  group('matrixInclude', () {
    test('has one job per workspace and system it runs on', () {
      expect(
        matrixInclude([
          const E2eWorkspace(
            'x',
            runs: {Os.windows: 'b', Os.macos: 'a'},
            skips: {Os.linux: 'why'},
            command: 'build',
          ),
        ], (_) => ''),
        [
          {
            'workspace': 'x',
            'os': 'macos-latest',
            'command': 'build',
            'targets': '//...',
          },
          {
            'workspace': 'x',
            'os': 'windows-latest',
            'command': 'build',
            'targets': '//...',
          },
        ],
      );
    });

    test('gives a system its own command and the tests it names', () {
      expect(
        matrixInclude([
          const E2eWorkspace(
            'x',
            runs: {Os.linux: 'a', Os.macos: 'b'},
            skips: {Os.windows: 'why'},
            command: 'build',
            commands: {Os.linux: 'test'},
            testsNamed: {
              Os.linux: ['one_', 'two_'],
            },
          ),
        ], (_) => 'a(name = "two_b_test")\na(name = "one_a_test")\n'),
        [
          {
            'workspace': 'x',
            'os': 'macos-latest',
            'command': 'build',
            'targets': '//...',
          },
          {
            'workspace': 'x',
            'os': 'ubuntu-latest',
            'command': 'test',
            'targets': '//:one_a_test //:two_b_test',
          },
        ],
      );
    });
  });

  group('targetProblems', () {
    const build =
        'foo(\n    name = "web_one_test",\n)\n'
        'bar(name="web_two_test")\n'
        'bar(name="web_helper")\n'
        'bar(name="linux_one_test")\n'
        'bar(name="other_web_test")\n';
    String file(String _) => build;
    const web = E2eWorkspace(
      'x',
      runs: {Os.linux: 'a'},
      testsNamed: {
        Os.linux: ['web_'],
      },
    );

    test('selects the tests with the prefix, sorted', () {
      expect(web.targetsOn(Os.linux, build), [
        '//:web_one_test',
        '//:web_two_test',
      ]);
    });

    test('picks up a test added to the BUILD file', () {
      expect(
        web.targetsOn(Os.linux, '$build\nbaz(name = "web_x_test")\n'),
        ['//:web_one_test', '//:web_two_test', '//:web_x_test'],
      );
    });

    test('joins several prefixes into one sorted list', () {
      const both = E2eWorkspace(
        'x',
        testsNamed: {
          Os.linux: ['web_', 'linux_'],
        },
      );
      expect(both.targetsOn(Os.linux, build), [
        '//:linux_one_test',
        '//:web_one_test',
        '//:web_two_test',
      ]);
    });

    test('runs everything where nothing is named', () {
      expect(web.targetsOn(Os.macos, build), ['//...']);
    });

    test('accepts prefixes that match a test', () {
      expect(targetProblems([web], file), isEmpty);
    });

    test('names a prefix that matches no test', () {
      expect(
        targetProblems([
          const E2eWorkspace(
            'x',
            testsNamed: {
              Os.linux: ['web_', 'gone_', 'other_'],
            },
          ),
        ], file),
        [
          contains('no `gone_...test` target in e2e/x/BUILD.bazel'),
        ],
      );
    });

    test('does not count a target that is not a test', () {
      expect(
        targetProblems([
          const E2eWorkspace(
            'x',
            testsNamed: {
              Os.linux: ['web_helper'],
            },
          ),
        ], file),
        [contains('no `web_helper...test` target')],
      );
    });

    test('rejects an empty selection', () {
      expect(
        targetProblems([
          const E2eWorkspace('x', testsNamed: {Os.linux: []}),
        ], file),
        [contains('selects no tests')],
      );
    });
  });
}
