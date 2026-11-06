/// A lock's `source: git` packages are fetched at the commit the lock records
/// and built as a hosted package is.
///
/// **The properties:**
///
///  1. A git package is its commit's tree at the repository root of its
///     spoke, whether it is the whole repository or a directory of one
///     (`description.path`); a later commit and the rest of a monorepo are not
///     there.
///  2. It is built as its pubspec says, not as a git package: a Flutter
///     plugin is a plugin, a package that bundles assets bundles them, and
///     a plain package is a plain library.
///  3. A hosted package that depends on it reaches its library.
///  4. A lock entry that pins no commit is refused when the lock is read,
///     naming the lock and the package; a commit the repository does not have
///     is refused at the fetch, naming the package.
///  5. A git package mapped to a workspace target by `resolve` is never
///     fetched.
///
/// The repositories are made on the spot (`GitPackage`), so no network is
/// involved.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

/// A pubspec with a Flutter plugin block for Android.
String _pluginPubspec(String name) =>
    'name: $name\n'
    'version: 1.0.0\n'
    'environment:\n'
    '  sdk: ^3.0.0\n'
    'flutter:\n'
    '  plugin:\n'
    '    platforms:\n'
    '      android:\n'
    '        package: dev.example.$name\n'
    '        pluginClass: Plugin\n';

void main() {
  group('the spoke of a git package is its commit', () {
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(
        git: [
          GitPackage(
            'whole',
            files: {'lib/src/whole_impl.dart': 'int impl = 1;\n'},
            laterFiles: {'lib/later.dart': 'int later = 1;\n'},
          ),
          GitPackage(
            'inner',
            repository: 'mono',
            path: 'packages/inner',
          ),
          GitPackage(
            'sibling',
            repository: 'mono',
            path: 'packages/sibling',
            laterFiles: {'README.md': 'later\n'},
          ),
        ],
      ).materialize();
    });

    test('at the repository root, without the commits after it', () async {
      final load = await ws.loadSpoke('whole');
      expect(load.succeeded, isTrue, reason: '$load');
      final dir = await ws.spokeDirectory('whole');
      expect(File(p.join(dir.path, 'pubspec.yaml')).existsSync(), isTrue);
      expect(
        File(p.join(dir.path, 'lib', 'src', 'whole_impl.dart')).existsSync(),
        isTrue,
      );
      expect(File(p.join(dir.path, 'lib', 'later.dart')).existsSync(), isFalse);
      expect(Directory(p.join(dir.path, '.git')).existsSync(), isFalse);
    });

    test('a directory of a monorepo is the root, and nothing else of the '
        'repository is there', () async {
      final load = await ws.loadSpoke('inner');
      expect(load.succeeded, isTrue, reason: '$load');
      final dir = await ws.spokeDirectory('inner');
      expect(File(p.join(dir.path, 'pubspec.yaml')).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'lib', 'inner.dart')).existsSync(), isTrue);
      expect(Directory(p.join(dir.path, 'packages')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'README.md')).existsSync(), isFalse);
    });

    test(
      'a package of one repository is another spoke than its sibling',
      () async {
        final hub = await ws.query('@pubhub//:all');
        expect(hub.succeeded, isTrue, reason: '$hub');
        expect(hub.stdout, contains('@pubhub//:inner'));
        expect(hub.stdout, contains('@pubhub//:sibling'));
        final load = await ws.loadSpoke('sibling');
        expect(load.succeeded, isTrue, reason: '$load');
        final sibling = await ws.spokeDirectory('sibling');
        expect(
          File(p.join(sibling.path, 'lib', 'sibling.dart')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(sibling.path, 'lib', 'inner.dart')).existsSync(),
          isFalse,
        );
      },
    );
  });

  group('it is built as its pubspec says', () {
    final plugin = GitPackage(
      'gplugin',
      pubspec: _pluginPubspec('gplugin'),
      files: {
        'android/src/main/kotlin/dev/example/Plugin.kt':
            'package dev.example\nclass Plugin\n',
      },
    );
    final assets = GitPackage(
      'gassets',
      pubspec:
          'name: gassets\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n'
          'flutter:\n  assets:\n    - assets/data.txt\n',
      files: {'assets/data.txt': 'x'},
    );
    final plain = GitPackage('gplain');

    Future<String> buildFile(PubInputsWorkspace ws, String name) async {
      final load = await ws.loadSpoke(name);
      expect(load.succeeded, isTrue, reason: '$load');
      final dir = await ws.spokeDirectory(name);
      return File(p.join(dir.path, 'BUILD.bazel')).readAsStringSync();
    }

    test('a plain package is a plain library, a plugin a plugin and one '
        'with assets bundles them', () async {
      final ws = await PubInputsFixture(git: [plugin, assets, plain])
          .materialize();
      final plainBuild = await buildFile(ws, 'gplain');
      final pluginBuild = await buildFile(ws, 'gplugin');
      final assetsBuild = await buildFile(ws, 'gassets');
      expect(plainBuild, contains('pub_package_member'));
      expect(plainBuild, isNot(contains('flutter_pub_member')));
      expect(pluginBuild, contains('flutter_pub_member'));
      expect(pluginBuild, contains('plugin_platforms_json'));
      expect(assetsBuild, contains('flutter_pub_member'));
      expect(assetsBuild, contains('assets/data.txt'));
      final build = await ws.bazel([
        'build',
        '--nobuild',
        '@pubhub//:gplain',
        '@pubhub//:gplugin',
        '@pubhub//:gassets',
      ]);
      expect(build.succeeded, isTrue, reason: '$build');
    });
  });

  group('a hosted package that depends on a git package', () {
    test('reaches its library', () async {
      final user = HostedPackage(
        'uses_gdep',
        pubspec:
            'name: uses_gdep\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n'
            'dependencies:\n  gdep: any\n',
      );
      final ws = await PubInputsFixture(
        hosted: [user],
        git: [GitPackage('gdep')],
        files: {
          'BUILD.bazel':
              'load("@rules_dart//dart:defs.bzl", "dart_library")\n'
              'dart_library(\n'
              '    name = "app",\n'
              '    package_name = "app",\n'
              '    srcs = ["lib/app.dart"],\n'
              '    deps = ["@pubhub//:uses_gdep"],\n'
              ')\n',
          'lib/app.dart': 'int value = 1;\n',
        },
      ).materialize();
      final deps = await ws.bazel(['cquery', '--output=label', 'deps(//:app)']);
      expect(deps.succeeded, isTrue, reason: '$deps');
      expect(deps.stdout, contains('flutter_pub_lib__gdep'), reason: '$deps');
    });
  });

  group('an entry that does not pin what is fetched', () {
    for (final ref in ['main', '0123abc']) {
      test(
        'the resolved-ref "$ref" is refused when the lock is read',
        () async {
          final ws = await PubInputsFixture(
            git: [GitPackage('unpinned', resolvedRef: ref)],
          ).materialize();
          final result = await ws.query('@pubhub//:all');
          expect(result.succeeded, isFalse, reason: '$result');
          expect(result.output, contains('unpinned'), reason: '$result');
          expect(result.output, contains('pubspec.lock'), reason: '$result');
          expect(result.output, contains('full commit id'), reason: '$result');
          expect(
            result.output,
            isNot(contains('during the fetch of repository')),
            reason: 'the refusal should come from reading the lock\n$result',
          );
        },
      );
    }

    test(
      'a commit the repository does not have is refused at the fetch',
      () async {
        final ws = await PubInputsFixture(
          git: [GitPackage('missing', resolvedRef: '0' * 40)],
        ).materialize();
        final hub = await ws.query('@pubhub//:all');
        expect(hub.succeeded, isTrue, reason: '$hub');
        final result = await ws.loadSpoke('missing');
        expect(refusedAtFetch(result), isTrue, reason: '$result');
        expect(
          namesPackage(result.output, 'missing'),
          isTrue,
          reason: '$result',
        );
      },
    );

    test('a path that is not a directory of the commit is refused at the '
        'fetch, naming it', () async {
      final ws = await PubInputsFixture(
        git: [GitPackage('nowhere', path: 'packages/nowhere')],
      ).materialize();
      // The files exist at the entry's path; the lock is rewritten to name
      // another directory of the same commit.
      final lock = ws.file('pubspec.lock');
      lock.writeAsStringSync(
        lock.readAsStringSync().replaceFirst(
          'path: "packages/nowhere"',
          'path: "packages/elsewhere"',
        ),
      );
      final result = await ws.loadSpoke('nowhere');
      expect(refusedAtFetch(result), isTrue, reason: '$result');
      expect(result.output, contains('packages/elsewhere'), reason: '$result');
    });
  });

  group('a git package mapped to a workspace target', () {
    test('is never fetched', () async {
      final ws = await PubInputsFixture(
        spokes: ['forked'],
        resolve: {'forked': '//third_party/forked:forked_fork'},
        // The repository is not there to be fetched.
        extraLockEntries:
            '  forked:\n'
            '    dependency: "direct main"\n'
            '    description:\n'
            '      path: "."\n'
            '      ref: main\n'
            '      resolved-ref: "${'a' * 40}"\n'
            '      url: "/nonexistent/forked.git"\n'
            '    source: git\n'
            '    version: "1.0.0"\n',
        files: {
          'third_party/forked/BUILD.bazel':
              'load("@rules_dart//dart:defs.bzl", "dart_library")\n'
              'dart_library(\n'
              '    name = "forked_fork",\n'
              '    package_name = "forked",\n'
              '    srcs = ["lib/forked.dart"],\n'
              '    visibility = ["//visibility:public"],\n'
              ')\n',
          'third_party/forked/lib/forked.dart': 'int value = 2;\n',
        },
      ).materialize();
      final result = await ws.bazel(['build', '--nobuild', '@pubhub//:forked']);
      expect(result.succeeded, isTrue, reason: '$result');
    });
  });
}
