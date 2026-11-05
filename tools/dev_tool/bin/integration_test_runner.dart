/// The host side of `flutter_*_integration_test`: runs the app an integration
/// test rule built and reports the suite it runs.
///
/// Started by Bazel as the test's executable, with
/// `FLUTTER_INTEGRATION_TEST_CONFIG` naming, in the runfiles, the JSON the rule
/// wrote (see `IntegrationRunnerConfig`).
import 'dart:async';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import '../lib/integration/integration_runner_config.dart';
import '../lib/integration/integration_test_run.dart';

/// Canonical name of the repository this binary is built in, which runfiles
/// paths are resolved from; set by the BUILD target.
const _runfilesSourceRepo = String.fromEnvironment('RUNFILES_SOURCE_REPO');

Future<void> main() async {
  final configPath = Platform.environment['FLUTTER_INTEGRATION_TEST_CONFIG'];
  if (configPath == null || configPath.isEmpty) {
    stderr.writeln(
      'integration_test: FLUTTER_INTEGRATION_TEST_CONFIG is not set. This '
      'program is the executable of a flutter_*_integration_test rule and is '
      'started by `bazel test`.',
    );
    exit(64);
  }

  final Runfiles runfiles;
  final IntegrationRunnerConfig config;
  try {
    runfiles = Runfiles.create(sourceRepository: _runfilesSourceRepo);
    final file = runfiles.rlocation(configPath);
    config = IntegrationRunnerConfig.parse(
      File(file).readAsStringSync(),
      origin: file,
    );
  } on Object catch (e) {
    stderr.writeln(
      'integration_test: cannot read the config at $configPath: '
      '${e is FormatException ? e.message : e}',
    );
    exit(64);
  }

  final DeviceChoice choice;
  try {
    choice = chooseDevice(
      config,
      os: Platform.operatingSystem,
      log: stderr.writeln,
    );
  } on StateError catch (e) {
    stderr.writeln('integration_test: ${e.message}');
    exit(1);
  }

  exitCode = await runIntegrationTest(
    config,
    resolve: runfiles.rlocation,
    choice: choice,
    environment: Platform.environment,
  );
  // The app's VM service and its log pumps are stopped by now, but a live
  // handle in a dependency would keep the process; the result is final.
  await stdout.flush();
  await stderr.flush();
  exit(exitCode);
}
