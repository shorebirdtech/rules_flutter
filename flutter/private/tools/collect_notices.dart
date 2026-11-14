/// Merges the licence files of a program's packages into one `NOTICES` asset,
/// as flutter_tools' `LicenseCollector` does, and writes it the way the
/// framework reads it.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart collect_notices.dart --config <path> --output <path>
///
/// The config file is JSON:
/// {
///   "packages": [{"name": "foo", "file": "path/to/LICENSE"}, ...],
///   "engine": {"name": "sky_engine", "file": "path/to/LICENSE"},
///   "additional": [{"name": "foo", "files": ["path/to/THIRD_PARTY"]}, ...],
///   "web": false
/// }
///
/// `packages` and `engine` are the same thing, the licence file of one package
/// each; `engine` is kept apart because every program has exactly one.
/// `additional` are the files a package's `flutter: licenses:` lists, appended
/// as they are, in the order given.
///
/// The output is `NOTICES.Z` (gzip) for a program the engine runs and `NOTICES`
/// (plain UTF-8) for the web, where the framework reads the asset
/// uncompressed.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The line the framework splits a `NOTICES` asset at
/// (`packages/flutter/lib/src/services/binding.dart`), and flutter_tools
/// writes between licences.
final String licenseSeparator = '\n${'-' * 80}\n';

/// One package's licence file, with its contents.
class PackageLicence {
  const PackageLicence(this.package, this.path, this.text);

  final String package;
  final String path;
  final String text;
}

/// The combined licence text of [packages] followed by [additional].
///
/// A package's file holds one licence, or several joined by
/// [licenseSeparator], each led by the names of the packages it covers, a
/// blank line and the text. Components with the same text are one entry,
/// naming every package that has it; entries are sorted, names within an entry
/// too. [additional] come after the entries, one per file, untouched.
///
/// Two licences for one package name fail when their text differs: the same
/// package behind two dependency edges is one package, two different ones
/// under a name is a build that cannot say which to ship.
String mergeNotices(
  Iterable<PackageLicence> packages,
  Iterable<String> additional,
) {
  final byPackage = <String, PackageLicence>{};
  for (final licence in packages) {
    final seen = byPackage[licence.package];
    if (seen == null) {
      byPackage[licence.package] = licence;
    } else if (seen.text != licence.text) {
      throw FormatException(
        'package ${licence.package} has two different licence files: '
        '${seen.path} and ${licence.path}',
      );
    }
  }

  final packageNames = <String, Set<String>>{};
  for (final licence in byPackage.values) {
    final raw = licence.text.split(licenseSeparator);
    for (final component in raw) {
      List<String>? names;
      String? text;
      if (raw.length > 1) {
        final split = component.indexOf('\n\n');
        if (split >= 0) {
          names = component.substring(0, split).split('\n');
          text = component.substring(split + 2);
        }
      }
      if (text == null) {
        names = [licence.package];
        text = component;
      }
      packageNames.putIfAbsent(text, () => <String>{}).addAll(names!);
    }
  }

  final entries = [
    for (final entry in packageNames.entries)
      '${(entry.value.toList()..sort()).join('\n')}\n\n${entry.key}',
  ]..sort();

  return entries.followedBy(additional).join(licenseSeparator);
}

/// [text] as the framework's `NOTICES.Z`: gzip at the best level, with a
/// header that names no host.
///
/// `dart:io`'s `GZipCodec` has no option for the header's fields, and zlib
/// fills two of them from the machine: the OS byte (3 on Linux, 19 on macOS,
/// 10 on Windows, from the platform zlib was built for) and, in some builds,
/// the modification time. The same licences would then be different bytes on
/// each build host. RFC 1952 gives 255 as "unknown" and 0 as "no time
/// available", so those are written over the header. Neither field is covered
/// by the trailer's CRC-32 (which is over the data alone), so the stream stays
/// valid.
List<int> compressNotices(String text) {
  final z = Uint8List.fromList(
    GZipCodec(level: ZLibOption.maxLevel).encode(utf8.encode(text)),
  );
  // A 10-byte header with no optional fields (FLG = 0) is what zlib writes
  // when asked for a plain gzip stream; anything else is not ours to rewrite.
  if (z.length < 18 || z[0] != 0x1f || z[1] != 0x8b || z[3] != 0) {
    throw StateError('gzip.encode did not produce a plain gzip header');
  }
  z.setRange(4, 8, const [0, 0, 0, 0]); // MTIME
  z[9] = 255; // OS: unknown
  return z;
}

String _read(String path, String owner) {
  try {
    return utf8.decode(File(path).readAsBytesSync());
  } on FormatException catch (e) {
    throw FormatException('$owner: $path is not valid UTF-8: ${e.message}');
  }
}

/// Reads [config] and writes the merged notices to [output].
void collect(Map<String, Object?> config, String output) {
  final licences = <PackageLicence>[];
  void add(Object? entry) {
    final map = entry as Map<String, Object?>;
    final name = map['name'] as String;
    final file = map['file'] as String;
    licences.add(PackageLicence(name, file, _read(file, 'package $name')));
  }

  for (final entry in config['packages'] as List<Object?>? ?? const []) {
    add(entry);
  }
  if (config['engine'] != null) add(config['engine']);

  final additional = <String>[];
  for (final entry in config['additional'] as List<Object?>? ?? const []) {
    final map = entry as Map<String, Object?>;
    final name = map['name'] as String;
    for (final file in map['files'] as List<Object?>) {
      additional.add(
        _read(file as String, 'package $name\'s additional licence'),
      );
    }
  }

  final text = mergeNotices(licences, additional);
  final bytes = config['web'] == true
      ? utf8.encode(text)
      : compressNotices(text);
  File(output)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

void main(List<String> args) {
  String? configPath;
  String? output;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (args[i] == '--output' && i + 1 < args.length) {
      output = args[++i];
    }
  }
  if (configPath == null || output == null) {
    stderr.writeln(
      'Usage: dart collect_notices.dart --config <path> --output <path>',
    );
    exit(64);
  }
  try {
    collect(
      json.decode(File(configPath).readAsStringSync()) as Map<String, Object?>,
      output,
    );
  } on FormatException catch (e) {
    stderr.writeln('collect_notices: ${e.message}');
    exit(1);
  }
}
