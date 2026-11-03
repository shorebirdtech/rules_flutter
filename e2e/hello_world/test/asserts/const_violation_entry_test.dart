// A constant that breaks a `const` constructor's assertion. `flutter test`
// does not compile this: constant evaluation runs the assertion, and its
// failure is a compile error ("Constant evaluation error"). A `flutter_test`
// has to refuse it the same way, or code `flutter test` rejects ships here.
//
// `manual`: building `//:const_violation_entry_test` is expected to FAIL; see
// the comment on it in BUILD.bazel.
import 'package:assert_dep/guarded.dart';
import 'package:flutter_test/flutter_test.dart';

const violation = Positive(-1);

void main() {
  test('is never reached', () {
    expect(violation.n, -1);
  });
}
