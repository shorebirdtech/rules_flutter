/// A constant that breaks a `const` constructor's assertion, in a dependency.
///
/// `flutter test` refuses to compile this: it evaluates the assertion while it
/// folds the constant. See `//:const_violation_dep_test`.
library;

import 'package:assert_dep/guarded.dart';

/// Not a valid [Positive].
const violation = Positive(-1);
