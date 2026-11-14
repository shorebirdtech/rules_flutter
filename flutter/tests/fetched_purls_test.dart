// A package really fetched says what it is, for any SBOM tool: the purls in the
// package metadata of the closure are exactly the expected ones.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

String _purl(Runfiles runfiles, String path) {
  final metadata = jsonDecode(
    File(runfiles.rlocation(path)).readAsStringSync(),
  );
  return (metadata as Map<String, Object?>)['purl']! as String;
}

void main() {
  final runfiles = Runfiles.create();
  final env = Platform.environment;
  final got = [
    for (final path in env['PACKAGE_METADATA']!.split(' '))
      _purl(runfiles, path),
  ]..sort();
  final want = env['PURLS']!.split(' ')..sort();
  if (got.join(' ') != want.join(' ')) {
    stderr.writeln('purls:\n  got  $got\n  want $want');
    exit(1);
  }
}
