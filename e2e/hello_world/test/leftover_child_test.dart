// A test may start a process that outlives flutter_tester and keeps its
// stdout open. The target still ends once the suite is reported: this one's
// child sleeps past the target's own timeout, so a runner that waits for the
// tester's output to close fails it with TIMEOUT.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test("leaves a child holding the tester's stdout", () async {
    final sh = await Process.start('sh', [
      '-c',
      'sleep 600 &',
    ], mode: ProcessStartMode.inheritStdio);
    expect(await sh.exitCode, 0);
  });
}
