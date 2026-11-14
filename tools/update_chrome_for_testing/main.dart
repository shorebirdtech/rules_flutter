/// Prints the `CHROME_FOR_TESTING` entry for `flutter/private/versions.bzl`.
///
/// Usage:
///   bazel run //tools/update_chrome_for_testing             # the Stable channel
///   bazel run //tools/update_chrome_for_testing -- 157.0.8103.38
///
/// Downloads each host's headless shell archive and hashes it, then prints the
/// entry to replace the one in versions.bzl. The download is pinned against that
/// digest, so a version is adopted by reading what this prints.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'chrome_for_testing.dart';

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    stderr.writeln(
      'Usage: bazel run //tools/update_chrome_for_testing -- [<chrome-version>]',
    );
    exit(64);
  }
  final client = HttpClient();
  try {
    final version = args.isEmpty
        ? stableVersion(await _fetchText(client, lastKnownGoodUri))
        : args.single;
    stderr.writeln('Chrome for Testing $version');
    final digests = <String, String>{};
    for (final platform in platforms) {
      final uri = headlessShellUri(version, platform);
      stderr.writeln('  $platform: $uri');
      digests[platform] = await _sha256Of(client, uri);
    }
    print(renderEntry(version, digests));
  } on Object catch (e) {
    stderr.writeln('update_chrome_for_testing: $e');
    exitCode = 1;
  } finally {
    client.close();
  }
}

Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
  final response = await (await client.getUrl(uri)).close();
  if (response.statusCode != 200) {
    await response.drain<void>();
    throw HttpException('HTTP ${response.statusCode}', uri: uri);
  }
  return response;
}

Future<String> _fetchText(HttpClient client, Uri uri) async => utf8.decode(
  await (await _get(
    client,
    uri,
  )).fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
);

Future<String> _sha256Of(HttpClient client, Uri uri) async =>
    (await sha256.bind(await _get(client, uri)).first).toString();
