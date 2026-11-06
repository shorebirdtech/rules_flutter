/// Writes `flutter/private/linux_runtime_pins.bzl`: the Debian packages the
/// Linux integration-test runtime is made of, for each architecture.
///
/// Usage:
///   bazel run //tools/update_linux_runtime -- <snapshot>
///
/// `<snapshot>` is a snapshot.debian.org timestamp (`20261104T000000Z`). The
/// tool reads Debian's package index for each architecture as it was then,
/// works out the closure of the packages `rootPackages` names, and writes each
/// package's path and sha256 as the index gives them. The runtime's downloads
/// are pinned against those digests, and the build checks what the packages
/// ask of the host (`hostRuntimeFloor`).
library;

import 'dart:convert';
import 'dart:io';

import 'debian_packages.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || !RegExp(r'^\d{8}T\d{6}Z$').hasMatch(args.single)) {
    stderr.writeln(
      'Usage: bazel run //tools/update_linux_runtime -- <snapshot>\n'
      'where <snapshot> is a snapshot.debian.org timestamp, such as '
      '20261104T000000Z.',
    );
    exit(64);
  }
  final snapshot = args.single;
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null) {
    stderr.writeln('update_linux_runtime: run it with `bazel run`.');
    exit(64);
  }
  final client = HttpClient();
  try {
    final closures = <String, List<DebianPackage>>{};
    for (final arch in architectures) {
      final uri = Uri.parse(
        'https://snapshot.debian.org/archive/debian/$snapshot/dists/$suite/'
        'main/binary-$arch/Packages.gz',
      );
      stderr.writeln('$arch: $uri');
      final index = parsePackagesIndex(await _fetchGzipText(client, uri));
      closures[arch] = resolveClosure(
        index,
        roots: rootPackages.keys,
        excluded: excludedPackages.keys.toSet(),
      );
      stderr.writeln('  ${closures[arch]!.length} packages');
    }
    final out = File('$workspace/flutter/private/linux_runtime_pins.bzl');
    out.writeAsStringSync(renderPins(snapshot, closures));
    stderr.writeln('wrote ${out.path}');
  } on Object catch (e) {
    stderr.writeln('update_linux_runtime: $e');
    exitCode = 1;
  } finally {
    client.close();
  }
}

/// snapshot.debian.org answers 503 now and then to a request that succeeds
/// when made again, so a fetch the server fails is made a few times before it
/// is reported.
const _attempts = 5;

Future<String> _fetchGzipText(HttpClient client, Uri uri) async {
  for (var attempt = 1; ; attempt++) {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode == 200) {
      return utf8.decode(
        gzip.decode(
          await response.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          ),
        ),
      );
    }
    await response.drain<void>();
    if (response.statusCode < 500 || attempt == _attempts) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    stderr.writeln('  HTTP ${response.statusCode}; trying again');
    await Future<void>.delayed(Duration(seconds: 1 << attempt));
  }
}
