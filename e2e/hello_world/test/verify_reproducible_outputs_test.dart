/// Checks that built outputs hold nothing about the machine that built them.
///
/// Run as `dart_test(args = ["<runfile path>", ...])`, each argument a file or
/// directory of the build in the test's runfiles, such as `hello_world.dill`
/// or `hello_world_web_web`.
///
/// Property: every output is a function of its declared inputs only. It holds
/// no absolute path of the build's execroot or output base, no sandbox number,
/// no home directory or user name. (The one byte that depends on the host OS,
/// in `NOTICES.Z`, has its own test.) Two builds of the same inputs on
/// different machines, or in different sandbox slots of one machine, then give
/// identical bytes, and the second finds the first's result in a shared cache.
///
/// Why this is the right property to defend, and what it is not:
///
///  * Bazel's contract for an action is that its outputs depend on its declared
///    inputs and its command line; a sandbox number and an output-base path are
///    neither, and every Bazel action that wants a remote or disk cache hit
///    across checkouts depends on this. rules_dart already holds its own
///    compiles to it.
///  * It is not "no absolute path ever": the Dart SDK's doc strings reach every
///    kernel and name `file:///home/myself/...`, and those are the same bytes
///    on every host. The markers are the ones that name *this* build.
///  * It scans the bytes rather than comparing two builds because Bazel's
///    caches would replay the first build's bytes for the second and hide the
///    difference; the scan finds the cause directly.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/host_leaks.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  late HostMarkers markers;

  setUpAll(() {
    // The runfiles directory lies under the build's execroot, which is where
    // the output base is read from.
    markers = HostMarkers.forBuildHost([
      ?Platform.environment['TEST_SRCDIR'],
      ...args.map(requireRunfile),
    ]);
    expect(
      markers.markers.map((m) => m.label),
      contains(startsWith('output base /')),
      reason:
          'the test could not tell where the build ran, so would pass a '
          'leak of it',
    );
  });

  for (final arg in args) {
    test('$arg names neither the sandbox nor the builder', () {
      final leaks = markers.inTree(requireRunfile(arg));
      expect(
        leaks.isEmpty,
        isTrue,
        reason:
            "a file that holds the build's own paths is different bytes on "
            'every machine and sandbox slot:\n${leaks.join('\n')}',
      );
    });
  }
}
