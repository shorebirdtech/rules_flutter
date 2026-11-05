/// The golden service as a process of the host.
///
/// The service is a `flutter_test` (`flutter/private/goldens/service.dart`), so
/// it is started as one is started by Bazel: as its rule's executable, with
/// the environment its rule says. What the integration test itself was given
/// by Bazel is not its to read: the test's filter, shard and report belong to
/// the test.
library;

import 'dart:convert';
import 'dart:io';

import 'golden_comparator.dart';

/// What Bazel hands a test about its own run, which the golden service is not:
/// its selection of cases, its shard, and where it reports. A service that took
/// them would select none of its own one case, or write over the report.
const _belongsToTheTest = [
  'TESTBRIDGE_TEST_ONLY',
  'TEST_TOTAL_SHARDS',
  'TEST_SHARD_INDEX',
  'TEST_SHARD_STATUS_FILE',
  'XML_OUTPUT_FILE',
  'COVERAGE_OUTPUT_FILE',
];

/// The variable that tells the service to write goldens, not compare them.
const goldenServiceUpdateVariable = 'RULES_FLUTTER_GOLDEN_UPDATE';

/// The environment to start the golden service with: the host's, so that it
/// finds the runfiles and the test's undeclared outputs directory and, under
/// `bazel run`, the source tree, without what is the test's own; with what its
/// rule says ([service]); and [update] when goldens are to be written.
Map<String, String> goldenServiceEnvironment(
  Map<String, String> host,
  Map<String, String> service, {
  required bool update,
}) => {
  for (final entry in host.entries)
    if (!_belongsToTheTest.contains(entry.key)) entry.key: entry.value,
  ...service,
  if (update) goldenServiceUpdateVariable: '1',
};

/// Starts [executable] with exactly [environment], keeping what it prints.
Future<RunningGoldenService> startGoldenServiceProcess(
  String executable,
  Map<String, String> environment,
) async {
  final process = await Process.start(
    executable,
    const [],
    environment: environment,
    includeParentEnvironment: false,
  );
  final service = _ProcessService(process);
  for (final stream in [process.stdout, process.stderr]) {
    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(service.output.add);
  }
  return service;
}

class _ProcessService implements RunningGoldenService {
  _ProcessService(this._process);

  final Process _process;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  final output = <String>[];

  @override
  void kill() => _process.kill(ProcessSignal.sigkill);
}
