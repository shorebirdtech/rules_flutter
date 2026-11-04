/// How a hosted pub package's archive is fetched and laid out.
///
/// **The properties** (what `dart pub get` guarantees about a hosted package,
/// held by the repository rule that stands in for it):
///
///  1. Every hosted archive is checked against the digest `pubspec.lock`
///     records. A lock entry without one (a pub older than 2.19 wrote it, or
///     someone edited it) is refused when the lock is read, naming the lock and
///     the package. An empty digest means "do not check" to Bazel's
///     downloader, so accepting it would fetch that package on trust.
///  2. A symbolic link in an archive that leaves the package, or points at
///     nothing, is not extracted: pub's own extraction skips it. One that stays
///     inside the package is kept. The package a build sees is the package pub
///     would have unpacked, so a link cannot make a build read outside it.
///
/// A correct digest still fetches offline: that is
/// `digest_pinned_e2e_test.dart`, with the refusals of the repository rule
/// itself in `digest_missing_e2e_test.dart`.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

void main() {
  group('a lock entry without a digest', () {
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [HostedPackage('good')],
        spokes: ['undigested'],
        extraLockEntries: '''
  undigested:
    dependency: "direct main"
    description:
      name: undigested
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
''',
      ).materialize();
    });

    test('is refused when the lock is read, naming the lock and the '
        'package', () async {
      // The hub loads every spoke lazily, so a refusal that waits for the
      // fetch of `undigested` never happens to a query of the hub.
      final result = await ws.query('@pubhub//:all');
      expect(
        result.succeeded,
        isFalse,
        reason: 'the hub loaded with a package that has no digest\n$result',
      );
      expect(
        result.output,
        isNot(contains('during the fetch of repository')),
        reason:
            'the refusal should come from reading the lock, not from a '
            'later fetch\n$result',
      );
      expect(
        result.output,
        contains('pubspec.lock'),
        reason: 'the refusal should name the lock\n$result',
      );
      expect(
        namesPackage(result.output, 'undigested'),
        isTrue,
        reason: 'the refusal should name the package\n$result',
      );
      expect(
        result.output,
        contains('sha256'),
        reason: 'the refusal should say what is missing\n$result',
      );
    });
  });

  group('links in an archive', () {
    late PubInputsWorkspace ws;
    late Directory spoke;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          HostedPackage(
            'linked',
            links: {
              // Stays in the package.
              'lib/alias.dart': 'linked.dart',
              'lib/inner/up.dart': '../linked.dart',
              // Leaves it: to an existing directory above the package, to a
              // file by an absolute path, and through a link that leaves it.
              'lib/escape_dir': '../..',
              'lib/escape_abs.dart': '/etc/hosts',
              'lib/hop.dart': 'escape_abs.dart',
              // Points at nothing.
              'lib/dangling.dart': 'missing.dart',
            },
          ),
        ],
      ).materialize();
      final fetched = await ws.bazel(['fetch', '--repo=@pubhub__linked']);
      expect(fetched.succeeded, isTrue, reason: '$fetched');
      spoke = await ws.spokeDirectory('linked');
    });

    FileSystemEntityType kind(String relative) => FileSystemEntity.typeSync(
      p.join(spoke.path, relative),
      followLinks: false,
    );

    for (final name in [
      'lib/escape_dir',
      'lib/escape_abs.dart',
      'lib/hop.dart',
      'lib/dangling.dart',
    ]) {
      test(
        '$name, which leaves the package or points at nothing, is removed',
        () {
          expect(kind(name), FileSystemEntityType.notFound);
        },
        skip: Platform.isWindows ? 'symbolic links need privileges' : false,
      );
    }

    for (final name in ['lib/alias.dart', 'lib/inner/up.dart']) {
      test('$name, which stays in the package, is kept', () {
        expect(kind(name), FileSystemEntityType.link);
        expect(
          File(p.join(spoke.path, name)).readAsStringSync(),
          'int value = 1;\n',
        );
      }, skip: Platform.isWindows ? 'symbolic links need privileges' : false);
    }

    test('the package still loads', () async {
      final result = await ws.loadSpoke('linked');
      expect(result.succeeded, isTrue, reason: '$result');
    });
  });
}
