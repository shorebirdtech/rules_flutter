/// A throwaway Bazel workspace around a `flutter.pub()` hub whose packages the
/// test writes, served from `file://` so no network is involved.
///
/// The hub is the real one: `flutter.pub()` in the module extension, one
/// `flutter_pub_package` repository per hosted package and per `sdk: flutter`
/// entry but `flutter` (whose `flutter_framework_package` is its own). A test
/// chooses what the lock holds and what each archive contains, then asks Bazel
/// to load a package of a spoke
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

/// The name of the hub. Spokes are `flutter_pub__<package>`, the build's.
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

/// A package a lock takes from a repository (`source: git`): its [files] go in
/// the repository's first commit, at [path], and the lock names that commit.
/// Packages with the same [repository] share one, so a monorepo's packages are
/// each locked at their own directory of it.
class GitPackage {
  GitPackage(
    this.name, {
    this.version = '1.0.0',
    this.path = '.',
    String? repository,
    String? pubspec,
    Map<String, String> files = const {},
    this.laterFiles = const {},
    this.resolvedRef,
  }) : repository = repository ?? name,
       files = {
         'pubspec.yaml': pubspec ?? HostedPackage.defaultPubspec(name, version),
         'lib/$name.dart': 'int value = 1;\n',
         ...files,
       };

  final String name;
  final String version;

  /// The package's directory in the repository, as the lock's `description.path`.
  final String path;
  final String repository;

  /// Relative to [path].
  final Map<String, String> files;

  /// Repository-relative files of a second commit, so the lock names a commit
  /// that is no longer the tip.
  final Map<String, String> laterFiles;

  /// What the lock says instead of the first commit's id.
  final String? resolvedRef;
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
  PubInputsWorkspace._(
    this._ws,
    this.serverUrl,
    this._hosted,
    this._lockPackage,
  );

  final EditableWorkspace _ws;

  /// The directory of `pubspec.lock`, relative to the root; empty for the root.
  final String _lockPackage;

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
  static String spoke(String package) => '@flutter_pub__$package';

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
        .where((d) => p.basename(d.path).endsWith('+flutter_pub__$package'))
        .toList();
    expect(
      matches,
      hasLength(1),
      reason: 'the spoke directory of $package under ${external.path}',
    );
    return matches.single;
  }

  /// Replace `pubspec.lock`, for a test that changes what the hub holds.
  void writeLock(String lock) =>
      file(p.posix.join(_lockPackage, 'pubspec.lock')).writeAsStringSync(lock);

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
    this.resolve = const {},
    this.lockPackage = '',
    this.git = const [],
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

  /// `flutter.pub(resolve = {...})`: package name to the label of its target.
  /// The packages' files go in [files], their lock entries in
  /// [extraLockEntries].
  final Map<String, String> resolve;

  /// The packages the lock takes from repositories made on the spot.
  final List<GitPackage> git;

  /// The Bazel package of `pubspec.lock`, so a monorepo's lock sits at
  /// `apps/app/pubspec.lock`; empty for the root.
  final String lockPackage;

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

    final repositories = await _makeRepositories(git, server);
    final gitEntries = StringBuffer();
    for (final package in git) {
      final repository = repositories[package.repository]!;
      gitEntries
        ..writeln('  ${package.name}:')
        ..writeln('    dependency: "direct main"')
        ..writeln('    description:')
        ..writeln('      path: "${package.path}"')
        ..writeln('      ref: main')
        ..writeln(
          '      resolved-ref: "${package.resolvedRef ?? repository.first}"',
        )
        ..writeln('      url: "${repository.directory}"')
        ..writeln('    source: git')
        ..writeln('    version: "${package.version}"');
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
      for (final package in git) package.name,
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
    lock = "//$lockPackage:pubspec.lock",
${resolve.isEmpty ? '' : '    resolve = {${resolve.entries.map((e) => '${jsonEncode(e.key)}: ${jsonEncode(e.value)}').join(', ')}},'}
)
use_repo(flutter, "$pubHub"${spokeNames.map((n) => ', "flutter_pub__$n"').join()})
''';

    // `generatedWorkspace` writes exactly the files it is given, so the
    // configuration an e2e workspace gets from its own `.bazelrc` is spelled
    // out here: the repo's `.bazelversion`, and its `.bazelrc.user` (on a
    // developer machine, what points `rules_dart` at a sibling checkout).
    // The lock is switched off because that override, and the generated
    // `file://` lock, no longer match anything checked in.
    final userConfig = repositoryUserConfigFor(repo, module);
    final ws = await generatedWorkspace('pub_inputs', {
      '.bazelversion': File(p.join(repo, '.bazelversion')).readAsStringSync(),
      '.bazelrc':
          'common --lockfile_mode=off\n'
          'try-import %workspace%/.bazelrc.user\n',
      if (userConfig != null) '.bazelrc.user': userConfig,
      'MODULE.bazel': module,
      'BUILD.bazel': '',
      if (lockPackage.isNotEmpty) p.posix.join(lockPackage, 'BUILD.bazel'): '',
      p.posix.join(lockPackage, 'pubspec.lock'): renderLock(
        hosted,
        serverUrl,
        extraEntries: extraLockEntries + gitEntries.toString(),
      ),
      ...files,
    });
    return PubInputsWorkspace._(ws, serverUrl, hosted, lockPackage);
  }
}

/// A repository made for [GitPackage]s: where it is, and its first commit.
typedef _Repository = ({String directory, String first});

/// The environment git runs in: none of the host's configuration (a
/// `commit.gpgsign` there would otherwise try to sign the fixture's commits),
/// and fixed authors.
Map<String, String> _gitEnvironment(Directory home) => {
  'HOME': home.path,
  'XDG_CONFIG_HOME': home.path,
  'PATH': Platform.environment['PATH'] ?? '',
  'GIT_CONFIG_NOSYSTEM': '1',
  'GIT_CONFIG_GLOBAL': '/dev/null',
  'GIT_AUTHOR_NAME': 'fixture',
  'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
  'GIT_COMMITTER_NAME': 'fixture',
  'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
};

/// One repository per distinct [GitPackage.repository], under [root]: the
/// packages' files in a first commit, their later files in a second.
Future<Map<String, _Repository>> _makeRepositories(
  List<GitPackage> packages,
  Directory root,
) async {
  final home = Directory(p.join(root.path, 'home'))..createSync();
  final environment = _gitEnvironment(home);
  Future<String> run(Directory dir, List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: dir.path,
      environment: environment,
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 0, reason: 'git $args: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  void write(Directory dir, String path, String content) {
    final file = File(p.join(dir.path, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  final made = <String, _Repository>{};
  final names = {for (final package in packages) package.repository};
  for (final name in names) {
    final dir = Directory(p.join(root.path, 'repositories', name))
      ..createSync(recursive: true);
    await run(dir, ['init', '-q', '--initial-branch=main']);
    final members = packages.where((package) => package.repository == name);
    for (final package in members) {
      for (final file in package.files.entries) {
        write(dir, p.posix.join(package.path, file.key), file.value);
      }
    }
    await run(dir, ['add', '-A']);
    await run(dir, ['commit', '-q', '--no-verify', '-m', 'first']);
    final first = await run(dir, ['rev-parse', 'HEAD']);
    for (final package in members) {
      for (final file in package.laterFiles.entries) {
        write(dir, file.key, file.value);
      }
    }
    await run(dir, ['add', '-A']);
    await run(dir, [
      'commit',
      '-q',
      '--no-verify',
      '--allow-empty',
      '-m',
      'later',
    ]);
    made[name] = (directory: dir.path, first: first);
  }
  return made;
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
/// holds the package's (`flutter_pub__<package>`), so "the message contains the
/// package" is true of every failure and says nothing. What counts is the
/// package being named by the text that explains the failure.
bool namesPackage(String text, String name) {
  final withoutRepository = text.replaceAll(
    RegExp('[A-Za-z0-9_+@.]*flutter_pub(_lib)?__${RegExp.escape(name)}'),
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
/// Gradle build: `flutter_android_maven_deps.json`, at its root.
Future<({List<String> coordinates, List<String> unread})> recordedMavenDeps(
  PubInputsWorkspace ws,
  String package,
) async {
  final dir = await ws.spokeDirectory(package);
  final json = jsonDecode(
    File(
      p.join(dir.path, 'flutter_android_maven_deps.json'),
    ).readAsStringSync(),
  ) as Map<String, Object?>;
  return (
    coordinates: [
      for (final dep in json['deps']! as List)
        (dep as Map<String, Object?>)['coordinate']! as String,
    ],
    unread: [for (final line in json['errors']! as List) line as String],
  );
}
