/// Checks that no two jars an Android app links define one class differently,
/// and that no Maven library reaches the app from two repositories.
///
/// An app's deploy jar, the classes it dexes, takes every jar that reaches
/// `android_binary` and keeps the first copy of each class. Two jars that
/// define a class differently are two versions of one library (or an old
/// artifact whose classes moved into a newer one), and the app would run a
/// mix that neither version is: Gradle resolves one version of each library
/// instead, aligning the artifacts of one library through the version
/// constraints of their Gradle module metadata. So the build fails, naming
/// the jars. Two such jars can also be harmless (two copies of one interface
/// either of which works, or a class shadowed on purpose), so the message
/// names `--@rules_flutter//flutter:allow_duplicate_classes`, under which the
/// rule passes no jars.
///
/// Classes are compared by the CRC-32 of their bytes, which a jar's central
/// directory records, so no class is read.
///
/// Not compared:
///
/// * Resource classes, `R` and `R$<type>`. Each Android library carries its
///   own, with placeholder ids, for its code to compile against;
///   `android_binary` generates the app's with the final ids and its copy is
///   the one the deploy jar keeps.
/// * `module-info.class` and everything under `META-INF/`: a modular jar's
///   module descriptor and multi-release copies, which are not classes an
///   Android app loads.
///
/// Nor may one Maven library, a `group:artifact` (with its packaging and
/// classifier, if any), reach the app from two rules_jvm_external
/// repositories. Each repository is a resolution of its own, so the app would
/// carry two copies at versions picked apart: equal today, they part when
/// either is re-pinned. Gradle resolves one version of each library for an
/// app, and `@rules_flutter_maven` is that one resolution. The build fails
/// naming the library and both targets.
///
/// On success the tool writes `--stamp`, which the build requires so that a
/// conflict fails the build.
///
/// The tool has no package dependencies and runs with the bare Dart SDK, so it
/// runs on any host.
///
/// Usage:
///   dart check_android_classes.dart @<params>
///
/// where the params file holds, one per line: `--app <label>`,
/// `--report <label>`, `--stamp <file>`, then for each jar `--jar <file>
/// <origin>`, in the order the deploy jar takes them; `<origin>` names the
/// jar in the message (its Maven coordinates, or its target). Then for each
/// of those jars that rules_jvm_external imported, `--maven <target>
/// <coordinates>`: the target the jar comes from, and its Maven coordinates
/// (`group:artifact[:packaging[:classifier]]:version`).
library;

import 'dart:io';
import 'dart:typed_data';

/// One jar the app links.
class Jar {
  Jar(this.path, this.origin);

  final String path;

  /// What the message calls the jar: its Maven coordinates, or its target.
  final String origin;
}

/// Classes that two or more jars define differently.
class Conflict {
  Conflict(this.jars, this.classes);

  /// The jars, in the order the deploy jar takes them.
  final List<Jar> jars;

  /// The classes they define differently, sorted.
  final List<String> classes;
}

/// One Maven library the app links, as a rules_jvm_external repository
/// imported it.
class MavenLibrary {
  MavenLibrary(this.target, this.coordinates);

  /// The label of the target that imports it, canonical
  /// (`@@<repository>//:<name>`).
  final String target;

  /// `group:artifact[:packaging[:classifier]]:version`.
  final String coordinates;

  /// The library: its coordinates without the version.
  String get library => coordinates.substring(0, coordinates.lastIndexOf(':'));

  /// The repository of [target].
  String get repository {
    final end = target.indexOf('//');
    return end < 0 ? '' : target.substring(0, end).replaceAll('@', '');
  }
}

/// The libraries that reach the app from more than one repository: each
/// library's imports, one per repository, in the order given, by library.
Map<String, List<MavenLibrary>> duplicateLibraries(
  List<MavenLibrary> libraries,
) {
  final byLibrary = <String, Map<String, MavenLibrary>>{};
  for (final library in libraries) {
    (byLibrary[library.library] ??= {}).putIfAbsent(
      library.repository,
      () => library,
    );
  }
  return {
    for (final key in byLibrary.keys.toList()..sort())
      if (byLibrary[key]!.length > 1) key: byLibrary[key]!.values.toList(),
  };
}

/// The message the build fails with for [found], or null when it is empty.
String? duplicateMessage(
  Map<String, List<MavenLibrary>> found, {
  required String app,
}) {
  if (found.isEmpty) return null;
  final out = StringBuffer()
    ..writeln(
      '$app links Maven libraries from more than one repository. Each '
      'repository resolves its versions on its own, so the app carries two '
      'copies of each library, at versions that part when either is '
      're-pinned.',
    );
  for (final MapEntry(key: library, value: imports) in found.entries) {
    out
      ..writeln()
      ..writeln('    $library');
    for (final import in imports) {
      out.writeln('        ${import.coordinates} from ${import.target}');
    }
  }
  out
    ..writeln()
    ..writeln(
      'An app\'s Android libraries come from @rules_flutter_maven, one '
      'resolution for the app, as Gradle makes one. Depend on the '
      'library\'s @rules_flutter_maven target in place of the other, adding '
      'the artifact to the root module\'s `maven.install(name = '
      '"rules_flutter_maven", artifacts = [...])` if it lacks it. Where the '
      'other target belongs to a module you do not edit, have the root '
      'module send that repository\'s copy to ours:',
    )
    ..writeln()
    ..write(
      '    maven.override(name = "<its repository>", coordinates = '
      '"<group:artifact>", target = "@rules_flutter_maven//:<target>")',
    );
  return out.toString();
}

/// Whether [name], an entry of a jar, is a class the check compares.
bool comparedClass(String name) {
  if (!name.endsWith('.class') || name.startsWith('META-INF/')) return false;
  final base = name.substring(name.lastIndexOf('/') + 1);
  if (base == 'module-info.class') return false;
  return base != 'R.class' && !base.startsWith(r'R$');
}

/// The classes the [jars] define differently, grouped by the jars involved.
///
/// [entries] gives each jar's class entries, name to CRC-32. A class that
/// several jars define with the same bytes is no conflict: whichever the
/// deploy jar keeps, the app runs the same code.
List<Conflict> conflicts(List<Jar> jars, Map<Jar, Map<String, int>> entries) {
  final definers = <String, List<Jar>>{};
  for (final jar in jars) {
    for (final name in entries[jar]!.keys) {
      if (comparedClass(name)) (definers[name] ??= []).add(jar);
    }
  }
  final byJars = <String, (List<Jar>, List<String>)>{};
  for (final MapEntry(key: name, value: definedBy) in definers.entries) {
    if (definedBy.length < 2) continue;
    final crcs = {for (final jar in definedBy) entries[jar]![name]};
    if (crcs.length < 2) continue;
    final key = definedBy.map((jar) => jar.path).join('\n');
    (byJars[key] ??= (definedBy, <String>[])).$2.add(name);
  }
  return [
    for (final (jars, classes) in byJars.values)
      Conflict(jars, classes..sort()),
  ]..sort((a, b) => a.jars.first.origin.compareTo(b.jars.first.origin));
}

/// The message the build fails with for [found], or null when it is empty.
String? conflictMessage(
  List<Conflict> found, {
  required String app,
  required String report,
}) {
  if (found.isEmpty) return null;
  final out = StringBuffer()
    ..writeln(
      '$app links jars that define the same classes differently. Its deploy '
      'jar keeps the first copy of each class, so the app would run a mix of '
      'two versions of one library.',
    );
  for (final conflict in found) {
    out.writeln();
    // A library built in two configurations is two jars of one origin.
    for (final origin in {for (final jar in conflict.jars) jar.origin}) {
      out.writeln('    $origin');
    }
    final count = conflict.classes.length;
    out.writeln(
      '        $count ${count == 1 ? 'class' : 'classes'}, such as '
      '${conflict.classes.take(3).join(', ')}',
    );
  }
  out
    ..writeln()
    ..writeln(
      'These are usually two versions of one library, or an old artifact (an '
      'androidx -ktx one, say) whose classes a newer version of its companion '
      'took over. Gradle resolves one version of each, and aligns such '
      'companions through the version constraints of their Gradle module '
      'metadata; rules_jvm_external reads only POMs. Raise the older '
      "artifact to the version Gradle would pick: `bazel run $report` prints "
      'the Maven artifacts this app needs, those versions included. Add them '
      'to the root module\'s `maven.install(name = "rules_flutter_maven", '
      'artifacts = [...])` and regenerate its lock file:',
    )
    ..writeln()
    ..writeln('    REPIN=1 bazel run @rules_flutter_maven//:pin')
    ..writeln()
    ..writeln(
      'Where either copy works, or the app shadows a library\'s class on '
      'purpose, build with this, under which the deploy jar keeps the first '
      'copy:',
    )
    ..writeln()
    ..write('    --@rules_flutter//flutter:allow_duplicate_classes');
  return out.toString();
}

const _endOfCentralDirectory = 0x06054b50;
const _centralHeader = 0x02014b50;

/// The entries of the zip archive [bytes], name to CRC-32.
///
/// Throws [FormatException] for what is not a zip archive, or one that needs
/// Zip64.
Map<String, int> zipCrcs(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // The end record is 22 bytes plus a comment of at most 65535.
  var end = -1;
  for (
    var at = bytes.length - 22;
    at >= 0 && at >= bytes.length - 65557;
    at--
  ) {
    if (data.getUint32(at, Endian.little) == _endOfCentralDirectory) {
      end = at;
      break;
    }
  }
  if (end < 0) {
    throw const FormatException('no zip end of central directory record');
  }
  final count = data.getUint16(end + 10, Endian.little);
  final directory = data.getUint32(end + 16, Endian.little);
  if (count == 0xFFFF || directory == 0xFFFFFFFF) {
    throw const FormatException('Zip64 archives are not supported');
  }
  final crcs = <String, int>{};
  var at = directory;
  for (var i = 0; i < count; i++) {
    if (at + 46 > bytes.length ||
        data.getUint32(at, Endian.little) != _centralHeader) {
      throw FormatException('no central directory header at $at');
    }
    final crc = data.getUint32(at + 16, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    crcs[String.fromCharCodes(bytes, at + 46, at + 46 + nameLength)] = crc;
    at += 46 + nameLength + extraLength + commentLength;
  }
  return crcs;
}

/// Checks the jars [args] names and returns the exit code.
int run(List<String> args) {
  if (args.length == 1 && args.single.startsWith('@')) {
    args = File(args.single.substring(1)).readAsLinesSync();
  }
  String? app;
  String? report;
  String? stamp;
  final jars = <Jar>[];
  final libraries = <MavenLibrary>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--app':
        app = args[++i];
      case '--report':
        report = args[++i];
      case '--stamp':
        stamp = args[++i];
      case '--jar':
        jars.add(Jar(args[i + 1], args[i + 2]));
        i += 2;
      case '--maven':
        libraries.add(MavenLibrary(args[i + 1], args[i + 2]));
        i += 2;
      default:
        stderr.writeln('check_android_classes: unknown argument ${args[i]}');
        return 2;
    }
  }
  if (app == null || report == null || stamp == null) {
    stderr.writeln(
      'check_android_classes: --app, --report and --stamp are required',
    );
    return 2;
  }
  final entries = <Jar, Map<String, int>>{};
  for (final jar in jars) {
    try {
      entries[jar] = zipCrcs(File(jar.path).readAsBytesSync());
    } on FormatException catch (e) {
      stderr.writeln('${jar.path} (${jar.origin}) is not a jar: ${e.message}');
      return 1;
    }
  }
  final messages = [
    duplicateMessage(duplicateLibraries(libraries), app: app),
    conflictMessage(conflicts(jars, entries), app: app, report: report),
  ].nonNulls;
  if (messages.isNotEmpty) {
    stderr.writeln(messages.join('\n\n'));
    return 1;
  }
  File(stamp).writeAsStringSync('');
  return 0;
}

void main(List<String> args) {
  exitCode = run(args);
}
