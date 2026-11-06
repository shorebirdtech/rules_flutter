import 'dart:convert';

import 'package:test/test.dart';

import '../chrome_for_testing.dart';

final _digests = {
  'linux-arm64': 'e' * 64,
  'linux64': 'a' * 64,
  'mac-arm64': 'b' * 64,
  'mac-x64': 'c' * 64,
  'win64': 'd' * 64,
};

String _listing({
  String version = '157.0.1.1',
  List<String> shells = const [
    'linux-arm64',
    'linux64',
    'mac-arm64',
    'mac-x64',
    'win64',
  ],
}) => json.encode({
  'channels': {
    'Beta': {'version': '158.0.0.0', 'downloads': <String, Object?>{}},
    'Stable': {
      'version': version,
      'downloads': {
        'chrome': [
          {'platform': 'linux64', 'url': 'x'},
        ],
        'chrome-headless-shell': [
          for (final p in shells) {'platform': p, 'url': 'u'},
        ],
      },
    },
  },
});

void main() {
  group('stableVersion', () {
    test(
      'is the Stable channel, not another, when each pinned host has a shell',
      () {
        expect(stableVersion(_listing()), '157.0.1.1');
      },
    );

    test('names the host a version has no headless shell for', () {
      expect(
        () => stableVersion(_listing(shells: ['mac-arm64', 'win64'])),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('linux-arm64, linux64, mac-x64'),
          ),
        ),
      );
    });

    test('refuses a listing with no Stable channel', () {
      expect(() => stableVersion('{"channels": {}}'), throwsFormatException);
    });
  });

  group('headlessShellUri', () {
    test('is the archive the repository rule fetches', () {
      expect(
        headlessShellUri('157.0.1.1', 'mac-arm64').toString(),
        'https://storage.googleapis.com/chrome-for-testing-public/157.0.1.1/mac-arm64/chrome-headless-shell-mac-arm64.zip',
      );
    });
  });

  group('renderEntry', () {
    test('is the entry as versions.bzl writes it, hosts in name order', () {
      expect(renderEntry('157.0.1.1', _digests), '''
CHROME_FOR_TESTING = struct(
    version = "157.0.1.1",
    # Platform (Chrome for Testing's name) to the sha256 of its
    # chrome-headless-shell archive.
    sha256 = {
        "linux-arm64": "${'e' * 64}",
        "linux64": "${'a' * 64}",
        "mac-arm64": "${'b' * 64}",
        "mac-x64": "${'c' * 64}",
        "win64": "${'d' * 64}",
    },
)''');
    });

    test('refuses an entry that leaves a host unpinned', () {
      expect(
        () => renderEntry('157.0.1.1', {..._digests}..remove('win64')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('refuses a digest that is not a sha256', () {
      expect(
        () => renderEntry('157.0.1.1', {..._digests, 'win64': 'XYZ'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
