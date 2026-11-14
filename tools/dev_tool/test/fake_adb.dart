/// Stands in for `adb` in `AndroidDeviceProbe`'s tests: prints what the JSON
/// file beside this executable (`<executable>.json`) says on stdout and on
/// stderr, then exits with the code it names.
///
/// A compiled program with its script in a sidecar file, because a test has to
/// make one stub per verdict and a shell script would not start on Windows.
library;

import 'dart:convert';
import 'dart:io';

void main() {
  final script = jsonDecode(
    File('${Platform.resolvedExecutable}.json').readAsStringSync(),
  ) as Map<String, Object?>;
  stdout.write('${script['stdout']}\n');
  stderr.write('${script['stderr']}\n');
  exit(script['exitCode']! as int);
}
