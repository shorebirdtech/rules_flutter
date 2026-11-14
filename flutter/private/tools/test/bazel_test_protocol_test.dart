// How `flutter_test` applies Bazel's test protocol to a `RemoteListener` tree.
import 'dart:math';

import 'package:flutter_rule_tools/bazel_test_protocol.dart';
import 'package:test/test.dart';

/// A test entry, named in full as `package:test` names it. [tags] are the
/// merged tags `RemoteListener` reports in the test's metadata.
Map<String, dynamic> _test(String name, {List<String>? tags}) => {
  'type': 'test',
  'name': name,
  if (tags != null) 'metadata': {'tags': tags},
};

Map<String, dynamic> _group(
  String name,
  List<Map<String, dynamic>> entries, {
  bool fixtures = false,
}) => {
  'type': 'group',
  'name': name,
  'entries': entries,
  if (fixtures) 'setUpAll': _test('$name (setUpAll)'),
  if (fixtures) 'tearDownAll': _test('$name (tearDownAll)'),
};

/// A suite shaped like `bazel_protocol_test.dart` in e2e/hello_world, with a
/// fourth test so three shards split it unevenly.
Map<String, dynamic> _suite() => _group('', [
  _group('outer', [
    _test('outer runs its setUpAll once'),
    _test('outer ignores a per-test timeout'),
    _group('outer inner', [
      _test('outer inner is reached through both groups'),
    ]),
  ], fixtures: true),
  _test('a widget test is a case like any other'),
]);

List<String> _names(SelectionResult result) => switch (result) {
  RunThese(:final tree) => _treeNames(tree),
  _ => const [],
};

List<String> _treeNames(Map<String, dynamic> group) => [
  for (final entry in group['entries'] as List)
    if ((entry as Map)['type'] == 'group')
      ..._treeNames(entry.cast<String, dynamic>())
    else
      entry['name'] as String,
];

Map<String, dynamic> _tree(SelectionResult result) => (result as RunThese).tree;

/// Six tests: two tagged `golden` (one also `slow`), one `slow`, three bare.
Map<String, dynamic> _tagged() => _group('', [
  _test('a golden', tags: ['golden']),
  _test('b golden slow', tags: ['golden', 'slow']),
  _test('c slow', tags: ['slow']),
  _test('d bare'),
  _test('e bare', tags: []),
  _test('f bare'),
]);

void main() {
  group('TestSelection', () {
    test('keeps the whole tree when nothing narrows it', () {
      final selection = TestSelection.fromEnvironment(const {});
      expect(selection.narrows, isFalse);
      expect(_names(selection.select(_suite())), hasLength(4));
    });

    test('--test_filter is a regular expression over the full name', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': r'inner|widget\b',
      });
      expect(_names(selection.select(_suite())), [
        'outer inner is reached through both groups',
        'a widget test is a case like any other',
      ]);
    });

    test('a group the filter empties goes, fixtures and all', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'widget',
      });
      final selected = _tree(selection.select(_suite()));
      expect(selected['entries'], hasLength(1));
      expect(_treeNames(selected), ['a widget test is a case like any other']);
    });

    test('a group that keeps a test keeps its fixtures', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'setUpAll once',
      });
      final outer =
          (_tree(selection.select(_suite()))['entries'] as List).single;
      expect((outer as Map)['setUpAll'], isNotNull);
      expect(outer['tearDownAll'], isNotNull);
    });

    test('a filter that matches nothing leaves no tree', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'no such test',
      });
      expect(selection.narrows, isTrue);
      expect(selection.select(_suite()), isA<NarrowedToNothing>());
    });

    test(
      'shards split the tests into contiguous shares, each exactly once',
      () {
        final shards = [
          for (var i = 0; i < 3; i++)
            _names(
              TestSelection.fromEnvironment({
                'TEST_TOTAL_SHARDS': '3',
                'TEST_SHARD_INDEX': '$i',
              }).select(_suite()),
            ),
        ];
        expect(shards.expand((s) => s), _names(RunThese(_suite())));
        expect(shards.map((s) => s.length), [1, 2, 1]);
      },
    );

    test('a shard with no share has no tree, and passes', () {
      final selection = TestSelection.fromEnvironment(const {
        // Four tests over eight shards: shard 0 takes [0, 1), shard 1 the
        // empty [1, 1).
        'TEST_TOTAL_SHARDS': '8',
        'TEST_SHARD_INDEX': '1',
      });
      expect(selection.narrows, isTrue);
      expect(selection.select(_suite()), isA<NarrowedToNothing>());
    });

    test('the filter applies before the shards split what is left', () {
      final shards = [
        for (var i = 0; i < 2; i++)
          _names(
            TestSelection.fromEnvironment({
              'TESTBRIDGE_TEST_ONLY': 'outer',
              'TEST_TOTAL_SHARDS': '2',
              'TEST_SHARD_INDEX': '$i',
            }).select(_suite()),
          ),
      ];
      expect(shards.expand((s) => s), hasLength(3));
      expect(shards.expand((s) => s), everyElement(contains('outer')));
    });

    test('refuses a filter that is not a regular expression', () {
      expect(
        () =>
            TestSelection.fromEnvironment(const {'TESTBRIDGE_TEST_ONLY': '('}),
        throwsFormatException,
      );
    });

    test('refuses shard numbers Bazel would not send', () {
      expect(
        () => TestSelection.fromEnvironment(const {
          'TEST_TOTAL_SHARDS': 'two',
          'TEST_SHARD_INDEX': '0',
        }),
        throwsFormatException,
      );
      expect(
        () => TestSelection.fromEnvironment(const {
          'TEST_TOTAL_SHARDS': '2',
          'TEST_SHARD_INDEX': '2',
        }),
        throwsFormatException,
      );
    });
  });

  group('tags', () {
    SelectionResult select(
      Map<String, String> env, {
      TagSelection fixed = const TagSelection(),
      Map<String, dynamic>? tree,
    }) => TestSelection.fromEnvironment(
      env,
      fixedTags: fixed,
    ).select(tree ?? _tagged());

    test('DART_TEST_TAGS keeps only the tests with the tag', () {
      expect(_names(select(const {'DART_TEST_TAGS': 'golden'})), [
        'a golden',
        'b golden slow',
      ]);
    });

    test('comma-separated selectors must all match', () {
      expect(_names(select(const {'DART_TEST_TAGS': 'golden,slow'})), [
        'b golden slow',
      ]);
    });

    test('a selector is a boolean expression', () {
      expect(_names(select(const {'DART_TEST_TAGS': 'golden || slow'})), [
        'a golden',
        'b golden slow',
        'c slow',
      ]);
      expect(_names(select(const {'DART_TEST_TAGS': 'golden && !slow'})), [
        'a golden',
      ]);
    });

    test('DART_TEST_EXCLUDE_TAGS drops a test with any of them', () {
      expect(
        _names(select(const {'DART_TEST_EXCLUDE_TAGS': 'golden,slow'})),
        ['d bare', 'e bare', 'f bare'],
      );
    });

    test('a fixed include and a run include must both match', () {
      final fixed = TagSelection.fromAttribute(['golden'], const []);
      expect(
        _names(select(const {'DART_TEST_TAGS': 'slow'}, fixed: fixed)),
        ['b golden slow'],
      );
    });

    test('a fixed exclude and a run exclude both drop', () {
      final fixed = TagSelection.fromAttribute(const [], ['golden']);
      expect(
        _names(select(const {'DART_TEST_EXCLUDE_TAGS': 'slow'}, fixed: fixed)),
        ['d bare', 'e bare', 'f bare'],
      );
    });

    test('a fixed selection alone runs the tests it keeps', () {
      final fixed = TagSelection.fromAttribute(['slow'], const []);
      expect(_names(select(const {}, fixed: fixed)), [
        'b golden slow',
        'c slow',
      ]);
    });

    test('tags apply before the filter', () {
      expect(
        _names(
          select(const {
            'DART_TEST_TAGS': 'golden',
            'TESTBRIDGE_TEST_ONLY': 'slow',
          }),
        ),
        ['b golden slow'],
      );
    });

    test('shards split what the tags left', () {
      final shards = [
        for (var i = 0; i < 3; i++)
          _names(
            select({
              'DART_TEST_TAGS': 'slow',
              'TEST_TOTAL_SHARDS': '3',
              'TEST_SHARD_INDEX': '$i',
            }),
          ),
      ];
      expect(shards.expand((s) => s), ['b golden slow', 'c slow']);
    });

    test('an empty or blank DART_TEST_TAGS selects nothing away', () {
      for (final value in ['', ' , ']) {
        final selection = TestSelection.fromEnvironment({
          'DART_TEST_TAGS': value,
          'DART_TEST_EXCLUDE_TAGS': value,
        });
        expect(selection.narrows, isFalse, reason: 'value "$value"');
        expect(_names(selection.select(_tagged())), hasLength(6));
      }
    });

    test('no test registered is its own result', () {
      expect(
        TestSelection().select(_group('', const [])),
        isA<NoneRegistered>(),
      );
    });

    test('no test registered under a tag selection passes with a note', () {
      final result = select(const {
        'DART_TEST_TAGS': 'x',
      }, tree: _group('', const []));
      expect(
        (result as NarrowedToNothing).note,
        allOf(
          contains('DART_TEST_TAGS "x"'),
          contains('no test in this suite has a tag'),
        ),
      );
    });

    test('a fixed selection that keeps nothing fails like upstream', () {
      final fixed = TagSelection.fromAttribute(['nope'], const []);
      final message =
          (select(const {}, fixed: fixed) as FixedSelectionEmpty).message;
      expect(message, contains('No tests match the requested tag selectors'));
      expect(message, contains('include: "nope"'));
      expect(message, contains('exclude: "<none>"'));
      expect(message, contains('tags used in this suite: golden, slow'));
    });

    test('a fixed selection that keeps nothing fails even when a run '
        'selection would have kept some', () {
      final fixed = TagSelection.fromAttribute(['nope'], const []);
      expect(
        select(const {'DART_TEST_TAGS': 'golden'}, fixed: fixed),
        isA<FixedSelectionEmpty>(),
      );
    });

    test('a run selection that keeps nothing passes and names the tags', () {
      final note =
          (select(const {'DART_TEST_TAGS': 'goldn'}) as NarrowedToNothing).note;
      expect(note, contains('DART_TEST_TAGS "goldn"'));
      expect(note, contains('tags used in this suite: golden, slow'));
    });

    test('the note names every part of the run that narrowed it', () {
      final note = (select(const {
        'DART_TEST_TAGS': 'golden',
        'DART_TEST_EXCLUDE_TAGS': 'golden',
        'TESTBRIDGE_TEST_ONLY': 'x',
      }) as NarrowedToNothing).note;
      expect(
        note,
        contains(
          '--test_filter "x", DART_TEST_TAGS "golden", '
          'DART_TEST_EXCLUDE_TAGS "golden"',
        ),
      );
    });

    test('a test with no tags in its metadata has none', () {
      expect(
        _names(select(const {'DART_TEST_EXCLUDE_TAGS': 'slow'})),
        contains('d bare'),
      );
    });

    test('a selector that does not parse names the variable', () {
      expect(
        () => TestSelection.fromEnvironment(const {'DART_TEST_TAGS': 'a &&'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('DART_TEST_TAGS "a &&"'), contains('not a tag')),
          ),
        ),
      );
      expect(
        () => TestSelection.fromEnvironment(const {
          'DART_TEST_EXCLUDE_TAGS': '(',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('DART_TEST_EXCLUDE_TAGS'),
          ),
        ),
      );
    });

    test('an attribute entry that does not parse names the entry', () {
      expect(
        () => TagSelection.fromAttribute(['a &&'], const []),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('include_tags entry "a &&"'),
          ),
        ),
      );
      expect(
        () => TagSelection.fromAttribute(const [], ['b ||']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('exclude_tags entry "b ||"'),
          ),
        ),
      );
    });

    test('an attribute entry with a comma is one selector, not two', () {
      expect(
        () => TagSelection.fromAttribute(['a,b'], const []),
        throwsFormatException,
      );
    });
  });

  group('ordering seed', () {
    /// [names] in the order package:test's engine runs a group of them under
    /// [seed]: one `Random(seed)` shuffling the group's entries.
    List<String> shuffled(List<String> names, int seed) =>
        names.toList()..shuffle(Random(seed));

    final flat = [
      'a golden',
      'b golden slow',
      'c slow',
      'd bare',
      'e bare',
      'f bare',
    ];

    test('unset, empty or 0 keeps the declared order', () {
      for (final env in [
        const <String, String>{},
        const {'DART_TEST_ORDERING_SEED': ''},
        const {'DART_TEST_ORDERING_SEED': '0'},
      ]) {
        expect(
          _names(TestSelection.fromEnvironment(env).select(_tagged())),
          flat,
          reason: '$env',
        );
      }
    });

    test('a seed shuffles each group with a Random of that seed', () {
      final selection = TestSelection.fromEnvironment(const {
        'DART_TEST_ORDERING_SEED': '7',
      });
      expect(selection.orderingSeed, 7);
      expect(_names(selection.select(_tagged())), shuffled(flat, 7));
      expect(shuffled(flat, 7), isNot(flat), reason: 'a seed that reorders');
    });

    test('nested groups are each shuffled with a new Random', () {
      final selection = TestSelection.fromEnvironment(const {
        'DART_TEST_ORDERING_SEED': '3',
      });
      final tree = _tree(selection.select(_suite()));
      final top = [
        for (final e in tree['entries'] as List) (e as Map)['name'] as String,
      ];
      expect(
        top,
        shuffled(['outer', 'a widget test is a case like any other'], 3),
      );
      final outer = (tree['entries'] as List).cast<Map>().singleWhere(
        (e) => e['name'] == 'outer',
      );
      expect(
        [for (final e in outer['entries'] as List) (e as Map)['name']],
        shuffled([
          'outer runs its setUpAll once',
          'outer ignores a per-test timeout',
          'outer inner',
        ], 3),
      );
      expect(outer['setUpAll'], isNotNull, reason: 'fixtures stay put');
    });

    test('shards split the declared order, then the shard is shuffled', () {
      final selection = TestSelection.fromEnvironment(const {
        'DART_TEST_ORDERING_SEED': '7',
        'TEST_TOTAL_SHARDS': '2',
        'TEST_SHARD_INDEX': '0',
      });
      expect(
        _names(selection.select(_tagged())),
        shuffled(['a golden', 'b golden slow', 'c slow'], 7),
      );
    });

    test('random draws a seed and keeps it, for the runner to print', () {
      final seed = TestSelection.parseOrderingSeed(
        'random',
        random: Random(1),
      );
      expect(seed, Random(1).nextInt(4294967295));
    });

    test('a seed is read as unsigned 32 bits, as package:test reads it', () {
      expect(TestSelection.parseOrderingSeed('-1'), 4294967295);
      expect(TestSelection.parseOrderingSeed('4294967297'), 1);
    });

    test('a value that is no seed fails, naming the variable', () {
      expect(
        () => TestSelection.fromEnvironment(const {
          'DART_TEST_ORDERING_SEED': 'often',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('DART_TEST_ORDERING_SEED "often"'),
          ),
        ),
      );
    });
  });

  group('junitXml', () {
    final xml = junitXml([
      TestCaseResult.passed(
        'adds <two> & "two"',
        const Duration(milliseconds: 1500),
        'printed\n',
      ),
      TestCaseResult.failed(
        'fails',
        Duration.zero,
        '',
        failureType: 'TestFailure',
        message: 'Expected: 1\nActual: 2',
        detail: 'TestFailure: Expected: 1\nActual: 2',
      ),
      TestCaseResult.failed(
        'throws',
        Duration.zero,
        '',
        failureType: 'StateError',
        message: 'bad state',
        detail: 'StateError: bad state',
      ),
      TestCaseResult.skipped('skipped'),
    ], suiteName: 'test/foo_test.dart');

    test('counts each outcome on the suite', () {
      expect(
        xml,
        contains(
          '<testsuite name="test/foo_test.dart" tests="4" failures="1" '
          'errors="1" skipped="1" time="1.500">',
        ),
      );
    });

    test('keeps a failed expectation apart from an error', () {
      expect(xml, contains('<failure message="Expected: 1">'));
      expect(xml, contains('<error message="bad state">'));
    });

    test('escapes names and carries what the case printed', () {
      expect(xml, contains('name="adds &lt;two&gt; &amp; &quot;two&quot;"'));
      expect(xml, contains('<system-out>printed\n</system-out>'));
      expect(xml, contains('<skipped/>'));
    });
  });

  group('parseUpdateGoldens', () {
    // The refusal is the reason this is a function rather than three lines in
    // `main`: `bazel test` cannot be made to pass and fail the same target, so
    // the only place the rejected case is reachable as a *passing* assertion
    // is here.

    test('is off with no arguments, whether or not a workspace is set', () {
      expect(parseUpdateGoldens([], null, program: 'a runner'), isFalse);
      expect(parseUpdateGoldens([], '/ws', program: 'a runner'), isFalse);
    });

    test('is on under `bazel run`, which sets BUILD_WORKSPACE_DIRECTORY', () {
      expect(
        parseUpdateGoldens(['--update-goldens'], '/ws', program: 'a runner'),
        isTrue,
      );
    });

    test('refuses under `bazel test`, where there is no source tree to write '
        'to — a golden regenerated into the sandbox would report success and '
        'change nothing', () {
      expect(
        () =>
            parseUpdateGoldens(['--update-goldens'], null, program: 'a runner'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('bazel run'), contains('--update-goldens')),
          ),
        ),
      );
      expect(
        () => parseUpdateGoldens(['--update-goldens'], '', program: 'a runner'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an unrecognised argument rather than ignoring it, so a '
        'mistyped flag cannot report a green run that regenerated nothing', () {
      expect(
        () =>
            parseUpdateGoldens(['--update-golden'], '/ws', program: 'a runner'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--update-golden'),
          ),
        ),
      );
    });
  });
}
