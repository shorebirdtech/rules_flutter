// `assert`s fire in a `flutter_test`, wherever the asserting code sits: the
// test's own file, a library the test depends on, an initializer list, and the
// framework itself. `flutter test` compiles with assertions on, so a test that
// relies on one tripping (or a library whose misuse should surface) behaves the
// same here.
//
// `//:asserts_fire_test` runs this in both kernel modes (per-library modules
// and whole-program) and in `-c fastbuild` and `-c dbg`; see the variants
// beside it in BUILD.bazel.
import 'package:assert_dep/guarded.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Const-constructible, asserting in its initializer list.
class _Entry {
  const _Entry(this.n) : assert(n > 0, '_Entry: $n is not positive');

  final int n;
}

void _entryBodyAssert(int n) {
  assert(n > 0, '_entryBodyAssert: $n is not positive');
}

/// Zero, to a compiler that cannot see through `int.parse`: keeps the
/// constructors below out of constant evaluation.
int _zero() => int.parse('0');

Matcher _assertionError(String message) => throwsA(
  isA<AssertionError>().having(
    (e) => e.toString(),
    'message',
    contains(message),
  ),
);

void main() {
  test("an assert in the test's own file fires", () {
    expect(
      () => _entryBodyAssert(_zero()),
      _assertionError('_entryBodyAssert'),
    );
  });

  test("an assert in a dependency's library fires", () {
    expect(() => requirePositive(_zero()), _assertionError('requirePositive'));
  });

  test("an initializer-list assert in the test's own file fires", () {
    expect(() => _Entry(_zero()), _assertionError('_Entry'));
  });

  test("an initializer-list assert in a dependency's library fires", () {
    expect(() => Positive(_zero()), _assertionError('Positive'));
  });

  test("an assert in the framework's const constructor fires", () {
    expect(
      () => Opacity(opacity: double.parse('2')),
      throwsA(isA<AssertionError>()),
    );
  });

  test('a valid value passes every one of them', () {
    _entryBodyAssert(1);
    requirePositive(1);
    expect(_Entry(1 + _zero()).n, 1);
    expect(Positive(1 + _zero()).n, 1);
    expect(Opacity(opacity: double.parse('0.5')).opacity, 0.5);
  });
}
