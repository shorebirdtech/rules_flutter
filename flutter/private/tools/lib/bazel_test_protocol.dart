/// Bazel's test protocol, for a suite `flutter_test_runner.dart` runs by
/// walking `package:test`'s tree itself.
///
/// `dart_test` gets the same behaviour by running `package:test`'s own runner
/// (`--name`, `--total-shards`/`--shard-index`, a JSON reporter converted to
/// JUnit). `flutter_test` speaks the `RemoteListener` protocol directly, so it
/// applies those rules here, the way that runner applies them:
///
/// - `TESTBRIDGE_TEST_ONLY` (`--test_filter`) is a regular expression matched
///   against each test's full name, as `--name` is.
/// - `TEST_TOTAL_SHARDS`/`TEST_SHARD_INDEX` give each shard a contiguous share
///   of the tests the filter left, as `--total-shards`/`--shard-index` do.
/// - A group left with no test is dropped, and its `setUpAll`/`tearDownAll`
///   with it.
/// - `DART_TEST_ORDERING_SEED` (`--test_env`) is `--test-randomize-ordering-seed`:
///   each group's entries are shuffled with a `Random` of that seed after the
///   other selections, as the runner's engine shuffles them, so a seed orders
///   a suite here as it does under `flutter test`.
/// - Each case goes to `XML_OUTPUT_FILE` as JUnit XML, in the shape
///   `dart_test` writes.
library;

import 'dart:math';

import 'package:boolean_selector/boolean_selector.dart';

/// Whether this run should regenerate goldens instead of comparing them.
///
/// Pure so it can be tested without a Bazel invocation to produce each case;
/// [workspaceDir] is `BUILD_WORKSPACE_DIRECTORY`, which `bazel run` sets and
/// `bazel test` does not. That variable is the discriminator rather than
/// anything about the arguments, because it is the actual constraint: update
/// mode writes to the source tree, and a test action has no source tree.
///
/// [program] names the runner in the messages.
///
/// Throws [FormatException] for an unrecognised argument. Nothing passes argv
/// to a `flutter_test` today — not `bazel test`, not `bazel coverage` — so an
/// unrecognised one came from a person, and silently ignoring a mistyped
/// `--update-golden` would report a green run that regenerated nothing.
bool parseUpdateGoldens(
  List<String> args,
  String? workspaceDir, {
  required String program,
}) {
  var update = false;
  for (final arg in args) {
    if (arg != '--update-goldens') {
      throw FormatException(
        '$program: unrecognised argument "$arg". The only '
        'supported argument is --update-goldens.',
      );
    }
    update = true;
  }
  if (update && (workspaceDir == null || workspaceDir.isEmpty)) {
    throw FormatException(
      '$program: --update-goldens rewrites goldens in the source '
      'tree, which a test action cannot do. Regenerate with '
      '`bazel run //<pkg>:<target> -- --update-goldens`.',
    );
  }
  return update;
}

/// Which tests a set of `package:test` tag selectors keeps.
///
/// An include selector keeps a test whose tags it matches and an exclude
/// selector drops one whose tags it matches, as `--tags` and `--exclude-tags`
/// do. Selectors combine as `package:test` combines `dart_test.yaml` with the
/// command line: includes intersect, excludes unite.
class TagSelection {
  const TagSelection({
    this.include = BooleanSelector.all,
    this.exclude = BooleanSelector.none,
    this.includeRaw,
    this.excludeRaw,
  });

  /// Reads the value of `DART_TEST_TAGS` and `DART_TEST_EXCLUDE_TAGS`: each is
  /// comma-separated selectors, as `--tags` takes them. Unset, empty and
  /// blank pieces select nothing away.
  ///
  /// Throws [FormatException] naming the variable for a piece that is not a
  /// selector.
  factory TagSelection.fromEnvironmentValues(String? include, String? exclude) {
    final includes = _pieces(include);
    final excludes = _pieces(exclude);
    return TagSelection(
      include: _combine(
        includes,
        (_) => 'DART_TEST_TAGS "$include" is not a tag selector: ',
        intersect: true,
      ),
      exclude: _combine(
        excludes,
        (_) => 'DART_TEST_EXCLUDE_TAGS "$exclude" is not a tag selector: ',
        intersect: false,
      ),
      includeRaw: includes.isEmpty ? null : include,
      excludeRaw: excludes.isEmpty ? null : exclude,
    );
  }

  /// Reads the `include_tags` and `exclude_tags` attributes: each entry is one
  /// selector and is not split.
  ///
  /// Throws [FormatException] naming the attribute and the entry.
  factory TagSelection.fromAttribute(
    List<String> include,
    List<String> exclude,
  ) => TagSelection(
    include: _combine(
      include,
      (entry) => 'include_tags entry "$entry" is not a tag selector: ',
      intersect: true,
    ),
    exclude: _combine(
      exclude,
      (entry) => 'exclude_tags entry "$entry" is not a tag selector: ',
      intersect: false,
    ),
  );

  static List<String> _pieces(String? value) => [
    for (final piece in (value ?? '').split(','))
      if (piece.trim().isNotEmpty) piece.trim(),
  ];

  /// [selectors] folded into one, an intersection or a union. [describe] gives
  /// the start of the error message, which then ends with the parser's own
  /// words.
  static BooleanSelector _combine(
    List<String> selectors,
    String Function(String selector) describe, {
    required bool intersect,
  }) {
    var result = intersect ? BooleanSelector.all : BooleanSelector.none;
    for (final selector in selectors) {
      final BooleanSelector parsed;
      try {
        parsed = BooleanSelector.parse(selector);
      } on FormatException catch (e) {
        throw FormatException('${describe(selector)}${e.message}');
      }
      result = intersect ? result.intersection(parsed) : result.union(parsed);
    }
    return result;
  }

  /// A test must match this to be kept.
  final BooleanSelector include;

  /// A test that matches this is dropped.
  final BooleanSelector exclude;

  /// The variables' values as given, for messages. Null when not selecting.
  final String? includeRaw;
  final String? excludeRaw;

  /// Whether this keeps less than every test.
  bool get selects =>
      !identical(include, BooleanSelector.all) ||
      !identical(exclude, BooleanSelector.none);

  bool matches(Set<String> tags) =>
      include.evaluate(tags.contains) && !exclude.evaluate(tags.contains);

  /// Both selections at once: a test must pass each.
  TagSelection merge(TagSelection other) => TagSelection(
    include: include.intersection(other.include),
    exclude: exclude.union(other.exclude),
    includeRaw: includeRaw ?? other.includeRaw,
    excludeRaw: excludeRaw ?? other.excludeRaw,
  );
}

/// What a [TestSelection] made of a suite's tree.
sealed class SelectionResult {
  const SelectionResult();
}

/// Run [tree], the tests this run executes.
class RunThese extends SelectionResult {
  const RunThese(this.tree);
  final Map<String, dynamic> tree;
}

/// The suite registered no test at all and nothing narrowed the run.
class NoneRegistered extends SelectionResult {
  const NoneRegistered();
}

/// The target's own fixed tag selection keeps no test: a broken target.
class FixedSelectionEmpty extends SelectionResult {
  const FixedSelectionEmpty(this.message);
  final String message;
}

/// This run's tags, filter or shard keep no test; a pass, with [note].
class NarrowedToNothing extends SelectionResult {
  const NarrowedToNothing(this.note);
  final String note;
}

/// Which of a suite's tests this run executes.
class TestSelection {
  TestSelection({
    this.filter,
    this.totalShards = 1,
    this.shardIndex = 0,
    this.fixedTags = const TagSelection(),
    this.runTags = const TagSelection(),
    this.orderingSeed,
  }) {
    if (totalShards < 1 || shardIndex < 0 || shardIndex >= totalShards) {
      throw FormatException(
        'shard $shardIndex of $totalShards is not a shard Bazel would ask for',
      );
    }
  }

  /// Reads Bazel's variables out of [env], and `DART_TEST_TAGS`,
  /// `DART_TEST_EXCLUDE_TAGS` and `DART_TEST_ORDERING_SEED`. [fixedTags] is
  /// the target's own selection. [random] draws the seed of
  /// `DART_TEST_ORDERING_SEED=random`.
  ///
  /// Throws [FormatException] for a filter that is not a regular expression,
  /// shard numbers that are not numbers, a tag selector that does not parse
  /// or a seed that is not one: a run that guessed would report a selection
  /// that never happened.
  factory TestSelection.fromEnvironment(
    Map<String, String> env, {
    TagSelection fixedTags = const TagSelection(),
    Random? random,
  }) {
    final orderingSeed = parseOrderingSeed(
      env['DART_TEST_ORDERING_SEED'],
      random: random,
    );
    final pattern = env['TESTBRIDGE_TEST_ONLY'];
    RegExp? filter;
    if (pattern != null && pattern.isNotEmpty) {
      try {
        filter = RegExp(pattern);
      } on FormatException catch (e) {
        throw FormatException(
          '--test_filter "$pattern" is not a regular expression: ${e.message}',
        );
      }
    }
    final runTags = TagSelection.fromEnvironmentValues(
      env['DART_TEST_TAGS'],
      env['DART_TEST_EXCLUDE_TAGS'],
    );
    final total = env['TEST_TOTAL_SHARDS'];
    if (total == null) {
      return TestSelection(
        filter: filter,
        fixedTags: fixedTags,
        runTags: runTags,
        orderingSeed: orderingSeed,
      );
    }
    final totalShards = int.tryParse(total);
    final shardIndex = int.tryParse(env['TEST_SHARD_INDEX'] ?? '');
    if (totalShards == null || shardIndex == null) {
      throw FormatException(
        'TEST_TOTAL_SHARDS "$total" and TEST_SHARD_INDEX '
        '"${env['TEST_SHARD_INDEX']}" must both be numbers',
      );
    }
    return TestSelection(
      filter: filter,
      totalShards: totalShards,
      shardIndex: shardIndex,
      fixedTags: fixedTags,
      runTags: runTags,
      orderingSeed: orderingSeed,
    );
  }

  /// `DART_TEST_ORDERING_SEED` [value] as `--test-randomize-ordering-seed`
  /// reads it: an integer, taken as unsigned 32 bits, or `random` for one
  /// [random] draws. Unset or empty is no seed.
  static int? parseOrderingSeed(String? value, {Random? random}) {
    if (value == null || value.isEmpty) return null;
    if (value == 'random') return (random ?? Random()).nextInt(4294967295);
    final seed = int.tryParse(value);
    if (seed == null) {
      throw FormatException(
        'DART_TEST_ORDERING_SEED "$value" is not a seed: it must be a 32bit '
        'unsigned integer or "random", as for --test-randomize-ordering-seed',
      );
    }
    return seed.toUnsigned(32);
  }

  final RegExp? filter;
  final int totalShards;
  final int shardIndex;

  /// The target's own tag selection (`include_tags`, `exclude_tags`).
  final TagSelection fixedTags;

  /// This run's tag selection (`DART_TEST_TAGS`, `DART_TEST_EXCLUDE_TAGS`).
  final TagSelection runTags;

  /// This run's `DART_TEST_ORDERING_SEED`. Null or 0 keeps the order the
  /// suite declares, as with `--test-randomize-ordering-seed`.
  final int? orderingSeed;

  /// Whether this run asked for less than the whole suite. A selection that
  /// matches nothing is then a pass, not a failure: `bazel test //...
  /// --test_filter=x` has to pass every target the filter does not touch, and
  /// a shard can draw no case at all.
  bool get narrows => filter != null || totalShards > 1 || runTags.selects;

  /// What this run does with [root], a `RemoteListener` group tree; [program]
  /// names the runner in messages. Tags select first, then the filter, then
  /// the shards split what is left.
  SelectionResult select(
    Map<String, dynamic> root, {
    String program = 'flutter_test',
  }) {
    final all = <Map<Object?, Object?>>[];
    _collect(root, all);
    if (all.isEmpty) {
      return narrows
          ? NarrowedToNothing(_note(program, const {}))
          : const NoneRegistered();
    }
    final used = {for (final test in all) ..._tags(test)};
    final fixed = [
      for (final test in all)
        if (fixedTags.matches(_tags(test))) test,
    ];
    if (fixed.isEmpty) {
      return FixedSelectionEmpty(
        '$program: No tests match the requested tag selectors:\n'
        '  include: "${fixedTags.include}"\n'
        '  exclude: "${fixedTags.exclude}"\n'
        '${_tagsUsed(program, used)}',
      );
    }
    final matching = [
      for (final test in fixed)
        if (runTags.matches(_tags(test)) &&
            (filter?.hasMatch(test['name'] as String? ?? '') ?? true))
          test,
    ];
    final share = matching.length / totalShards;
    final start = (share * shardIndex).round();
    final end = (share * (shardIndex + 1)).round();
    // By identity, and over the entries as decoded: a `cast` view is a new
    // object each time, so two walks would never find each other's.
    final chosen = Set<Map<Object?, Object?>>.identity()
      ..addAll(matching.sublist(start, end));
    final tree = _prune(root, chosen);
    if (tree == null) return NarrowedToNothing(_note(program, used));
    final seed = orderingSeed;
    if (seed != null && seed > 0) _shuffle(tree, seed);
    return RunThese(tree);
  }

  /// [test]'s tags: the ones `RemoteListener` merged from its library, groups
  /// and the test itself.
  static Set<String> _tags(Map<Object?, Object?> test) => {
    for (final tag
        in (test['metadata'] as Map<Object?, Object?>?)?['tags'] as List? ??
            const [])
      tag as String,
  };

  static String _tagsUsed(String program, Set<String> used) => used.isEmpty
      ? '$program: no test in this suite has a tag'
      : '$program: tags used in this suite: '
            '${(used.toList()..sort()).join(', ')}';

  String _note(String program, Set<String> used) {
    final parts = [
      if (filter != null) '--test_filter "${filter!.pattern}"',
      if (totalShards > 1) 'shard ${shardIndex + 1} of $totalShards',
      if (runTags.includeRaw != null) 'DART_TEST_TAGS "${runTags.includeRaw}"',
      if (runTags.excludeRaw != null)
        'DART_TEST_EXCLUDE_TAGS "${runTags.excludeRaw}"',
    ];
    return '$program: no test case in this suite matches this run\'s '
        '${parts.join(', ')}.'
        '${runTags.selects ? '\n${_tagsUsed(program, used)}' : ''}';
  }

  static void _collect(
    Map<Object?, Object?> group,
    List<Map<Object?, Object?>> into,
  ) {
    for (final entry in group['entries'] as List? ?? const []) {
      final m = entry as Map<Object?, Object?>;
      if (m['type'] == 'group') {
        _collect(m, into);
      } else {
        into.add(m);
      }
    }
  }

  /// Shuffles each group's entries with a `Random` of [seed], a new one per
  /// group, before the groups inside it: package:test's engine does the same
  /// as it runs each group. [group] is a tree [_prune] built, whose lists are
  /// its own.
  static void _shuffle(Map<Object?, Object?> group, int seed) {
    final entries = group['entries'] as List;
    entries.shuffle(Random(seed));
    for (final entry in entries) {
      final m = entry as Map<Object?, Object?>;
      if (m['type'] == 'group') _shuffle(m, seed);
    }
  }

  static Map<String, dynamic>? _prune(
    Map<Object?, Object?> group,
    Set<Map<Object?, Object?>> chosen,
  ) {
    final kept = <Object?>[];
    for (final entry in group['entries'] as List? ?? const []) {
      final m = entry as Map<Object?, Object?>;
      if (m['type'] == 'group') {
        final child = _prune(m, chosen);
        if (child != null) kept.add(child);
      } else if (chosen.contains(m)) {
        kept.add(m);
      }
    }
    if (kept.isEmpty) return null;
    return {...group.cast<String, dynamic>(), 'entries': kept};
  }
}

/// One case's outcome, for the JUnit report.
class TestCaseResult {
  TestCaseResult.passed(this.name, this.elapsed, this.output)
    : skipped = false,
      failureType = null,
      message = null,
      detail = null;

  TestCaseResult.skipped(this.name)
    : skipped = true,
      elapsed = Duration.zero,
      output = '',
      failureType = null,
      message = null,
      detail = null;

  TestCaseResult.failed(
    this.name,
    this.elapsed,
    this.output, {
    required String this.failureType,
    required String this.message,
    required String this.detail,
  }) : skipped = false;

  final String name;
  final Duration elapsed;
  final String output;
  final bool skipped;

  /// `TestFailure` for a failed expectation, anything else for an error;
  /// JUnit keeps the two apart, as `package:test`'s reporters do.
  final String? failureType;
  final String? message;
  final String? detail;
}

/// [cases] as JUnit XML, one `testsuite` named [suiteName] — the shape
/// `dart_test` writes, so one parser reads both.
String junitXml(List<TestCaseResult> cases, {required String suiteName}) {
  String seconds(Duration d) =>
      (d.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(3);
  bool isFailure(TestCaseResult c) => c.failureType == 'TestFailure';
  final failures = cases.where((c) => c.failureType != null && isFailure(c));
  final errors = cases.where((c) => c.failureType != null && !isFailure(c));
  final skipped = cases.where((c) => c.skipped);
  final total = cases.fold(Duration.zero, (sum, c) => sum + c.elapsed);

  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<testsuites>')
    ..writeln(
      '  <testsuite name="${_attr(suiteName)}" tests="${cases.length}" '
      'failures="${failures.length}" errors="${errors.length}" '
      'skipped="${skipped.length}" time="${seconds(total)}">',
    );
  for (final c in cases) {
    out.write(
      '    <testcase name="${_attr(c.name)}" '
      'classname="${_attr(suiteName)}" time="${seconds(c.elapsed)}">',
    );
    if (c.skipped) {
      out.write('<skipped/>');
    } else if (c.failureType != null) {
      final tag = isFailure(c) ? 'failure' : 'error';
      out.write(
        '<$tag message="${_attr(c.message!.split('\n').first)}">'
        '${_text(c.detail!)}</$tag>',
      );
    }
    if (c.output.isNotEmpty) {
      out.write('<system-out>${_text(c.output)}</system-out>');
    }
    out.writeln('</testcase>');
  }
  out
    ..writeln('  </testsuite>')
    ..writeln('</testsuites>');
  return out.toString();
}

String _text(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _attr(String s) => _text(s).replaceAll('"', '&quot;');
