/// Running the `bazel run` program of an add-to-app target from a test.
library;

import 'dart:io';

import 'runfiles_paths.dart';

/// Runs the `bazel run` program of the `flutter_ios_xcframeworks` or
/// `flutter_macos_xcframeworks` target [name] of the workspace's root
/// package, as `bazel run //:<name> -- --output=<dir>` would, into a new
/// directory under [parent] (or the system temp), and returns that directory.
///
/// The target's runfiles must be the test's: its program, its config and the
/// layout it writes. Exits 1 if the program fails.
String exportXcframeworks(String name, {String? output}) {
  final program = requireRunfile('$name.export', what: 'The export program');
  final destination =
      output ?? Directory.systemTemp.createTempSync('add_to_app_export').path;
  final result = Process.runSync(
    program,
    ['--output=$destination'],
    environment: {
      'RULES_FLUTTER_XCFRAMEWORKS_CONFIG': runfileKey(
        '$name.xcframeworks_export.json',
      ),
      'BUILD_WORKSPACE_DIRECTORY': destination,
      'BUILD_WORKING_DIRECTORY': destination,
    },
  );
  if (result.exitCode != 0) {
    stderr.writeln(
      'bazel run //:$name failed:\n${result.stdout}${result.stderr}',
    );
    exit(1);
  }
  return destination;
}
