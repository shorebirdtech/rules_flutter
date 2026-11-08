/// Prints the Maven artifacts an Android build needs, as the lines to paste
/// into `maven.install(name = "rules_android_maven", artifacts = [...])`.
///
/// Two kinds of line:
///
/// * The artifacts the Android plugins' Gradle builds declare, at the highest
///   version any of them declares, as Gradle gives a plugin.
/// * Artifacts the install resolves that Gradle would raise. A library
///   published with Gradle module metadata can constrain the versions of
///   its companions: androidx `activity` 1.9.0 requires `activity-ktx`, if
///   present, to be 1.9.0 too, because classes moved between them. Gradle
///   honours those constraints; rules_jvm_external reads only POMs and
///   leaves an old `-ktx` artifact beside a new main one, whose classes then
///   conflict. So this reads the `.module` file of every artifact the
///   install resolves, from the install's repositories, as rules_jvm_external's
///   own `outdated` does, and raises what a constraint asks to raise, until
///   nothing changes.
///
/// Usage: `maven_artifacts <runfiles path of the report's JSON>`, which
/// `flutter_android_maven` (every plugin of the build) and
/// `flutter_android_maven_report` (an application's) write: `repo`, `app`
/// (or null), `requirements` (coordinate to `version` and `declared_by`),
/// `resolved` (coordinate to version) and `repositories`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// What the plugins declare for one artifact.
class Requirement {
  Requirement(this.version, this.declaredBy);

  /// The highest version declared, or null when none names one.
  final String? version;
  final List<String> declaredBy;
}

/// An artifact raised by another's Gradle module metadata.
class Alignment {
  Alignment(this.version, this.by);

  final String version;

  /// The `group:artifact version` whose constraint asks for [version].
  final String by;
}

/// A dependency constraint of a module's Gradle metadata.
typedef Constraint = ({String coordinate, String version});

/// The dependency constraints of the Gradle module metadata [json], of
/// every variant.
///
/// A constraint that names no single version (`rejects` alone, or a range)
/// raises nothing, and is left out.
List<Constraint> constraintsOf(String json) {
  final metadata = jsonDecode(json) as Map<String, Object?>;
  final constraints = <Constraint>{};
  for (final variant in (metadata['variants'] as List? ?? const [])) {
    for (final constraint
        in ((variant as Map)['dependencyConstraints'] as List? ?? const [])) {
      final c = constraint as Map;
      final version = c['version'] as Map? ?? const {};
      final wanted = (version['strictly'] ?? version['requires']) as String?;
      if (wanted == null || _isRange(wanted)) continue;
      constraints.add((
        coordinate: '${c['group']}:${c['module']}',
        version: wanted,
      ));
    }
  }
  return constraints.toList();
}

bool _isRange(String version) =>
    version.contains(RegExp(r'[\[\](),+]')) || version.startsWith('latest.');

/// Raises the artifacts of [start] (coordinate to version) as the
/// constraints of their Gradle module metadata ask, until nothing changes.
///
/// [constraints] gives the constraints of one version of one artifact. A
/// constraint on an artifact [start] lacks adds nothing, as in Gradle.
Future<Map<String, Alignment>> align(
  Map<String, String> start,
  Future<List<Constraint>> Function(String coordinate, String version)
  constraints,
) async {
  final versions = Map.of(start);
  final aligned = <String, Alignment>{};
  var pending = versions.entries.map((e) => (e.key, e.value)).toList();
  while (pending.isNotEmpty) {
    final found = await Future.wait([
      for (final (coordinate, version) in pending)
        constraints(
          coordinate,
          version,
        ).then((list) => (coordinate, version, list)),
    ]);
    final raised = <String>{};
    for (final (coordinate, version, list) in found) {
      for (final constraint in list) {
        final have = versions[constraint.coordinate];
        if (have == null || compareVersions(have, constraint.version) >= 0) {
          continue;
        }
        versions[constraint.coordinate] = constraint.version;
        aligned[constraint.coordinate] = Alignment(
          constraint.version,
          '$coordinate $version',
        );
        raised.add(constraint.coordinate);
      }
    }
    pending = [for (final c in raised) (c, versions[c]!)];
  }
  return aligned;
}

/// The text the program prints.
///
/// [requirements] are the plugins' declarations, [resolved] what the install
/// resolves, [aligned] the result of [align] over both.
String formatReport({
  required String repo,
  required String? app,
  required Map<String, Requirement> requirements,
  required Map<String, String> resolved,
  required Map<String, Alignment> aligned,
}) {
  final lines = <String>[];
  var changed = 0;
  for (final coordinate in requirements.keys.toList()..sort()) {
    final req = requirements[coordinate]!;
    final alignment = aligned[coordinate];
    var version = req.version;
    final notes = <String>[];
    if (alignment != null &&
        (version == null || compareVersions(alignment.version, version) > 0)) {
      version = alignment.version;
      notes.add('aligned with ${alignment.by}');
    }
    final have = resolved[coordinate];
    if (have == null) {
      notes.add('missing');
    } else if (version != null && compareVersions(have, version) < 0) {
      notes.add('resolves $have');
    }
    if (have == null || notes.isNotEmpty) changed++;
    lines.add(
      _line(coordinate, version, [
        'declared by ${req.declaredBy.join(', ')}',
        ...notes,
      ]),
    );
  }
  final alignedOnly = [
    for (final coordinate in aligned.keys.toList()..sort())
      if (!requirements.containsKey(coordinate)) coordinate,
  ];
  for (final coordinate in alignedOnly) {
    final alignment = aligned[coordinate]!;
    lines.add(
      _line(coordinate, alignment.version, [
        'aligned with ${alignment.by}',
        'resolves ${resolved[coordinate]}',
      ]),
    );
  }

  final out = <String>[
    app == null
        ? '# Maven artifacts the Android plugins of @$repo declare.'
        : '# Maven artifacts the Android plugins that $app links declare.',
  ];
  if (requirements.isEmpty) {
    out.add('# The plugins declare none.');
  } else if (changed > 0) {
    out.add(
      '# $changed of ${requirements.length} are missing or too low in '
      '@rules_android_maven (marked).',
    );
  } else {
    out.add(
      '# All ${requirements.length} are provided by @rules_android_maven.',
    );
  }
  if (alignedOnly.isNotEmpty) {
    out.add(
      '# ${alignedOnly.length} more '
      '${alignedOnly.length == 1 ? 'resolves' : 'resolve'} lower than the '
      'Gradle module metadata of another artifact asks for: Gradle would '
      'raise ${alignedOnly.length == 1 ? 'it' : 'them'} (marked).',
    );
  }
  if (lines.isEmpty) {
    out.add('# None.');
  } else {
    out
      ..add(
        '# Paste into maven.install(name = "rules_android_maven", '
        'artifacts = [...]):',
      )
      ..add('')
      ..addAll(lines.map((line) => '        $line'));
  }
  return '${out.join('\n')}\n';
}

String _line(String coordinate, String? version, List<String> notes) =>
    '"$coordinate:${version ?? '<version>'}",  # ${notes.join('; ')}';

/// The Gradle module metadata of [coordinate] at [version], from the first of
/// [repositories] that has it, or null when none does: the artifact was
/// published without it.
///
/// [get] returns a URL's body, or null for a 404.
Future<String?> moduleMetadata(
  String coordinate,
  String version,
  List<String> repositories,
  Future<String?> Function(Uri url) get,
) async {
  final [group, artifact] = coordinate.split(':');
  final path =
      '${group.replaceAll('.', '/')}/$artifact/$version/'
      '$artifact-$version.module';
  for (final repository in repositories) {
    final base = repository.endsWith('/') ? repository : '$repository/';
    final body = await get(Uri.parse('$base$path'));
    if (body != null) return body;
  }
  return null;
}

/// Fetches [url] with [client]: the body, or null for a 404.
///
/// Anything else (another status, no connection) throws: a report that left
/// an artifact out because a repository did not answer would be wrong
/// without saying so.
Future<String?> _get(HttpClient client, Uri url) async {
  final request = await client.getUrl(url);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: url);
  }
  return body;
}

/// Runs tasks at most [limit] at a time.
class _Pool {
  _Pool(this.limit);

  final int limit;
  var _running = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

/// Compares Maven versions as Maven's ComparableVersion does, simplified:
/// tokens split on `.`, `-` and digit/letter transitions; numbers compare
/// numerically with missing ones as 0; qualifiers order alpha < beta <
/// milestone < rc < snapshot < release < sp, unknown ones after, lexically.
int compareVersions(String a, String b) {
  final ta = _tokens(a);
  final tb = _tokens(b);
  for (var i = 0; i < ta.length || i < tb.length; i++) {
    final c = _compareTokens(
      i < ta.length ? ta[i] : null,
      i < tb.length ? tb[i] : null,
    );
    if (c != 0) return c;
  }
  return 0;
}

const _qualifierRank = {
  'alpha': 0,
  'a': 0,
  'beta': 1,
  'b': 1,
  'milestone': 2,
  'm': 2,
  'rc': 3,
  'cr': 3,
  'snapshot': 4,
  '': 5,
  'ga': 5,
  'final': 5,
  'release': 5,
  'sp': 6,
};
const _releaseRank = 5;
const _unknownRank = 7;

List<Object> _tokens(String version) {
  final tokens = <Object>[];
  final current = StringBuffer();
  bool? numeric;
  void flush() {
    if (current.isEmpty) return;
    final text = current.toString();
    tokens.add(numeric! ? int.parse(text) : text);
    current.clear();
  }

  for (final c in version.toLowerCase().split('')) {
    if (c == '.' || c == '-' || c == '_') {
      flush();
      continue;
    }
    final digit = c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
    if (current.isNotEmpty && digit != numeric) flush();
    current.write(c);
    numeric = digit;
  }
  flush();
  return tokens;
}

(int, String) _qualifierKey(String qualifier) {
  final rank = _qualifierRank[qualifier];
  return rank == null ? (_unknownRank, qualifier) : (rank, '');
}

int _compareKeys((int, String) a, (int, String) b) =>
    a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2).sign;

int _comparePresent(Object a, Object? b) {
  if (a is int) {
    if (b == null) return a == 0 ? 0 : 1;
    if (b is int) return a.compareTo(b).sign;
    return 1;
  }
  final ka = _qualifierKey(a as String);
  if (b == null) return _compareKeys(ka, (_releaseRank, ''));
  if (b is int) return -1;
  return _compareKeys(ka, _qualifierKey(b as String));
}

int _compareTokens(Object? a, Object? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -_comparePresent(b!, null);
  return _comparePresent(a, b);
}

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: maven_artifacts <runfiles path of the report>');
    exit(2);
  }
  final data = jsonDecode(
    File(Runfiles.create().rlocation(args.single)).readAsStringSync(),
  ) as Map<String, Object?>;
  final requirements = {
    for (final MapEntry(:key, :value)
        in (data['requirements'] as Map<String, Object?>).entries)
      key: Requirement(
        (value as Map)['version'] as String?,
        (value['declared_by'] as List).cast<String>(),
      ),
  };
  final resolved = (data['resolved'] as Map).cast<String, String>();
  final repositories = (data['repositories'] as List).cast<String>();

  // What the install would resolve once the plugins' lines are pasted in.
  final start = Map.of(resolved);
  for (final MapEntry(:key, value: req) in requirements.entries) {
    final have = start[key];
    if (have != null &&
        req.version != null &&
        compareVersions(have, req.version!) < 0) {
      start[key] = req.version!;
    }
  }

  final client = HttpClient();
  final pool = _Pool(16);
  try {
    final aligned = await align(start, (coordinate, version) async {
      final json = await pool.run(
        () => moduleMetadata(
          coordinate,
          version,
          repositories,
          (url) => _get(client, url),
        ),
      );
      return json == null ? const [] : constraintsOf(json);
    });
    stdout.write(
      formatReport(
        repo: data['repo'] as String,
        app: data['app'] as String?,
        requirements: requirements,
        resolved: resolved,
        aligned: aligned,
      ),
    );
  } on Exception catch (e) {
    stderr.writeln(
      'Could not read the Gradle module metadata of the artifacts '
      '@rules_android_maven resolves from ${repositories.join(', ')}: $e',
    );
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}
