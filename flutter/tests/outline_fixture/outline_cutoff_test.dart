// Checks the plan `outline_cutoff_modules` writes: see outline_cutoff.bzl.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final plan = jsonDecode(
    File(runfiles.rlocation(args.single)).readAsStringSync(),
  ) as Map<String, dynamic>;

  /// The kernel files of a module directory, by name.
  Map<String, List<int>> dills(String rlocation) {
    final found = {
      for (final f in Directory(
        runfiles.rlocation(rlocation),
      ).listSync().whereType<File>())
        f.uri.pathSegments.last: f.readAsBytesSync(),
    };
    expect(found, isNotEmpty, reason: rlocation);
    return found;
  }

  bool same(String a, String b) {
    final x = dills(a), y = dills(b);
    return x.length == y.length &&
        x.keys.every((k) => y.containsKey(k) && _equal(x[k]!, y[k]!));
  }

  final base = (plan['base'] as Map).cast<String, String>();
  final edits = (plan['edits'] as Map).cast<String, Map>();
  Map<String, String> edit(String name) => edits[name]!.cast<String, String>();

  test('a dependent compiles against an outline', () {
    expect(base['dependency_outlines'], endsWith('.outlines'));
  });

  test('an edit inside a function body leaves the outline unchanged', () {
    final e = edit('body');
    expect(
      same(base['dependency']!, e['dependency']!),
      isFalse,
      reason: "the edit leaves the library's own module unchanged",
    );
    expect(
      same(base['dependency_outlines']!, e['dependency_outlines']!),
      isTrue,
      reason: 'dependents would be compiled again: the outline changed',
    );
    expect(same(base['dependent']!, e['dependent']!), isTrue);
  });

  test('an edit to a signature changes the outline and the dependent', () {
    final e = edit('signature');
    expect(
      same(base['dependency_outlines']!, e['dependency_outlines']!),
      isFalse,
      reason: 'dependents would not be compiled again: the outline is the same',
    );
    expect(
      same(base['dependent']!, e['dependent']!),
      isFalse,
      reason: "the edit leaves the dependent's module unchanged",
    );
  });
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
