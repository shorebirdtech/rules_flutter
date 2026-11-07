/// Several `flutter_pub.from_lock()` locks share one repository per package, so
/// they must agree on what a package is.
///
/// **The properties:**
///
///  1. Two hubs that list a package at one version share it: both labels reach
///     the one `flutter_pub_lib__<package>` repository, and no repository of
///     either hub's name exists.
///  2. A lock behind another on a package fails when the module is read, at
///     `on_version_conflict = "error"`, naming both locks, both versions, the
///     package and the command that fixes it. That command runs while the
///     conflict stands (the toolchain it needs is another extension's), and
///     after it the hub analyses. At `"upgrade"` it builds the higher version.
///  3. Locks that disagree on where a package comes from, or on the digest of
///     one version, fail naming both.
///  4. A package mapped with `resolve` is that target for every hub and the
///     locked package is never fetched; two different maps fail naming both.
///  5. Two tags of one name are one hub.
///
/// Package names no lock of this repository lists, so the repository's own
/// tool lock (which every consumer build reads) does not take part.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

const _otherHub = 'otherhub';

FixtureHub _other(
  List<HostedPackage> hosted, {
  String? onVersionConflict,
  String extraLockEntries = '',
  Map<String, String> resolve = const {},
  String name = _otherHub,
}) => FixtureHub(
  name: name,
  lockPackage: 'other',
  hosted: hosted,
  extraLockEntries: extraLockEntries,
  resolve: resolve,
  onVersionConflict: onVersionConflict,
);

/// A `dart_library` for [name], at `<dir>/BUILD.bazel`.
Map<String, String> _target(String dir, String name) => {
  p.posix.join(dir, 'lib', '$name.dart'): 'int value = 1;\n',
  p.posix.join(dir, 'BUILD.bazel'):
      'load("@rules_dart//dart:defs.bzl", "dart_library")\n'
      'dart_library(\n'
      '    name = "$name",\n'
      '    package_name = "$name",\n'
      '    srcs = glob(["lib/**/*.dart"]),\n'
      '    visibility = ["//visibility:public"],\n'
      ')\n',
};

void main() {
  test('two hubs listing a package share one repository', () async {
    final plain = HostedPackage('vplain');
    final ws = await PubInputsFixture(
      hosted: [plain],
      otherHubs: [
        _other([plain]),
      ],
    ).materialize();

    for (final label in ['@pubhub//:vplain', '@$_otherHub//:vplain']) {
      final result = await ws.query(label);
      expect(result.succeeded, isTrue, reason: '$result');
    }
    final deps = await ws.bazel([
      'query',
      'deps(@pubhub//:vplain + @$_otherHub//:vplain, 1)',
      '--output=label',
    ]);
    expect(deps.succeeded, isTrue, reason: '$deps');
    final libraries = deps.stdout
        .split('\n')
        .where((l) => l.endsWith('flutter_pub_lib__vplain//:vplain'))
        .toSet();
    expect(libraries, hasLength(1), reason: '$deps');
    expect(deps.stdout, isNot(contains('pubhub__vplain')));
    expect(deps.stdout, isNot(contains('${_otherHub}__vplain')));
  });

  test(
    'a lock behind another at "error" fails when the module is read',
    () async {
      final ws = await PubInputsFixture(
        hosted: [HostedPackage('vplain', version: '1.0.0')],
        otherHubs: [
          _other([HostedPackage('vplain', version: '1.1.0')]),
        ],
      ).materialize();

      final result = await ws.query('@pubhub//:vplain');
      expect(result.succeeded, isFalse, reason: '$result');
      expect(
        result.output,
        allOf(
          contains('"vplain" has conflicting versions'),
          contains('1.0.0 (hub "pubhub"'),
          contains('1.1.0 (hub "$_otherHub"'),
          contains('//:pubspec.lock'),
          contains('//other:pubspec.lock'),
          contains('pub -- upgrade vplain'),
          contains('on_version_conflict = "upgrade"'),
        ),
        reason: '$result',
      );
    },
  );

  test(
    'the command a version conflict names runs while the conflict stands, '
    'and fixes it',
    () async {
      final ws = await PubInputsFixture(
        http: true,
        lockPackage: 'app',
        hosted: [HostedPackage('vplain', version: '1.0.0')],
        files: {
          'app/pubspec.yaml':
              'name: app\n'
              'environment:\n'
              '  sdk: ^3.0.0\n'
              'dependencies:\n'
              '  vplain:\n'
              '    hosted: "{{SERVER}}"\n'
              '    version: ^1.0.0\n',
        },
        otherHubs: [
          _other([HostedPackage('vplain', version: '1.1.0')]),
        ],
      ).materialize();

      final conflict = await ws.query('@pubhub//:vplain');
      expect(conflict.succeeded, isFalse, reason: '$conflict');
      final commands = RegExp(
        r'^\s*bazel run (\S+) -- (.+)$',
        multiLine: true,
      ).allMatches(conflict.output).toList();
      expect(commands, hasLength(1), reason: '$conflict');
      final command = commands.single;

      // The cache is the test's own, so the packages of its registry do not
      // land in the developer's.
      final cache = Directory.systemTemp.createTempSync('pub_cache_');
      addTearDown(() => cache.deleteSync(recursive: true));
      final fixed = await ws.bazel(
        [
          'run',
          command.group(1)!,
          '--',
          ...command.group(2)!.trim().split(RegExp(r'\s+')),
        ],
        environment: {'PUB_CACHE': cache.path},
      );
      expect(fixed.succeeded, isTrue, reason: '$fixed');
      expect(
        ws.file('app/pubspec.lock').readAsStringSync(),
        contains('version: "1.1.0"'),
      );

      final analysed = await ws.bazel([
        'build',
        '--nobuild',
        '@pubhub//:vplain',
      ]);
      expect(analysed.succeeded, isTrue, reason: '$analysed');
    },
  );

  test(
    'a lock behind another at "upgrade" builds the higher version',
    () async {
      final ws = await PubInputsFixture(
        hosted: [HostedPackage('vplain', version: '1.0.0')],
        onVersionConflict: 'upgrade',
        otherHubs: [
          _other([HostedPackage('vplain', version: '1.1.0')]),
        ],
      ).materialize();

      final result = await ws.loadSpoke('vplain');
      expect(result.succeeded, isTrue, reason: '$result');
      final spoke = await ws.spokeDirectory('vplain');
      final pubspec = File(p.join(spoke.path, 'pubspec.yaml'))
          .readAsStringSync();
      expect(pubspec, contains('version: 1.1.0'));
    },
  );

  test(
    'a package hosted in one lock and in a repository in another fails',
    () async {
      final ws = await PubInputsFixture(
        git: [GitPackage('vplain')],
        otherHubs: [
          _other([HostedPackage('vplain')]),
        ],
      ).materialize();

      final result = await ws.query('@pubhub//:vplain');
      expect(result.succeeded, isFalse, reason: '$result');
      expect(
        result.output,
        allOf(
          contains('"vplain" comes from different sources'),
          contains('hosted 1.0.0'),
          contains('git '),
          contains('//other:pubspec.lock'),
        ),
        reason: '$result',
      );
    },
  );

  test('one version with two digests fails, naming both', () async {
    final plain = HostedPackage('vplain');
    final ws = await PubInputsFixture(
      hosted: [plain],
      otherHubs: [
        _other(
          [],
          extraLockEntries:
              '  vplain:\n'
              '    dependency: "direct main"\n'
              '    description:\n'
              '      name: vplain\n'
              '      sha256: "${'ab' * 32}"\n'
              '      url: "{{SERVER}}"\n'
              '    source: hosted\n'
              '    version: "1.0.0"\n',
        ),
      ],
    ).materialize();

    final result = await ws.query('@pubhub//:vplain');
    expect(result.succeeded, isFalse, reason: '$result');
    expect(
      result.output,
      allOf(
        contains('"vplain" 1.0.0 has different digests'),
        contains('ab' * 32),
        contains('//other:pubspec.lock'),
      ),
      reason: '$result',
    );
  });

  test(
    'a mapped package is that target for every hub, never fetched',
    () async {
      final plain = HostedPackage('vplain');
      final ws = await PubInputsFixture(
        hosted: [plain],
        resolve: {'vplain': '//mapped:vplain'},
        files: _target('mapped', 'vplain'),
        otherHubs: [
          _other([HostedPackage('vplain', version: '9.9.9')]),
        ],
      ).materialize();

      for (final hub in ['pubhub', _otherHub]) {
        final deps = await ws.bazel([
          'query',
          'deps(@$hub//:vplain, 2)',
          '--output=label',
        ]);
        expect(deps.succeeded, isTrue, reason: '$deps');
        expect(deps.stdout, contains('//mapped:vplain'), reason: '$deps');
      }
      // The repository is the mapped target's forwarder: none of a package's
      // files, though two of the locks list one.
      final spoke = await ws.spokeDirectory('vplain');
      expect(File(p.join(spoke.path, 'pubspec.yaml')).existsSync(), isFalse);
    },
  );

  test('a package mapped to two targets fails, naming both', () async {
    final plain = HostedPackage('vplain');
    final ws = await PubInputsFixture(
      hosted: [plain],
      resolve: {'vplain': '//mapped:vplain'},
      files: {..._target('mapped', 'vplain'), ..._target('remapped', 'vplain')},
      otherHubs: [
        _other([plain], resolve: {'vplain': '//remapped:vplain'}),
      ],
    ).materialize();

    final result = await ws.query('@pubhub//:vplain');
    expect(result.succeeded, isFalse, reason: '$result');
    expect(
      result.output,
      allOf(
        contains('"vplain" is mapped to different targets'),
        contains('//mapped:vplain'),
        contains('//remapped:vplain'),
      ),
      reason: '$result',
    );
  });

  test('two tags of one name are one hub holding both locks', () async {
    final ws = await PubInputsFixture(
      hosted: [HostedPackage('vone')],
      otherHubs: [
        _other([HostedPackage('vtwo')], name: 'pubhub'),
      ],
    ).materialize();

    final hub = await ws.query('@pubhub//:all');
    expect(hub.succeeded, isTrue, reason: '$hub');
    expect(hub.stdout, contains('@pubhub//:vone'));
    expect(hub.stdout, contains('@pubhub//:vtwo'));
  });
}
