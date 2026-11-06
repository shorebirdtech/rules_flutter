/// What a test file's library annotations say, read the way `flutter test`
/// reads them.
///
/// `package:test` parses `@Tags`, `@TestOn`, `@Timeout`, `@Skip` and
/// `@OnPlatform` from the source of the test file, on the host, and sends them
/// in the handshake; the suite then gives every group and test the library's
/// tags. A runner that speaks the protocol itself has to do the same, so this
/// calls `test_core`'s own parser rather than keeping a second one to match.
library;

import 'package:test_api/backend.dart' show Runtime;
// The parser is the one `flutter test` runs; `test_core` exports no public
// entry point for it.
// ignore: implementation_imports
import 'package:test_core/src/runner/parse_metadata.dart';

/// The tags [contents], the source of the test file [displayPath], declares on
/// its library with `@Tags`.
///
/// Throws [FormatException] when the file's annotations cannot be read: a
/// `@Tags` that is not a constant list of strings, a file without a `main`, or
/// source the parser rejects. `flutter test` reports each as a load failure,
/// and a run that skipped them would select on tags it never saw.
Set<String> libraryTags(String displayPath, String contents) {
  try {
    return parseMetadata(displayPath, contents, {
      for (final runtime in Runtime.builtIn) runtime.identifier,
    }).tags;
  } on FormatException {
    rethrow;
  } on Object catch (e) {
    throw FormatException('$e');
  }
}
