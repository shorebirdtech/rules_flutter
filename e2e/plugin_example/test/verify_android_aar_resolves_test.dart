/// Resolves the Maven repositories `flutter_android_aar` builds as a Gradle
/// host would, without Gradle and without the network: every coordinate their
/// POMs name must be found.
///
/// Starting from each repository's module POM, every dependency is looked up
/// where a host finds it:
///
/// * an artifact of the repository itself (the plugins'): its POM at the
///   exact version, at the path its coordinate gives, declaring that
///   coordinate, with its archive (`.aar`) beside it, and then its own
///   dependencies in turn;
/// * an `io.flutter` artifact (the engine's), from Flutter's Maven repository:
///   the POM of that coordinate, pinned by sha256 in MODULE.bazel;
/// * anything else (what the plugins' Gradle builds declare), from Google's
///   Maven or Maven Central: an artifact `@rules_flutter_maven`'s lock pins at
///   that version or a newer one, which a host's resolution takes as Gradle
///   does, the highest version asked for.
///
/// And every artifact of the repository must be reached from the module.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';
import 'package:runfiles/runfiles.dart';

/// One POM: the coordinate it declares and the dependencies it lists.
class Pom {
  Pom(this.path, String xml)
    : group = _project(xml, 'groupId'),
      artifact = _project(xml, 'artifactId'),
      version = _project(xml, 'version'),
      packaging = _project(xml, 'packaging') ?? 'jar',
      dependencies = [
        for (final m in RegExp(
          r'<dependency>([\s\S]*?)</dependency>',
        ).allMatches(xml))
          Dependency(
            _tag(m[1]!, 'groupId')!,
            _tag(m[1]!, 'artifactId')!,
            _tag(m[1]!, 'version')!,
          ),
      ];

  final String path;
  final String? group;
  final String? artifact;
  final String? version;
  final String packaging;
  final List<Dependency> dependencies;

  String get coordinate => '$group:$artifact:$version';

  /// A tag of the project itself, not of a dependency or of its parent.
  static String? _project(String xml, String tag) => _tag(
    xml.replaceAll(RegExp(r'<dependencies>[\s\S]*?</dependencies>'), ''),
    tag,
  );

  static String? _tag(String xml, String tag) =>
      RegExp('<$tag>([^<]*)</$tag>').firstMatch(xml)?.group(1)?.trim();
}

class Dependency {
  Dependency(this.group, this.artifact, this.version);
  final String group;
  final String artifact;
  final String version;
  String get key => '$group:$artifact';
  String get coordinate => '$group:$artifact:$version';
}

/// Maven's order of two versions, for the numeric versions artifacts have.
int compareVersions(String a, String b) {
  final x = a.split(RegExp('[.-]'));
  final y = b.split(RegExp('[.-]'));
  for (var i = 0; i < x.length || i < y.length; i++) {
    final p = i < x.length ? x[i] : '0';
    final q = i < y.length ? y[i] : '0';
    final m = int.tryParse(p);
    final n = int.tryParse(q);
    final c = m != null && n != null ? m.compareTo(n) : p.compareTo(q);
    if (c != 0) return c;
  }
  return 0;
}

void main() {
  final check = BundleCheck();
  final runfiles = Runfiles.create();

  // Flutter's engine artifacts, by coordinate.
  final engine = <String, Pom>{};
  for (final rlocation
      in (Platform.environment['FLUTTER_MAVEN_POMS'] ?? '').split(' ')) {
    if (rlocation.isEmpty) continue;
    final path = runfiles.rlocation(rlocation);
    final pom = Pom(path, File(path).readAsStringSync());
    engine[pom.coordinate] = pom;
  }
  check.expect(
    'the engine POMs pinned in MODULE.bazel are given to the test',
    condition: engine.isNotEmpty,
  );

  // What `@rules_flutter_maven` pins: group:artifact to version.
  final lock = jsonDecode(
    File(
      requireRunfile('rules_flutter_maven_install.json', what: 'Lock'),
    ).readAsStringSync(),
  ) as Map<String, Object?>;
  final pinned = <String, String>{
    for (final MapEntry(:key, :value)
        in (lock['artifacts']! as Map<String, Object?>).entries)
      key.split(':').take(2).join(':'):
          (value! as Map<String, Object?>)['version']! as String,
  };

  const module = 'com.example.plugin_example.module';
  for (final (name, root) in [
    ('plugin_module_repo_release', '$module:flutter_release:1.0'),
    ('plugin_module_repo_debug', '$module:flutter_debug:1.0'),
    ('annotated_module_aar_repo', '$module:flutter_release:1.0'),
    // A workspace plugin's module, in its own package.
    (
      'glass_app/glass_module_aar_repo',
      'com.example.glass_app.module:flutter_release:1.0',
    ),
  ]) {
    _resolve(
      check,
      name,
      requireRunfile(name, what: 'Repository'),
      root,
      engine,
      pinned,
    );
  }
  check.finish(
    '\nEvery coordinate the repositories name resolves, as a Gradle host '
    'resolves it.',
  );
}

void _resolve(
  BundleCheck check,
  String name,
  String repo,
  String root,
  Map<String, Pom> engine,
  Map<String, String> pinned,
) {
  // The repository's own artifacts, each checked to sit where its coordinate
  // says, with its archive.
  final local = <String, Pom>{};
  for (final f in Directory(repo).listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.pom')) continue;
    final pom = Pom(f.path, f.readAsStringSync());
    final relative = f.path.substring(repo.length + 1).replaceAll(r'\', '/');
    final expected =
        '${pom.group?.replaceAll('.', '/')}/${pom.artifact}/${pom.version}/'
        '${pom.artifact}-${pom.version}.pom';
    if (relative != expected) {
      check.fail(
        '$name: $relative declares ${pom.coordinate}, whose POM is $expected',
      );
    }
    final archive = f.path.replaceAll(RegExp(r'\.pom$'), '.${pom.packaging}');
    if (!File(archive).existsSync()) {
      check.fail(
        '$name: ${pom.coordinate} is packaged as ${pom.packaging}, and '
        'there is no $archive',
      );
    }
    local[pom.coordinate] = pom;
  }

  final reached = <String>{};
  final pending = [root];
  var engineCount = 0;
  var external = 0;
  while (pending.isNotEmpty) {
    final coordinate = pending.removeLast();
    if (!reached.add(coordinate)) continue;
    final pom = local[coordinate];
    if (pom == null) {
      check.fail('$name: $coordinate is not in the repository');
      continue;
    }
    for (final d in pom.dependencies) {
      if (local.containsKey(d.coordinate)) {
        pending.add(d.coordinate);
      } else if (d.group == 'io.flutter') {
        engineCount++;
        final found = engine[d.coordinate];
        if (found == null) {
          check.fail(
            '$name: ${pom.coordinate} depends on ${d.coordinate}, which is not '
            'among the engine POMs pinned in MODULE.bazel '
            '(${engine.keys.toList()..sort()})',
          );
        }
      } else {
        external++;
        final version = pinned[d.key];
        if (version == null) {
          check.fail(
            '$name: ${pom.coordinate} depends on ${d.coordinate}, which '
            '@rules_flutter_maven does not pin',
          );
        } else if (compareVersions(version, d.version) < 0) {
          check.fail(
            '$name: ${pom.coordinate} depends on ${d.coordinate}, and '
            '@rules_flutter_maven pins the older $version',
          );
        }
      }
    }
  }
  check.expect(
    '$name: from $root, ${reached.length} artifacts of the repository, '
    '$engineCount engine dependencies and $external others resolve',
    condition: reached.length == local.length && engineCount > 0,
    detail:
        'not reached from the module: '
        '${local.keys.where((k) => !reached.contains(k)).toList()}',
  );
}
