/// A throwaway Bazel workspace around a `flutter.pub()` hub whose packages the
/// test writes, served from `file://` so no network is involved.
///
/// The hub is the real one: `flutter.pub()` in the module extension, one
/// `flutter_pub_package` repository per hosted package, `flutter_sdk_package`
/// per `sdk: flutter` entry. A test chooses what the lock holds and what each
/// archive contains, then asks Bazel to load a package of a spoke
/// ([PubInputsWorkspace.query]); the answer is whatever rules_flutter does
/// with that input.
///
/// Spokes are fetched lazily, so one workspace can hold many packages that
/// are each good or bad on its own, and a bad one fails only the query that
/// names it. An input the *extension* itself reacts to (a lock entry it
/// cannot build) fails every query, so a test of those rewrites the lock
/// between queries ([PubInputsWorkspace.writeLock]) rather than adding
/// entries.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The name of the hub. Spokes are `pubhub__<package>`.
const pubHub = 'pubhub';

/// A package archive as pub.dev would serve it: [files] relative to the
/// package root, each a `String` or a `List<int>`.
class HostedPackage {
  HostedPackage(
    this.name, {
    this.version = '1.0.0',
    Map<String, Object> files = const {},
    this.links = const {},
    String? pubspec,
  }) : files = {
         // Every package has the Dart library its own name promises, and
         // unless the test is about the pubspec, a valid one.
         'pubspec.yaml': pubspec ?? defaultPubspec(name, version),
         'lib/$name.dart': 'int value = 1;\n',
         ...files,
       };

  final String name;
  final String version;
  final Map<String, Object> files;

  /// Symbolic links in the archive: path relative to the package root to the
  /// target exactly as stored (relative to the link, or absolute), whether or
  /// not it exists.
  final Map<String, String> links;

  /// The smallest pubspec pub itself accepts for [name].
  static String defaultPubspec(String name, String version) =>
      'name: $name\nversion: $version\nenvironment:\n  sdk: ^3.0.0\n';
}

/// What `bazel` said.
class BazelResult {
  BazelResult(this.exitCode, this.stdout, this.stderr);

  /// `null` when the command had to be killed at the deadline.
  final int? exitCode;
  final String stdout;
  final String stderr;

  bool get succeeded => exitCode == 0;

  /// Everything Bazel printed, in one string for matching.
  String get output => '$stdout\n$stderr';

  @override
  String toString() =>
      'exit=$exitCode\n--- stdout\n$stdout\n--- stderr\n$stderr';
}

/// The workspace a [PubInputsFixture] materialised.
class PubInputsWorkspace {
  PubInputsWorkspace._(this._ws, this.serverUrl, this._hosted);

  final EditableWorkspace _ws;

  /// The `file://` URL the lock's hosted entries name.
  final String serverUrl;
  final List<HostedPackage> _hosted;

  String get root => _ws.root;
  File file(String relative) => _ws.file(relative);

  /// Run `bazel <args>` in the workspace.
  Future<BazelResult> bazel(List<String> args) async {
    final command = args.first;
    final process = await Process.start('bazel', [
      command,
      // `info` takes none of the build options.
      if (command != 'info') ...[
        '--noshow_progress',
        '--curses=no',
        '--color=no',
      ],
      ...args.skip(1),
    ], workingDirectory: root);
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    int? code;
    try {
      code = await process.exitCode.timeout(const Duration(minutes: 4));
    } on TimeoutException {
      process.kill();
    }
    return BazelResult(code, await out, await err);
  }

  /// Load the package of [label] (fetching its repository), and answer.
  Future<BazelResult> query(String label) => bazel(['query', label]);

  /// A package's spoke repository, as a label's repository part.
  static String spoke(String package) => '@${pubHub}__$package';

  /// Load the spoke of [package] the way a build of anything that depends on
  /// it would.
  Future<BazelResult> loadSpoke(String package) =>
      query('${spoke(package)}//:all');

  /// Where Bazel keeps the fetched files of [package]'s spoke.
  Future<Directory> spokeDirectory(String package) async {
    final base = await bazel(['info', 'output_base']);
    expect(base.succeeded, isTrue, reason: '$base');
    final external = Directory(p.join(base.stdout.trim(), 'external'));
    final matches = external
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).endsWith('+${pubHub}__$package'))
        .toList();
    expect(
      matches,
      hasLength(1),
      reason: 'the spoke directory of $package under ${external.path}',
    );
    return matches.single;
  }

  /// Replace `pubspec.lock`, for a test that changes what the hub holds.
  void writeLock(String lock) => file('pubspec.lock').writeAsStringSync(lock);

  /// The lock for the hosted packages this workspace was made with, plus
  /// [entries]: raw `packages:` entries, indented two spaces.
  String lockWith([String entries = '']) => PubInputsFixture.renderLock(
    _hosted,
    serverUrl,
    extraEntries: entries,
  );
}

/// What goes into a [PubInputsWorkspace].
class PubInputsFixture {
  PubInputsFixture({
    this.hosted = const [],
    this.extraLockEntries = '',
    this.files = const {},
    this.overlayRoots = const [],
    this.spokes = const [],
  });

  /// The hosted packages: archives are made and listed in the lock.
  final List<HostedPackage> hosted;

  /// Raw `packages:` entries appended to the lock (indented two spaces), for
  /// sources that are not hosted.
  final String extraLockEntries;

  /// Extra workspace files, by path relative to the root.
  final Map<String, String> files;

  /// Labels for `flutter.plugin_overlays(roots = [...])`.
  final List<String> overlayRoots;

  /// Spoke names to `use_repo` beyond the hosted packages' own.
  final List<String> spokes;

  /// The `pubspec.lock` text for [hosted] served from [serverUrl].
  static String renderLock(
    List<HostedPackage> hosted,
    String serverUrl, {
    String extraEntries = '',
  }) {
    final out = StringBuffer('packages:\n');
    for (final package in hosted) {
      out
        ..writeln('  ${package.name}:')
        ..writeln('    dependency: "direct main"')
        ..writeln('    description:')
        ..writeln('      name: ${package.name}')
        ..writeln('      sha256: "${_digests[package]}"')
        ..writeln('      url: "$serverUrl"')
        ..writeln('    source: hosted')
        ..writeln('    version: "${package.version}"');
    }
    out
      ..write(extraEntries)
      ..writeln('sdks:')
      ..writeln('  dart: ">=3.0.0 <4.0.0"');
    return out.toString();
  }

  static final Expando<String> _digests = Expando<String>('sha256');

  Future<PubInputsWorkspace> materialize() async {
    final server = await Directory.systemTemp.createTemp('pub_inputs_server_');
    addTearDown(() => server.delete(recursive: true));

    for (final package in hosted) {
      final tree = await Directory.systemTemp.createTemp('pub_inputs_tree_');
      try {
        for (final entry in package.files.entries) {
          final file = File(p.join(tree.path, entry.key));
          file.parent.createSync(recursive: true);
          final content = entry.value;
          if (content is String) {
            file.writeAsStringSync(content);
          } else {
            file.writeAsBytesSync(content as List<int>);
          }
        }
        for (final entry in package.links.entries) {
          final link = Link(p.join(tree.path, entry.key));
          link.parent.createSync(recursive: true);
          link.createSync(entry.value);
        }
        final archive = File(
          p.join(
            server.path,
            'packages',
            package.name,
            'versions',
            '${package.version}.tar.gz',
          ),
        );
        archive.parent.createSync(recursive: true);
        final tar = await Process.run('tar', [
          '-czf',
          archive.path,
          '-C',
          tree.path,
          '.',
        ]);
        expect(tar.exitCode, 0, reason: 'tar: ${tar.stderr}');
        _digests[package] = await _sha256(archive);
      } finally {
        tree.deleteSync(recursive: true);
      }
    }

    final serverUrl = 'file://${server.path}';
    final repo = e2eWorkspace('..');
    final root = File(p.join(repo, 'MODULE.bazel')).readAsStringSync();
    String pinned(String pattern) {
      final match = RegExp(pattern).firstMatch(root);
      if (match == null) {
        throw StateError('MODULE.bazel states no $pattern');
      }
      return match.group(1)!;
    }

    final flutterVersion = pinned(r'flutter_version\s*=\s*"([^"]+)"');
    final rulesDart = pinned(
      r'bazel_dep\(name\s*=\s*"rules_dart",\s*version\s*=\s*"([^"]+)"',
    );
    final skylib = pinned(
      r'bazel_dep\(name\s*=\s*"bazel_skylib",\s*version\s*=\s*"([^"]+)"',
    );

    final spokeNames = {
      for (final package in hosted) package.name,
      ...spokes,
    }.toList()..sort();
    final module =
        '''
module(name = "pub_inputs_scratch")

bazel_dep(name = "rules_flutter", version = "0.0.0")
bazel_dep(name = "rules_dart", version = "$rulesDart")
bazel_dep(name = "bazel_skylib", version = "$skylib")

local_path_override(
    module_name = "rules_flutter",
    path = ${jsonEncode(repo)},
)

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "$flutterVersion")
${overlayRoots.isEmpty ? '' : 'flutter.plugin_overlays(roots = ${jsonEncode(overlayRoots)})'}
flutter.pub(
    name = "$pubHub",
    lock = "//:pubspec.lock",
)
use_repo(flutter, "$pubHub"${spokeNames.map((n) => ', "${pubHub}__$n"').join()})
''';

    // `generatedWorkspace` writes exactly the files it is given, so the
    // configuration an e2e workspace gets from its own `.bazelrc` is spelled
    // out here: the repo's `.bazelversion`, and its `.bazelrc.user` (on a
    // developer machine, what points `rules_dart` at a sibling checkout).
    // The lock is switched off because that override, and the generated
    // `file://` lock, no longer match anything checked in.
    final userConfig = File(p.join(repo, '.bazelrc.user'));
    final ws = await generatedWorkspace('pub_inputs', {
      '.bazelversion': File(p.join(repo, '.bazelversion')).readAsStringSync(),
      '.bazelrc':
          'common --lockfile_mode=off\n'
          'try-import %workspace%/.bazelrc.user\n',
      if (userConfig.existsSync())
        '.bazelrc.user': userConfig.readAsStringSync(),
      'MODULE.bazel': module,
      'BUILD.bazel': '',
      'pubspec.lock': renderLock(
        hosted,
        serverUrl,
        extraEntries: extraLockEntries,
      ),
      ...files,
    });
    return PubInputsWorkspace._(ws, serverUrl, hosted);
  }
}

/// The SHA-256 of [file], hex, the way `pubspec.lock` records it.
Future<String> _sha256(File file) async {
  final tool = Platform.isMacOS ? ['shasum', '-a', '256'] : ['sha256sum'];
  final run = await Process.run(tool.first, [...tool.skip(1), file.path]);
  expect(run.exitCode, 0, reason: '${tool.first}: ${run.stderr}');
  return (run.stdout as String).split(RegExp(r'\s+')).first;
}

/// Whether [text] mentions [name] on its own: not as part of the name of a
/// repository, label or path that merely contains it.
///
/// Bazel prefixes every failure of a fetch with the repository's name, which
/// holds the package's (`pubhub__<package>`), so "the message contains the
/// package" is true of every failure and says nothing. What counts is the
/// package being named by the text that explains the failure.
bool namesPackage(String text, String name) {
  final withoutRepository = text.replaceAll(
    RegExp('[A-Za-z0-9_+@.]*${pubHub}__${RegExp.escape(name)}'),
    '',
  );
  return RegExp(
    '(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])',
  ).hasMatch(withoutRepository);
}

/// Whether [result] is rules_flutter refusing an input while fetching a
/// repository, as opposed to Bazel tripping over what it generated later
/// (a BUILD file that does not parse, a label that is not valid) or over a
/// target that is not there.
bool refusedAtFetch(BazelResult result) =>
    !result.succeeded &&
    result.output.contains('during the fetch of repository') &&
    !result.output.contains('package contains errors');

/// An Android plugin: a pubspec with `flutter.plugin.platforms.android`, one
/// Kotlin source (so the spoke builds an Android library from it), and [files]
/// besides.
HostedPackage androidPlugin(String name, Map<String, Object> files) =>
    HostedPackage(
      name,
      pubspec:
          'name: $name\n'
          'version: 1.0.0\n'
          'environment:\n'
          '  sdk: ^3.0.0\n'
          'flutter:\n'
          '  plugin:\n'
          '    platforms:\n'
          '      android:\n'
          '        package: dev.example.$name\n'
          '        pluginClass: Plugin\n',
      files: {
        'android/src/main/kotlin/dev/example/Plugin.kt':
            'package dev.example\nclass Plugin\n',
        ...files,
      },
    );

/// What the spoke of [package] recorded as the Maven dependencies of its
/// Gradle build: `android/maven_deps.json`.
Future<({List<String> coordinates, List<String> unread})> recordedMavenDeps(
  PubInputsWorkspace ws,
  String package,
) async {
  final dir = await ws.spokeDirectory(package);
  final json = jsonDecode(
    File(p.join(dir.path, 'android', 'maven_deps.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  return (
    coordinates: [
      for (final dep in json['deps']! as List)
        (dep as Map<String, Object?>)['coordinate']! as String,
    ],
    unread: [for (final line in json['errors']! as List) line as String],
  );
}
