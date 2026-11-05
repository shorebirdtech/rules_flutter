// The golden comparison of an integration test, run where `dart:ui` is.
//
// An integration test runs in an app, and the host runner that drives it is a
// plain Dart program: it has no `dart:ui`, which comparing two PNGs needs, and
// the app may be on a phone that has none of the files. `flutter test` solves
// the same problem with a `flutter_tester` that runs the comparator for the
// tool (`TestGoldenComparator` in `flutter_tools`). This is that program, as a
// `flutter_test` the host runner starts when the first golden is asked for:
// `flutter_test` has already built what a `flutter_tester` needs, and the
// comparison is the one every `flutter_test` here makes
// (`BazelGoldenFileComparator`), so a golden means the same thing under both.
//
// The host runner dials nothing and is dialed: it listens on a loopback port it
// names in `RULES_FLUTTER_GOLDEN_SERVICE_PORT`, and this connects to it. Both
// speak one JSON object per line.
//
//   request:  {"id": 3, "op": "compare" | "update", "key": "goldens/x.png",
//              "bytes": "<base64 of the PNG>"}
//   response: {"id": 3, "matched": true}  a comparison that passed, or a golden
//                                         written, which also says "wrote": the
//                                         file's path
//          or {"id": 3, "error": "..."}   a comparison that could not be made,
//                                         or failed, in the comparator's words
//
// `compare` is how a failing comparison is told apart from an error only in
// the message: `LocalFileComparator` throws for a mismatch, with the diff
// written where the failure images go, and returns true otherwise.
//
// The host closes the connection when the test is over, and the program ends.
//
// What it compares for is in the environment:
//
//   RULES_FLUTTER_GOLDEN_TEST_PATH      the `short_path` of the integration
//                                       test's source: goldens are relative to
//                                       its directory.
//   RULES_FLUTTER_GOLDEN_UPDATE         `1` to write goldens into the source
//                                       tree instead of comparing, as
//                                       `bazel run //<test> -- --update-goldens`
//                                       does for a `flutter_test`.
//
// and the rest is the Bazel test's own, which the host passes on:
// `TEST_UNDECLARED_OUTPUTS_DIR`, `TEST_TARGET`, `BUILD_WORKSPACE_DIRECTORY`,
// the runfiles.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'comparator.dart';

const _portVariable = 'RULES_FLUTTER_GOLDEN_SERVICE_PORT';
const _testPathVariable = 'RULES_FLUTTER_GOLDEN_TEST_PATH';
const _updateVariable = 'RULES_FLUTTER_GOLDEN_UPDATE';

/// Answers one request of the host with [comparator].
///
/// Public, and separate from the socket, so that the service's decisions are
/// not tied to a process to be tested.
Future<Map<String, Object?>> answerGoldenRequest(
  Map<String, Object?> request,
  BazelGoldenFileComparator comparator,
) async {
  final id = request['id'];
  try {
    final key = Uri.parse(request['key']! as String);
    final bytes = base64.decode(request['bytes']! as String);
    switch (request['op']) {
      case 'compare':
        return {'id': id, 'matched': await comparator.compare(bytes, key)};
      case 'update':
        await comparator.update(key, bytes);
        return {'id': id, 'matched': true, 'wrote': comparator.lastWritten};
      default:
        return {'id': id, 'error': 'unknown operation "${request['op']}"'};
    }
  } on Object catch (e) {
    // A comparison that fails says why by throwing: a mismatch a
    // `FlutterError`, a golden that is not there a `TestFailure`.
    return {'id': id, 'error': e is TestFailure ? e.message ?? '$e' : '$e'};
  }
}

/// The comparator this service compares with, for the test and mode the host
/// named.
BazelGoldenFileComparator comparatorFromEnvironment(Map<String, String> env) {
  final testPath = env[_testPathVariable];
  if (testPath == null || testPath.isEmpty) {
    throw StateError(
      'golden service: $_testPathVariable is not set, so there is no test '
      'file to root the goldens at. The integration test runner sets it.',
    );
  }
  return BazelGoldenFileComparator.forTest(
    testPath,
    environment: env,
    update: env[_updateVariable] == '1',
  );
}

void main() {
  // The test runner's per-test default would end the service after 30 seconds;
  // it ends when the host closes the connection, or Bazel ends the test.
  test('serves goldens to the integration test runner', () async {
    final port = int.tryParse(Platform.environment[_portVariable] ?? '');
    if (port == null) {
      fail(
        '$_portVariable is not the port of the integration test runner. This '
        'program is started by it.',
      );
    }
    final comparator = comparatorFromEnvironment(Platform.environment);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    try {
      await for (final line
          in socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(
                const LineSplitter(),
              )) {
        final response = await answerGoldenRequest(
          json.decode(line) as Map<String, Object?>,
          comparator,
        );
        socket.writeln(json.encode(response));
        await socket.flush();
      }
    } finally {
      socket.destroy();
    }
  }, timeout: Timeout.none);
}
