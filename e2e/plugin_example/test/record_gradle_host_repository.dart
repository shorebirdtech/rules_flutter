/// Records add_to_app_host/android/gradle_repository.json, the lock of the
/// Maven repository `@gradle_host_maven` (gradle_offline_repository.bzl) the
/// host app's offline build resolves from.
///
/// Usage: `bazel run --config=deep //:record_gradle_host_repository`. It
/// builds the host app's three variants as `gradle_host_test` does, but
/// against the remote repositories and with an empty Gradle user home, then
/// locks every file Gradle downloaded: its URL, the first of the repositories
/// that has it, and its SHA-256. Run it after changing the host app's build,
/// its Android Gradle plugin, or the Flutter version (which names the
/// `io.flutter` artifacts).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'gradle_host.dart';

const _lockPath = 'add_to_app_host/android/gradle_repository.json';

/// The classifiers of an artifact the Android Gradle plugin downloads for the
/// machine it runs on (aapt2): a recording on one locks all of them, so the
/// lock serves every machine.
const _hostClassifiers = ['linux', 'osx', 'windows'];

Future<void> main(List<String> args) async {
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (args.length != 1 || workspace == null) {
    stderr.writeln(
      'usage: bazel run --config=deep //:record_gradle_host_repository '
      '(it writes $_lockPath in the workspace)',
    );
    exitCode = 2;
    return;
  }
  final work = Directory.systemTemp.createTempSync('gradle_host_record');
  final client = HttpClient();
  try {
    final host = GradleHost(args.single, work);
    final built = await host.run([
      for (final variant in hostVariants) 'assemble${_capitalized(variant)}',
    ], offline: false);
    if (built != 0) {
      stderr.writeln('The online build failed; nothing was recorded.');
      exitCode = 1;
      return;
    }

    final downloaded = _downloadedFiles(host.gradleUserHome);
    final paths = {
      ...downloaded.keys,
      for (final path in downloaded.keys) ..._otherHostClassifiers(path),
    }.toList()..sort();
    final remotes = [
      for (final r in host.repositories)
        if (r.startsWith('https:')) r,
    ];

    final files = <String, Object>{};
    for (var i = 0; i < paths.length; i += 16) {
      final batch = paths.skip(i).take(16);
      final entries = await Future.wait([
        for (final path in batch)
          _lock(client, remotes, path, downloaded[path]),
      ]);
      for (final (path, entry) in entries) {
        files[path] = entry;
      }
    }
    File('$workspace/$_lockPath').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'files': files})}\n',
    );
    stdout.writeln('Wrote $_lockPath: ${files.length} files.');
  } finally {
    client.close();
    work.deleteSync(recursive: true);
  }
}

String _capitalized(String s) => s[0].toUpperCase() + s.substring(1);

/// Every file in Gradle's download cache, by its path in a Maven repository.
///
/// The cache lays a file out as
/// `caches/modules-2/files-2.1/<group>/<module>/<version>/<sha1>/<file>`,
/// where `<file>` is the name a component's Gradle module metadata gives it.
/// The metadata also gives the file's `url` in the repository, relative to the
/// component's directory, which may differ (`datastore-core.aar` is at
/// `datastore-core-android-1.2.1.aar`) or be another version's directory
/// (Guava's `-jre` component points at its `-android` jar).
Map<String, File> _downloadedFiles(Directory gradleUserHome) {
  final cache = Directory('${gradleUserHome.path}/caches/modules-2/files-2.1');
  final byComponent = <String, List<File>>{};
  for (final file in cache.listSync(recursive: true).whereType<File>()) {
    final parts = file.path
        .substring(cache.path.length + 1)
        .split(RegExp(r'[\\/]'));
    if (parts.length != 5) {
      throw FormatException('unexpected file in Gradle cache: ${file.path}');
    }
    final [group, module, version, _, _] = parts;
    (byComponent['${group.replaceAll('.', '/')}/$module/$version'] ??= []).add(
      file,
    );
  }
  final files = <String, File>{};
  for (final MapEntry(key: directory, value: componentFiles)
      in byComponent.entries) {
    final urls = <String, String>{};
    for (final file in componentFiles.where(
      (f) => f.path.endsWith('.module'),
    )) {
      final metadata =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      for (final variant in metadata['variants'] as List<Object?>? ?? []) {
        for (final f in (variant! as Map)['files'] as List<Object?>? ?? []) {
          final {'name': String name, 'url': String url} = f! as Map;
          final path = Uri(path: '$directory/').resolve(url).path;
          if (urls[name] case final other? when other != path) {
            throw FormatException('$directory: $name is at $other and $path');
          }
          urls[name] = path;
        }
      }
    }
    for (final file in componentFiles) {
      final name = file.uri.pathSegments.last;
      files[urls[name] ?? '$directory/$name'] = file;
    }
  }
  return files;
}

/// For a file of one host's classifier, the paths of the others' files.
Iterable<String> _otherHostClassifiers(String path) sync* {
  for (final classifier in _hostClassifiers) {
    final suffix = '-$classifier.jar';
    if (!path.endsWith(suffix)) continue;
    final base = path.substring(0, path.length - suffix.length);
    for (final other in _hostClassifiers) {
      if (other != classifier) yield '$base-$other.jar';
    }
  }
}

/// The lock entry of [path]: the first of [remotes] that serves it, and the
/// SHA-256 of [cached], or of what that remote serves if nothing is cached.
Future<(String, Object)> _lock(
  HttpClient client,
  List<String> remotes,
  String path,
  File? cached,
) async {
  for (final remote in remotes) {
    final url = '$remote/$path';
    final request = await client.headUrl(Uri.parse(url));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode == HttpStatus.notFound) continue;
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HEAD $url: ${response.statusCode}');
    }
    final Digest digest;
    if (cached != null) {
      digest = sha256.convert(cached.readAsBytesSync());
    } else {
      final get = await (await client.getUrl(Uri.parse(url))).close();
      if (get.statusCode != HttpStatus.ok) {
        throw HttpException('GET $url: ${get.statusCode}');
      }
      digest = await sha256.bind(get).single;
    }
    return (path, {'sha256': digest.toString(), 'url': url});
  }
  throw StateError('no repository of $remotes has $path');
}
