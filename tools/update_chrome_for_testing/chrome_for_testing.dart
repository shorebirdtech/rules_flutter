/// What the updater knows about Chrome for Testing: which hosts it pins, where
/// each archive is, and how an entry for `CHROME_FOR_TESTING` is written.
///
/// Pure, so that what the updater prints can be checked without a network.
library;

import 'dart:convert';

/// The hosts `CHROME_FOR_TESTING` pins, by Chrome for Testing's name for each.
///
/// The `flutter_chrome_for_testing_<platform>` repositories and the `chrome`
/// runner's `select` name the same four; a host missing here is one a web
/// integration test is skipped on.
const platforms = ['linux64', 'mac-arm64', 'mac-x64', 'win64'];

const _origin = 'https://storage.googleapis.com/chrome-for-testing-public';

/// The listing of the newest build of each release channel, with its downloads.
final lastKnownGoodUri = Uri.parse(
  'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json',
);

/// The headless shell archive of [version] for [platform].
///
/// The same URL `chrome_for_testing_url` in `flutter/private/artifact_urls.bzl`
/// builds; the download is pinned against the digest this tool prints for it.
Uri headlessShellUri(String version, String platform) => Uri.parse(
  '$_origin/$version/$platform/chrome-headless-shell-$platform.zip',
);

/// The version of the Stable channel in the [listing] (`lastKnownGoodUri`'s
/// body), checked to have a headless shell for every pinned host.
///
/// Throws a [FormatException] saying what is missing.
String stableVersion(String listing) {
  final Object? decoded = json.decode(listing);
  final Object? channels = decoded is Map ? decoded['channels'] : null;
  final Object? stable = channels is Map ? channels['Stable'] : null;
  if (stable is! Map || stable['version'] is! String) {
    throw const FormatException(
      'the Chrome for Testing listing names no Stable version',
    );
  }
  final offered = <String>{
    for (final d
        in (stable['downloads'] as Map?)?['chrome-headless-shell'] as List? ??
            const [])
      if (d is Map && d['platform'] is String) d['platform'] as String,
  };
  final missing = platforms.where((p) => !offered.contains(p)).toList();
  if (missing.isNotEmpty) {
    throw FormatException(
      'Stable ${stable['version']} has no chrome-headless-shell for '
      '${missing.join(', ')}; pick a version that does, or drop the host from '
      'CHROME_FOR_TESTING and from the `chrome` runner.',
    );
  }
  return stable['version'] as String;
}

/// The `CHROME_FOR_TESTING` entry for [version], with the sha256 of each
/// host's archive in [digests], as it is written in `versions.bzl`.
String renderEntry(String version, Map<String, String> digests) {
  final missing = platforms.where((p) => digests[p] == null).toList();
  if (missing.isNotEmpty) {
    throw ArgumentError('no digest for ${missing.join(', ')}');
  }
  for (final MapEntry(:key, :value) in digests.entries) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw ArgumentError('the digest of $key is not 64 lowercase hex: $value');
    }
  }
  final sorted = [...platforms]..sort();
  return [
    'CHROME_FOR_TESTING = struct(',
    '    version = "$version",',
    "    # Platform (Chrome for Testing's name) to the sha256 of its",
    '    # chrome-headless-shell archive.',
    '    sha256 = {',
    for (final p in sorted) '        "$p": "${digests[p]}",',
    '    },',
    ')',
  ].join('\n');
}
