/// Pub packages that depend on each other.
///
/// Pub allows a dependency cycle (`dio` imports `dio_web_adapter`, which
/// imports `dio`); Bazel does not. What must hold is the pub-side guarantee:
/// a lock that pub resolved builds, whatever its packages import, and the
/// result is what pub would give. Every package of a cycle is in the build at
/// the version the lock names, whichever one an app depends on, and each
/// member keeps what is its own: its assets bundle under `packages/<name>/`,
/// its plugin registers once.
///
/// The generated workspace is the real `flutter.pub()` hub over `file://`
/// packages (`pub_inputs_fixture.dart`); the checks are analysis-time
/// assertions over the providers a target carries, so building a check is the
/// test, and a Bazel dependency cycle shows as its own failure.
@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

/// Rules the generated workspace loads: the package graph a hub target
/// carries, and what Flutter collects over it.
const _checks = r'''
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_flutter//flutter:providers.bzl", "FlutterInfo")

def _impl(ctx):
    dart = ctx.attr.target[DartInfo]
    flutter = ctx.attr.target[FlutterInfo] if FlutterInfo in ctx.attr.target else None
    label = str(ctx.attr.target.label)
    versions = {}
    for pkg in dart.transitive_packages.to_list():
        versions.setdefault(pkg.package_name, {})[pkg.version] = True
    got_versions = {name: sorted(v.keys()) for name, v in versions.items()}
    bundled = sorted([
        "packages/%s/%s" % (a.package_name, a.asset_path)
        for a in (flutter.pub_assets.to_list() if flutter else [])
    ])
    plugins = sorted([p.name for p in (flutter.plugins if flutter else [])])
    fonts = sorted(["%s/%s" % (f.package_name, f.family) for f in (flutter.pub_fonts.to_list() if flutter else [])])

    problems = []
    for name, want in ctx.attr.versions.items():
        if got_versions.get(name) != [want]:
            problems.append("%s: package `%s` resolves at %s, expected only [%s]" % (label, name, got_versions.get(name), want))
    if sorted(ctx.attr.assets) != bundled:
        problems.append("%s: bundles assets %s, expected %s" % (label, bundled, sorted(ctx.attr.assets)))
    if sorted(ctx.attr.fonts) != fonts:
        problems.append("%s: bundles fonts %s, expected %s" % (label, fonts, sorted(ctx.attr.fonts)))
    if sorted(ctx.attr.plugins) != plugins:
        problems.append("%s: registers plugins %s, expected %s" % (label, plugins, sorted(ctx.attr.plugins)))
    if problems:
        fail("\n".join(problems))

    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

package_check = rule(
    implementation = _impl,
    attrs = {
        "target": attr.label(mandatory = True, providers = [DartInfo]),
        "versions": attr.string_dict(),
        "assets": attr.string_list(),
        "plugins": attr.string_list(),
        "fonts": attr.string_list(),
    },
)
''';

/// A pure-Dart package importing [imports], with [pubspecExtra] appended to
/// its pubspec (a `flutter:` block, say).
HostedPackage _package(
  String name,
  List<String> imports, {
  String pubspecExtra = '',
  Map<String, Object> files = const {},
}) {
  final dependencies = imports.isEmpty
      ? ''
      : 'dependencies:\n${imports.map((i) => '  $i: any\n').join()}';
  return HostedPackage(
    name,
    pubspec:
        'name: $name\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n'
        '$dependencies$pubspecExtra',
    files: {
      'lib/$name.dart':
          '${imports.map((i) => "import 'package:$i/$i.dart' as $i;\n").join()}'
          'int $name = 1;\n',
      ...files,
    },
  );
}

String _assets(String file) => 'flutter:\n  assets:\n    - assets/$file\n';

String _check(
  String name,
  String target, {
  required Map<String, String> versions,
  List<String> assets = const [],
  List<String> plugins = const [],
  List<String> fonts = const [],
}) =>
    '''
package_check(
    name = "$name",
    target = "$target",
    versions = {${versions.entries.map((e) => '"${e.key}": "${e.value}"').join(', ')}},
    assets = [${assets.map((a) => '"$a"').join(', ')}],
    plugins = [${plugins.map((p) => '"$p"').join(', ')}],
    fonts = [${fonts.map((f) => '"$f"').join(', ')}],
)
''';

void main() {
  group('packages that depend on each other', () {
    late PubInputsWorkspace ws;

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          // Two packages importing each other, each with an asset of its own.
          _package(
            'pair_a',
            ['pair_b'],
            pubspecExtra: _assets('a.txt'),
            files: {'assets/a.txt': 'a'},
          ),
          _package(
            'pair_b',
            ['pair_a'],
            pubspecExtra: _assets('b.txt'),
            files: {'assets/b.txt': 'b'},
          ),

          // A cycle of three, one of whose members depends on a package
          // outside it; and a package outside it that depends on a member.
          _package('ring_a', ['ring_b']),
          _package('ring_b', ['ring_c']),
          _package('ring_c', ['ring_a', 'ring_leaf']),
          _package('ring_leaf', []),
          _package('ring_user', ['ring_b']),

          // A plugin in a cycle with a plain package.
          _package(
            'loop_plugin',
            ['loop_helper'],
            pubspecExtra:
                'flutter:\n  plugin:\n    platforms:\n      android:\n'
                '        package: dev.example.loop_plugin\n'
                '        pluginClass: Plugin\n',
            files: {
              'android/src/main/kotlin/dev/example/Plugin.kt':
                  'package dev.example\nclass Plugin\n',
            },
          ),
          _package('loop_helper', ['loop_plugin']),

          // A package with assets in a cycle with one that has none (rules_dart's
          // own kind of member, beside Flutter's), and a package asking for the
          // Material icon font in a cycle with a plain one.
          _package(
            'mix_asset',
            ['mix_plain'],
            pubspecExtra: _assets('m.txt'),
            files: {'assets/m.txt': 'm'},
          ),
          _package('mix_plain', ['mix_asset']),
          _package(
            'icons_a',
            ['icons_b'],
            pubspecExtra: 'flutter:\n  uses-material-design: true\n',
          ),
          _package('icons_b', ['icons_a']),

          // A package a plugin overlay builds whole, in a cycle.
          _package('overlaid', ['overlaid_peer']),
          _package('overlaid_peer', ['overlaid']),
        ],
        overlayRoots: ['//overlays:BUILD.bazel'],
        files: {
          'checks.bzl': _checks,
          'overlays/BUILD.bazel': '',
          'overlays/overlaid/BUILD.bazel.tpl': 'filegroup(name = "{PKG}", srcs = [], visibility = ["//visibility:public"])\n',
          'BUILD.bazel':
              'load(":checks.bzl", "package_check")\n'
              '${_check('pair_via_a', '@pubhub//:pair_a', versions: {'pair_a': '1.0.0', 'pair_b': '1.0.0'}, assets: ['packages/pair_a/assets/a.txt', 'packages/pair_b/assets/b.txt'])}'
              '${_check('pair_via_b', '@pubhub//:pair_b', versions: {'pair_a': '1.0.0', 'pair_b': '1.0.0'}, assets: ['packages/pair_a/assets/a.txt', 'packages/pair_b/assets/b.txt'])}'
              '${_check('ring_via_b', '@pubhub//:ring_b', versions: {'ring_a': '1.0.0', 'ring_b': '1.0.0', 'ring_c': '1.0.0', 'ring_leaf': '1.0.0'})}'
              '${_check('ring_user', '@pubhub//:ring_user', versions: {'ring_a': '1.0.0', 'ring_b': '1.0.0', 'ring_c': '1.0.0', 'ring_leaf': '1.0.0', 'ring_user': '1.0.0'})}'
              '${_check('mix_via_plain', '@pubhub//:mix_plain', versions: {'mix_asset': '1.0.0', 'mix_plain': '1.0.0'}, assets: ['packages/mix_asset/assets/m.txt'])}'
              '${_check('icons_via_b', '@pubhub//:icons_b', versions: {'icons_a': '1.0.0', 'icons_b': '1.0.0'}, fonts: ['/MaterialIcons'])}'
              '${_check('overlaid_via_peer', '@pubhub//:overlaid_peer', versions: {})}'
              '${_check('loop_via_helper', '@pubhub//:loop_helper', versions: {'loop_helper': '1.0.0', 'loop_plugin': '1.0.0'}, plugins: ['loop_plugin'])}',
        },
      ).materialize();
    });

    test('a pair builds, whichever of the two an app depends on', () async {
      for (final check in ['pair_via_a', 'pair_via_b']) {
        final result = await ws.bazel(['build', '//:$check']);
        expect(result.succeeded, isTrue, reason: '$check:\n$result');
      }
    });

    test('a cycle of three builds, with its dependency outside it', () async {
      final result = await ws.bazel(['build', '//:ring_via_b']);
      expect(result.succeeded, isTrue, reason: '$result');
    });

    test('a package outside a cycle can depend on a member of it', () async {
      final result = await ws.bazel(['build', '//:ring_user']);
      expect(result.succeeded, isTrue, reason: '$result');
    });

    test('a plugin in a cycle registers once', () async {
      final result = await ws.bazel(['build', '//:loop_via_helper']);
      expect(result.succeeded, isTrue, reason: '$result');
    });

    test('a package with assets builds with one that has none', () async {
      final result = await ws.bazel(['build', '//:mix_via_plain']);
      expect(result.succeeded, isTrue, reason: '$result');
    });

    test('the Material icon font a package asks for is bundled', () async {
      final result = await ws.bazel(['build', '//:icons_via_b']);
      expect(result.succeeded, isTrue, reason: '$result');
    });

    test('each member of a cycle keeps its own Android library', () async {
      // A plugin's Kotlin is compiled once per package, whatever its Dart
      // cycle: the app's Android aggregator lists each package's.
      for (final package in ['loop_plugin', 'loop_helper']) {
        final result = await ws.query('@pubhub__$package//android:lib');
        expect(result.succeeded, isTrue, reason: '$package:\n$result');
      }
    });

    test(
      'a package built from an overlay cannot be in a cycle, and says so',
      () async {
        final result = await ws.bazel(['build', '//:overlaid_via_peer']);
        expect(result.succeeded, isFalse, reason: '$result');
        expect(result.output, contains('built from a plugin overlay'));
        expect(
          namesPackage(result.output, 'overlaid'),
          isTrue,
          reason: '$result',
        );
      },
    );
  });

  group('dio, which pub resolves with dio_web_adapter', () {
    test('both packages are in the build at the locked versions', () async {
      final ws = await PubInputsFixture(
        files: {
          'pubspec.lock': _dioLock,
          'checks.bzl': _checks,
          'BUILD.bazel':
              'load(":checks.bzl", "package_check")\n'
              '${_check('dio', '@pubhub//:dio', versions: {'dio': '5.11.1', 'dio_web_adapter': '2.2.2'})}',
        },
      ).materialize();
      final result = await ws.bazel(['build', '//:dio']);
      expect(result.succeeded, isTrue, reason: '$result');
    });
  });
}

/// `pubspec.lock` of an app depending on `dio`, as pub resolved it.
const _dioLock = '''
packages:
  async:
    dependency: transitive
    description:
      name: async
      sha256: e2eb0491ba5ddb6177742d2da23904574082139b07c1e33b8503b9f46f3e1a37
      url: "https://pub.dev"
    source: hosted
    version: "2.13.1"
  collection:
    dependency: transitive
    description:
      name: collection
      sha256: "2f5709ae4d3d59dd8f7cd309b4e023046b57d8a6c82130785d2b0e5868084e76"
      url: "https://pub.dev"
    source: hosted
    version: "1.19.1"
  dio:
    dependency: "direct main"
    description:
      name: dio
      sha256: "852ec3b48cc431ac04fff978413c541502b67ffc3e26921e74e3d994694192c1"
      url: "https://pub.dev"
    source: hosted
    version: "5.11.1"
  dio_web_adapter:
    dependency: "direct main"
    description:
      name: dio_web_adapter
      sha256: "3a1b2cd7be71086f38504956e3ebcd2837288d231ff454bafa78021244102bfc"
      url: "https://pub.dev"
    source: hosted
    version: "2.2.2"
  http_parser:
    dependency: transitive
    description:
      name: http_parser
      sha256: "178d74305e7866013777bab2c3d8726205dc5a4dd935297175b19a23a2e66571"
      url: "https://pub.dev"
    source: hosted
    version: "4.1.2"
  meta:
    dependency: transitive
    description:
      name: meta
      sha256: "307249ce4ff29d58a18e97f6345f539382eb9c9c29ecda628900f31de0443dd9"
      url: "https://pub.dev"
    source: hosted
    version: "1.19.0"
  mime:
    dependency: transitive
    description:
      name: mime
      sha256: bd47de35f07e27267e69c8c8b22edf9473bfee170a60d60fcc93730c5144b7f6
      url: "https://pub.dev"
    source: hosted
    version: "2.1.0"
  path:
    dependency: transitive
    description:
      name: path
      sha256: "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5"
      url: "https://pub.dev"
    source: hosted
    version: "1.9.1"
  source_span:
    dependency: transitive
    description:
      name: source_span
      sha256: "56a02f1f4cd1a2d96303c0144c93bd6d909eea6bee6bf5a0e0b685edbd4c47ab"
      url: "https://pub.dev"
    source: hosted
    version: "1.10.2"
  string_scanner:
    dependency: transitive
    description:
      name: string_scanner
      sha256: "921cd31725b72fe181906c6a94d987c78e3b98c2e205b397ea399d4054872b43"
      url: "https://pub.dev"
    source: hosted
    version: "1.4.1"
  term_glyph:
    dependency: transitive
    description:
      name: term_glyph
      sha256: "7f554798625ea768a7518313e58f83891c7f5024f88e46e7182a4558850a4b8e"
      url: "https://pub.dev"
    source: hosted
    version: "1.2.2"
  typed_data:
    dependency: transitive
    description:
      name: typed_data
      sha256: f9049c039ebfeb4cf7a7104a675823cd72dba8297f264b6637062516699fa006
      url: "https://pub.dev"
    source: hosted
    version: "1.4.0"
  web:
    dependency: transitive
    description:
      name: web
      sha256: e119e82ac4795c7925103b7cf3768191f33941b99e7ccffbd6c645201d9f606b
      url: "https://pub.dev"
    source: hosted
    version: "1.1.2"
sdks:
  dart: ">=3.13.0 <4.0.0"
''';
