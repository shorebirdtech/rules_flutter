/// Checks that a built asset bundle's `NOTICES.Z` does not depend on the host.
///
/// Run as `dart_test(args = ["<runfile path>", ...])`, each a file or directory
/// of the build in the test's runfiles.
///
/// Property: `NOTICES.Z` is a function of the licence text it holds, so the
/// same licences give the same bytes whichever machine built the bundle. A gzip
/// header carries the compressor's OS, which zlib takes from the platform it
/// was built for (3 on Linux, 19 on macOS, 10 on Windows), so a bundle built on
/// a Mac and on a Linux executor would differ by that byte and never share a
/// cache entry. The one value that names no host is 255, "unknown" in RFC 1952,
/// and the modification time must be 0.
///
/// This tests the built bundle, which is the claim users depend on. The tool
/// that writes the file has the same check as a unit test, over more inputs.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/host_leaks.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final notices = [
    for (final arg in args) ..._noticesUnder(requireRunfile(arg)),
  ];

  test('the build has a NOTICES.Z to check', () {
    expect(notices, isNotEmpty);
  });

  for (final file in notices) {
    test('${file.uri.path.split('/_main/').last} names no host', () {
      expect(
        gzipHeaderHostDependence(file.readAsBytesSync()),
        isEmpty,
        reason:
            "a gzip header with the compressor's OS in it is different "
            'bytes on each host',
      );
    });
  }
}

Iterable<File> _noticesUnder(String path) sync* {
  if (FileSystemEntity.isDirectorySync(path)) {
    for (final f in Directory(path).listSync(recursive: true)) {
      if (f is File && _isNotices(f)) yield f;
    }
  } else if (_isNotices(File(path))) {
    yield File(path);
  }
}

// By URI, whose segments are `/`-separated on Windows too, where a `File`'s
// path uses `\`.
bool _isNotices(File f) => f.uri.pathSegments.last == 'NOTICES.Z';
