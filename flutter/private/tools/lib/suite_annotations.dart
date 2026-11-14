/// What a test file's library annotations say, read the way `flutter test`
/// reads them.
///
/// `package:test` parses `@Tags`, `@TestOn`, `@Timeout`, `@Skip` and
/// `@OnPlatform` from the source of the test file, on the host, and sends them
/// in the handshake; the suite then gives every group and test the library's
/// metadata. A runner that speaks the protocol itself has to do the same, so
/// this calls `test_core`'s own parser rather than keeping a second one to
/// match.
///
/// `flutter test` runs every suite, widget tests and integration tests alike
/// and whatever the device, as runtime `vm` on the host's operating system, so
/// that is the platform `@TestOn` and `@OnPlatform` are evaluated against.
library;

import 'package:test_api/backend.dart' show Metadata, Runtime, SuitePlatform;
import 'package:test_api/scaffolding.dart' show Timeout;
// The parser is the one `flutter test` runs; `test_core` exports no public
// entry point for it.
// ignore: implementation_imports
import 'package:test_core/src/runner/parse_metadata.dart';

import 'remote_suite.dart' show suitePlatform;

/// The annotations on the library of one test file.
class SuiteAnnotations {
  SuiteAnnotations._(this._metadata, this._platform);

  final Metadata _metadata;
  final SuitePlatform _platform;

  /// Reads the annotations of [contents], the source of the test file
  /// [displayPath].
  ///
  /// Throws [FormatException] when the file's annotations cannot be read: a
  /// `@Tags` that is not a constant list of strings, a `@TestOn` selector that
  /// names no platform, a file without a `main`, or source the parser rejects.
  /// `flutter test` reports each as a load failure, and a run that skipped them
  /// would select on annotations it never saw.
  factory SuiteAnnotations.parse(String displayPath, String contents) {
    try {
      return SuiteAnnotations._(
        parseMetadata(displayPath, contents, {
          for (final runtime in Runtime.builtIn) runtime.identifier,
        }),
        SuitePlatform.deserialize(suitePlatform()),
      );
    } on FormatException {
      rethrow;
    } on Object catch (e) {
      throw FormatException('$e');
    }
  }

  /// A file that declares nothing, for a program that has no test file to read.
  SuiteAnnotations.none()
    : _metadata = Metadata(),
      _platform = SuitePlatform.deserialize(suitePlatform());

  /// The tags the library declares with `@Tags`.
  Set<String> get tags => _metadata.tags;

  /// Why the suite is not run on this host, as text naming the `@TestOn`
  /// selector and the platform; null when it is run.
  ///
  /// `package:test` does not load a suite whose `@TestOn` does not match, so
  /// the program is not started for it.
  String? get exclusion {
    if (_metadata.testOn.evaluate(_platform)) return null;
    return '@TestOn("${_metadata.testOn}") does not match the platform '
        '${_platform.runtime.identifier} on ${_platform.os.identifier}';
  }

  /// The metadata the handshake carries: everything the library declares, with
  /// the suite's default timeout merged as [mergeTimeout] says.
  Map<String, Object?> handshakeMetadata(String? bazelTestTimeout) => _metadata
      .change(timeout: mergeTimeout(bazelTestTimeout, _metadata.timeout))
      .serialize();
}

/// The timeout of a suite whose Bazel limit is [bazelTestTimeout] (seconds,
/// `TEST_TIMEOUT`) and whose library declares [library] (`Timeout.factor(1)`
/// when it declares none).
///
/// Bazel's own limit takes the place of `package:test`'s 30-second default, as
/// `dart_test` sets it, and merges with the library's as `Timeout.merge` does:
/// a `@Timeout` duration replaces it, a factor scales it and `Timeout.none`
/// removes it. It is not `none` by default: `Timeout.merge` lets `none` on
/// either side win, so that would discard a limit a test's author wrote on a
/// case to catch a hang. Outside `bazel test` there is no limit to state, so
/// the default is none, which a `@Timeout` duration still replaces.
Timeout mergeTimeout(String? bazelTestTimeout, Timeout library) {
  final seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) {
    return library.duration == null ? Timeout.none : library;
  }
  return Timeout(Duration(seconds: seconds)).merge(library);
}
