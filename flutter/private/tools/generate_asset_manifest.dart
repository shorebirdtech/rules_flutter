/// Generates Flutter asset bundle files (AssetManifest.bin, FontManifest.json).
///
/// This tool implements the StandardMessageCodec binary encoding used by
/// Flutter's AssetManifest.bin format. It has no package dependencies and
/// runs with the bare Dart SDK.
///
/// Usage:
///   dart generate_asset_manifest.dart --config <path> --output-dir <path>
///       [--program-assets=<path>]
///
/// `--program-assets` names what a program ships, in rules_dart's
/// program-assets line format (its README, "The program-assets file"). Each
/// data asset the program ships is bundled at `packages/<package>/<name>` and
/// listed in the asset manifest under that key, as flutter_tools bundles a
/// hook's data asset.
///
/// The config file is JSON with this schema:
/// {
///   "assets": {
///     "assets/image.png": [
///       {"asset": "assets/image.png"},
///       {"asset": "assets/2.0x/image.png", "dpr": 2.0}
///     ]
///   },
///   "fonts": [...],
///   "copies": {"key": "source/path", ...}   // stored at the key, URI-encoded
/// }
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// -- StandardMessageCodec binary encoding ------------------------------------
// This reimplements Flutter's StandardMessageCodec.encodeMessage() so we can
// produce AssetManifest.bin without depending on package:flutter.

const int _tagNull = 0;
const int _tagTrue = 1;
const int _tagFalse = 2;
const int _tagInt32 = 3;
const int _tagInt64 = 4;
const int _tagFloat64 = 6;
const int _tagString = 7;
const int _tagList = 12;
const int _tagMap = 13;

class _WriteBuffer {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _position = 0;

  void putUint8(int value) {
    _builder.addByte(value);
    _position++;
  }

  void putBytes(List<int> bytes) {
    _builder.add(bytes);
    _position += bytes.length;
  }

  void _putByteData(ByteData data) {
    _builder.add(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    _position += data.lengthInBytes;
  }

  void putInt32(int value) {
    final d = ByteData(4)..setInt32(0, value, Endian.host);
    _putByteData(d);
  }

  void putInt64(int value) {
    final d = ByteData(8)..setInt64(0, value, Endian.host);
    _putByteData(d);
  }

  void putFloat64(double value) {
    // Align to 8-byte boundary.
    final pad = (8 - (_position % 8)) % 8;
    for (var i = 0; i < pad; i++) {
      _builder.addByte(0);
    }
    _position += pad;
    final d = ByteData(8)..setFloat64(0, value, Endian.host);
    _putByteData(d);
  }

  Uint8List done() => _builder.toBytes();
}

void _writeSize(_WriteBuffer buf, int size) {
  if (size < 254) {
    buf.putUint8(size);
  } else if (size < 0x10000) {
    buf.putUint8(254);
    final d = ByteData(2)..setUint16(0, size, Endian.host);
    buf._putByteData(d);
  } else {
    buf.putUint8(255);
    final d = ByteData(4)..setUint32(0, size, Endian.host);
    buf._putByteData(d);
  }
}

void _writeValue(_WriteBuffer buf, Object? value) {
  if (value == null) {
    buf.putUint8(_tagNull);
  } else if (value is bool) {
    buf.putUint8(value ? _tagTrue : _tagFalse);
  } else if (value is int) {
    if (value >= -0x80000000 && value <= 0x7fffffff) {
      buf.putUint8(_tagInt32);
      buf.putInt32(value);
    } else {
      buf.putUint8(_tagInt64);
      buf.putInt64(value);
    }
  } else if (value is double) {
    buf.putUint8(_tagFloat64);
    buf.putFloat64(value);
  } else if (value is String) {
    buf.putUint8(_tagString);
    final encoded = utf8.encode(value);
    _writeSize(buf, encoded.length);
    buf.putBytes(encoded);
  } else if (value is List) {
    buf.putUint8(_tagList);
    _writeSize(buf, value.length);
    for (final item in value) {
      _writeValue(buf, item);
    }
  } else if (value is Map) {
    buf.putUint8(_tagMap);
    _writeSize(buf, value.length);
    for (final entry in value.entries) {
      _writeValue(buf, entry.key);
      _writeValue(buf, entry.value);
    }
  } else {
    throw ArgumentError('Unsupported type: ${value.runtimeType}');
  }
}

Uint8List encodeStandardMessage(Object? message) {
  if (message == null) return Uint8List(0);
  final buf = _WriteBuffer();
  _writeValue(buf, message);
  return buf.done();
}

// -- Icon tree shaking helpers -----------------------------------------------

/// Ends the build with [message]. Icon tree shaking either does what it was
/// asked to or fails, as `flutter build` does: a bundle that quietly skipped
/// it would ship icon fonts whole that the app was said to ship subset, and a
/// subset made from a wrong answer would drop glyphs the app draws.
Never _failTreeShaking(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'To build without icon tree shaking, set `tree_shake_icons = False`.',
  );
  exit(1);
}

/// The `IconData` constants the app uses, as const_finder prints them
/// (`constantInstances`, `nonConstantLocations`).
///
/// From Flutter 3.50 on there is no const_finder: `recorded_uses` is the file
/// the AOT kernel compile wrote with `--recorded-uses`, and `IconData`
/// (annotated `@RecordUse()`) has its instances there.
Map<String, dynamic> _iconUses(Map<String, dynamic> iconTreeShaking) {
  final recordedUses = iconTreeShaking['recorded_uses'] as String?;
  if (recordedUses != null) {
    final Object? decoded;
    try {
      decoded = json.decode(File(recordedUses).readAsStringSync());
    } on FormatException catch (e) {
      _failTreeShaking('Failed to parse the recorded uses file: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      _failTreeShaking(
        'Invalid recorded uses file: expected a top level JSON object, got '
        '$decoded.',
      );
    }
    return iconUsesFromRecordings(decoded);
  }
  final dart = iconTreeShaking['dart'] as String;
  final constFinder = iconTreeShaking['const_finder'] as String;
  final kernelDill = iconTreeShaking['kernel_dill'] as String;
  final constFinderResult = Process.runSync(dart, [
    constFinder,
    '--kernel-file',
    kernelDill,
    '--class-library-uri',
    'package:flutter/src/widgets/icon_data.dart',
    '--class-name',
    'IconData',
    '--annotation-class-name',
    '_StaticIconProvider',
    '--annotation-class-library-uri',
    'package:flutter/src/widgets/icon_data.dart',
  ]);
  if (constFinderResult.exitCode != 0) {
    _failTreeShaking(
      'const_finder failed (exit ${constFinderResult.exitCode}):\n'
      '${constFinderResult.stderr}',
    );
  }
  final decoded = json.decode(constFinderResult.stdout as String);
  if (decoded is! Map<String, dynamic>) {
    _failTreeShaking(
      'Invalid const_finder output: expected a JSON object, got $decoded.',
    );
  }
  return decoded;
}

/// Reads the `IconData` instances out of a `--recorded-uses` file (the
/// `package:record_use` format) into const_finder's output shape: each
/// constant instance's `codePoint`, `fontFamily` and `fontPackage`, and one
/// entry in `nonConstantLocations` for each instance whose fields the
/// compiler couldn't evaluate (a creation with a non-constant argument, or a
/// constructor tear-off). flutter_tools 3.50 reads the same file the same
/// way (`IconTreeShaker._parseRecordings`).
Map<String, dynamic> iconUsesFromRecordings(Map<String, dynamic> recordings) {
  final constants = recordings['constants'] as List<dynamic>? ?? const [];
  final definitions = recordings['definitions'] as List<dynamic>? ?? const [];
  final iconData = <int>{
    for (final (i, d) in definitions.indexed)
      if ((d as Map<String, dynamic>)['uri'] ==
              'package:flutter/src/widgets/icon_data.dart' &&
          ((d['path'] as List<dynamic>?)?.firstOrNull
                  as Map<String, dynamic>?)?['name'] ==
              'IconData')
        i,
  };

  Object? value(int? index) {
    if (index == null) return null;
    final c = constants[index] as Map<String, dynamic>;
    return c['type'] == 'int' || c['type'] == 'string' ? c['value'] : null;
  }

  final constant = <Map<String, Object?>>[];
  final nonConstant = <Map<String, Object?>>[];
  final uses = recordings['uses'] as Map<String, dynamic>? ?? const {};
  for (final entry in uses['instances'] as List<dynamic>? ?? const []) {
    final m = entry as Map<String, dynamic>;
    if (!iconData.contains(m['definition_index'])) continue;
    for (final use in m['uses'] as List<dynamic>? ?? const []) {
      final u = use as Map<String, dynamic>;
      switch (u['type']) {
        case 'constant':
          final instance =
              constants[u['constant_index'] as int] as Map<String, dynamic>;
          final fields = instance['value'] as Map<String, dynamic>? ?? const {};
          constant.add({
            'codePoint': value(fields['codePoint'] as int?),
            'fontFamily': value(fields['fontFamily'] as int?),
            'fontPackage': value(fields['fontPackage'] as int?),
          });
        case 'creation':
          final positional = u['positional'] as List<dynamic>? ?? const [];
          final named = u['named'] as Map<String, dynamic>? ?? const {};
          // An argument the compiler couldn't evaluate is an index to a
          // `{"type": "non_constant"}` entry (record_use's NonConstant); a
          // missing index is treated the same.
          bool nonConstantArg(Object? index) =>
              index == null ||
              (constants[index as int] as Map<String, dynamic>)['type'] ==
                  'non_constant';
          if (positional.any(nonConstantArg) ||
              named.values.any(nonConstantArg)) {
            nonConstant.add(u);
          } else {
            constant.add({
              'codePoint': positional.isEmpty
                  ? null
                  : value(positional.first as int),
              'fontFamily': value(named['fontFamily'] as int?),
              'fontPackage': value(named['fontPackage'] as int?),
            });
          }
        default:
          nonConstant.add(u);
      }
    }
  }
  return {'constantInstances': constant, 'nonConstantLocations': nonConstant};
}

/// Run font-subset, piping code points via stdin. Returns true on success.
Future<bool> _runFontSubset(
  String fontSubsetBin,
  String outputPath,
  String inputPath,
  String codePoints,
) async {
  // font-subset reads code points from stdin (space-separated, newline-terminated).
  final process = await Process.start(fontSubsetBin, [outputPath, inputPath]);
  try {
    process.stdin.writeln(codePoints);
    await process.stdin.flush();
    await process.stdin.close();
  } on Exception {
    // Handled by checking exit code below.
  }

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    stderr.writeln('font-subset failed for $inputPath (exit $exitCode)');
    return false;
  }
  return true;
}

// -- Main --------------------------------------------------------------------

/// The name and version of the program-assets line format this reads.
const programAssetsFormat = 'rules_dart_program_assets/1';

/// The data assets a program ships, read from a file in rules_dart's
/// program-assets line format: each link hook's data directory listed.
///
/// The bundle holds data assets only, so this reads a file that holds them
/// and passes over any code records it also holds. rules_dart's reference
/// reader (`@rules_dart//dart/program_assets`) is a package, and this tool
/// runs as a script with none; rules_dart's conformance fixture checks the
/// two agree.
final class ProgramAssets {
  ProgramAssets(this.dataAssets);

  /// Each data asset's file, by id (`package:<package>/<name>`).
  final Map<String, String> dataAssets;

  /// Reads [path]. Its `exec` paths are relative to [base], the working
  /// directory when null.
  static ProgramAssets read(String path, {String? base}) {
    String resolve(String p) =>
        base == null || p.startsWith('/') ? p : '$base/$p';
    final lines = File(path).readAsLinesSync();
    var at = 0;
    String next(String what) {
      if (at >= lines.length) {
        throw FormatException('$path: ends before $what');
      }
      return lines[at++];
    }

    void tag(String expected) {
      final line = next('`$expected`');
      if (line != expected) {
        throw FormatException('$path: expected `$expected`, got `$line`');
      }
    }

    tag('--format');
    final format = next('the format');
    if (format != programAssetsFormat) {
      throw FormatException(
        '$path: format `$format`, not `$programAssetsFormat`',
      );
    }
    tag('--paths');
    final paths = next('the paths');
    if (paths != 'exec') {
      throw FormatException(
        '$path: `--paths $paths`; only `exec` is read here',
      );
    }
    tag('--holds');
    final holds = next('what it holds');
    final parts = holds.split(' ');
    if (holds.isEmpty ||
        parts.toSet().length != parts.length ||
        parts.any((p) => !const {'data', 'code', 'code-names'}.contains(p)) ||
        (parts.contains('code') && parts.contains('code-names'))) {
      throw FormatException('$path: `--holds` `$holds` is not a valid view');
    }
    if (!parts.contains('data')) {
      throw FormatException(
        '$path holds `$holds`, not the data assets the bundle needs; pass '
        '`data = True` to `program_assets_action_args()`',
      );
    }
    final holdsCode = parts.length > 1;
    void holding(String record, bool held) {
      if (!held) {
        throw FormatException(
          '$path: a `$record` record in a file that holds `$holds`',
        );
      }
    }

    final data = <String, String>{};
    void ship(String id, String file) {
      if (data.containsKey(id)) {
        throw FormatException('$path names data asset `$id` twice');
      }
      data[id] = file;
    }

    // A code asset's record: its id, link mode, library and uri.
    void passCodeAsset() {
      for (final what in ['an id', 'a link mode', 'a library', 'a uri']) {
        next(what);
      }
    }

    while (at < lines.length) {
      switch (next('a record')) {
        case '--data-asset':
          final id = next('an id');
          ship(id, resolve(next('a file')));
        case '--link-data':
          final package = next('a package');
          final directory = resolve(next('a directory'));
          final root = Directory(directory);
          final files = root.existsSync()
              ? root
                    .listSync(recursive: true, followLinks: true)
                    .whereType<File>()
              : const <File>[];
          for (final file in files) {
            final name = file.path
                .substring(directory.length + 1)
                .replaceAll(r'\', '/');
            ship('package:$package/$name', file.path);
          }
        case '--code-asset':
          holding('--code-asset', holdsCode);
          passCodeAsset();
        case '--link-code':
          holding('--link-code', holdsCode);
          next('a package');
          next('a selection');
          while (at < lines.length && lines[at] == '--candidate') {
            at++;
            passCodeAsset();
          }
        case final other:
          throw FormatException('$path: unknown record `$other`');
      }
    }
    return ProgramAssets(data);
  }
}

/// Adds each of a program's data assets to [config], at
/// `packages/<package>/<name>`, the key `rootBundle` loads it by.
///
/// A key another file already claims fails: the bundle can hold one of them.
void addProgramDataAssets(Map<String, dynamic> config, ProgramAssets program) {
  final assets = (config['assets'] ??= <String, dynamic>{}) as Map;
  final copies = (config['copies'] ??= <String, dynamic>{}) as Map;
  for (final MapEntry(key: id, value: source) in program.dataAssets.entries) {
    final key = 'packages/${id.substring('package:'.length)}';
    final claimed = copies[key];
    if (claimed != null && claimed != source) {
      stderr.writeln(
        'Two files claim the asset key $key: $claimed and the data asset '
        '$source. A bundle can hold one of them.',
      );
      exit(1);
    }
    copies[key] = source;
    assets[key] = [
      {'asset': key},
    ];
  }
}

Future<void> main(List<String> args) async {
  String? configPath;
  String? outputDir;
  String? programAssets;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (args[i] == '--output-dir' && i + 1 < args.length) {
      outputDir = args[++i];
    } else if (args[i].startsWith('--program-assets=')) {
      programAssets = args[i].substring('--program-assets='.length);
    }
  }

  if (configPath == null || outputDir == null) {
    stderr.writeln(
      'Usage: dart generate_asset_manifest.dart --config <path> --output-dir <path>',
    );
    exit(1);
  }

  final config =
      json.decode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
  if (programAssets != null) {
    addProgramDataAssets(config, ProgramAssets.read(programAssets));
  }

  // Create output directory.
  Directory(outputDir).createSync(recursive: true);

  // -- AssetManifest.bin -----------------------------------------------------
  final assets = config['assets'] as Map<String, dynamic>? ?? {};
  final manifestMap = <String, Object>{};
  for (final entry in assets.entries) {
    final variants = (entry.value as List<dynamic>).map((v) {
      final variant = v as Map<String, dynamic>;
      final result = <String, Object>{'asset': variant['asset'] as String};
      if (variant.containsKey('dpr')) {
        result['dpr'] = (variant['dpr'] as num).toDouble();
      }
      return result;
    }).toList();
    manifestMap[entry.key] = variants;
  }
  final binBytes = encodeStandardMessage(manifestMap);
  File('$outputDir/AssetManifest.bin').writeAsBytesSync(binBytes);

  // AssetManifest.bin.json — base64-encoded JSON wrapper for web.
  File('$outputDir/AssetManifest.bin.json').writeAsStringSync(
    json.encode(base64.encode(binBytes)),
  );

  // -- FontManifest.json -----------------------------------------------------
  final fonts = config['fonts'] as List<dynamic>? ?? [];
  File('$outputDir/FontManifest.json').writeAsStringSync(json.encode(fonts));

  // -- Icon tree shaking (optional) ------------------------------------------
  final iconTreeShaking = config['icon_tree_shaking'] as Map<String, dynamic>?;
  Map<String, Set<int>>? usedCodePoints;
  Map<String, String>? fontFamilyToAsset;

  // Code points each subset font keeps if the font has them, used or not.
  var optionalCodePoints = <int>[];

  if (iconTreeShaking != null) {
    final optional =
        iconTreeShaking['optional_code_points'] as List<dynamic>? ?? [];
    optionalCodePoints = [for (final cp in optional) cp as int];

    // Step 1: find the icon code points the app uses, in const_finder's
    // output shape. From Flutter 3.50 on they come from the uses the AOT
    // compile recorded (`recorded_uses`); before 3.50, const_finder scans the
    // kernel for them.
    final output = _iconUses(iconTreeShaking);

    // Which icons a program uses is unknown where an IconData is not
    // constant, so no subset of a font is safe.
    final nonConst = output['nonConstantLocations'] as List<dynamic>? ?? [];
    if (nonConst.isNotEmpty) {
      _failTreeShaking(
        'This application cannot tree shake icon fonts. It has non-constant '
        'instances of IconData at the following locations:\n'
        '${[
          for (final location in nonConst)
            if ((location as Map)['file'] != null) '- ${location['file']}:${location['line']}:${location['column']}' else '- an IconData created with a non-constant argument, or torn off',
        ].join('\n')}\n'
        'Avoid non-constant invocations of IconData.',
      );
    }

    // Build fontFamily → Set<codePoint> map.
    final used = <String, Set<int>>{};
    for (final instance
        in output['constantInstances'] as List<dynamic>? ?? []) {
      final m = instance as Map<String, dynamic>;
      final family = m['fontFamily'] as String?;
      final pkg = m['fontPackage'] as String?;
      // A kernel built for the web (JavaScript) holds an `int` constant as
      // a `double`, so const_finder reports its code point as a number.
      final codePoint = (m['codePoint'] as num?)?.round();
      if (family != null && codePoint != null) {
        final key = pkg == null ? family : 'packages/$pkg/$family';
        used.putIfAbsent(key, () => <int>{}).add(codePoint);
      }
    }
    usedCodePoints = used;

    // Build fontFamily → font path map from FontManifest. A family the app
    // draws icons from has one font file: subsetting one of several and
    // shipping the rest whole would leave the bundle holding icons the app
    // was said not to use.
    fontFamilyToAsset = <String, String>{};
    for (final entry in fonts) {
      final m = entry as Map<String, dynamic>;
      final family = m['family'] as String?;
      final fontList = m['fonts'] as List<dynamic>? ?? [];
      if (family == null || !used.containsKey(family)) continue;
      if (fontList.length != 1) {
        _failTreeShaking(
          'This tool cannot process icon fonts with multiple fonts in a '
          'single family ($family has ${fontList.length}).',
        );
      }
      final asset = (fontList.single as Map<String, dynamic>)['asset'];
      if (asset is! String) {
        _failTreeShaking(
          'FontManifest.json invalid: expected the "asset" of $family to be '
          'a string, got $asset.',
        );
      }
      fontFamilyToAsset[family] = asset;
    }
  }

  // -- Copy asset files (with optional font subsetting) ----------------------
  final copies = config['copies'] as Map<String, dynamic>? ?? {};
  for (final entry in copies.entries) {
    // The engine asks for `Uri.encodeFull(key)`, and flutter_tools stores each
    // file at its URI-encoded path (`my%20image.png`), so a name with a space
    // or a non-ASCII character is found; the manifest lists the decoded key.
    final dest = '$outputDir/${Uri(pathSegments: entry.key.split('/')).path}';
    Directory(File(dest).parent.path).createSync(recursive: true);

    // Check if this asset should be subsetted.
    if (usedCodePoints != null &&
        fontFamilyToAsset != null &&
        iconTreeShaking != null) {
      final fontSubsetBin = iconTreeShaking['font_subset'] as String;
      // A font is the one of a family by its exact path in the bundle, never
      // by how the paths end: `packages/p/fonts/Icons.ttf` and `fonts/Icons.ttf`
      // are two fonts, and each takes only its own family's code points.
      String? matchedFamily;
      for (final famEntry in fontFamilyToAsset.entries) {
        if (famEntry.value == entry.key) {
          matchedFamily = famEntry.key;
          break;
        }
      }

      final codePoints = matchedFamily != null
          ? usedCodePoints[matchedFamily]
          : null;
      if (codePoints != null && codePoints.isNotEmpty) {
        // Run font-subset: code points are piped via stdin.
        final codePointStr = [
          ...codePoints.map((cp) => cp.toString()),
          ...optionalCodePoints.map((cp) => 'optional:$cp'),
        ].join(' ');
        final success = await _runFontSubset(
          fontSubsetBin,
          dest,
          entry.value as String,
          codePointStr,
        );
        if (success) {
          final inputSize = File(entry.value as String).lengthSync();
          final outputSize = File(dest).lengthSync();
          final reduction = ((inputSize - outputSize) / inputSize * 100)
              .toStringAsFixed(1);
          stderr.writeln(
            'Font "${entry.key}" tree-shaken: $inputSize -> $outputSize bytes ($reduction% reduction).',
          );
          continue;
        }
        _failTreeShaking('Font subsetting failed for ${entry.key}.');
      }
    }

    File(entry.value as String).copySync(dest);
  }
}
