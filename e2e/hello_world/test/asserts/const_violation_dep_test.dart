// The same, with the invalid constant in a library the test depends on rather
// than in the test's own file. `manual`; see `//:const_violation_dep_test`.
import 'package:assert_violation_dep/const_violation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('is never reached', () {
    expect(violation.n, -1);
  });
}
