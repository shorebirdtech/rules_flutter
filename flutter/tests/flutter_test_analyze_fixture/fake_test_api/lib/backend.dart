/// Stands in for `package:test_api`, which the root workspace has no pub hub
/// to supply.
///
/// `flutter_test` refuses `deps` that do not transitively expose
/// `package:test_api`, and matches on the package name alone. The fixture's
/// test imports this file as a real test imports its test package, so the
/// dependency is used; the test is never run (it is `manual`), and only its
/// analysis closure is exercised.
library;

/// What the fixture's test reads, so its import is used.
const String backendPlaceholder = 'test_api';
