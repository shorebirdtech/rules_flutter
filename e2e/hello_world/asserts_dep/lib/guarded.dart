/// Code whose `assert`s a test must be able to trip, in a library compiled
/// apart from the test's own file.
library;

/// Throws an [AssertionError] unless [n] is positive.
void requirePositive(int n) {
  assert(n > 0, 'requirePositive: $n is not positive');
}

/// A value whose `const` constructor asserts in its initializer list.
class Positive {
  /// Asserts that [n] is positive.
  const Positive(this.n) : assert(n > 0, 'Positive: $n is not positive');

  /// The checked value.
  final int n;
}
