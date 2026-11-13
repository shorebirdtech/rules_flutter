/// Generates Flutter asset bundle files (AssetManifest.bin, FontManifest.json).
///
/// This tool implements the StandardMessageCodec binary encoding used by
/// Flutter's AssetManifest.bin format. It has no package dependencies and
/// runs with the bare Dart SDK.
///
/// Usage:
///   dart generate_asset_manifest.dart --config <path> --output-dir <path>
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
///   "copies": {"dest/path": "source/path", ...},
///   "notices": "License text..."
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

/// Run font-subset, piping code points via stdin. Returns true on success.
/// The `IconData` constants the app uses, as const_finder prints them
/// (`constantInstances`, `nonConstantLocations`), or null when they can't be
/// found, which bundles the fonts whole.
///
/// From Flutter 3.50 on there is no const_finder: `recorded_uses` is the file
/// the AOT kernel compile wrote with `--recorded-uses`, and `IconData`
/// (annotated `@RecordUse()`) has its instances there.
Map<String, dynamic>? _iconUses(Map<String, dynamic> iconTreeShaking) {
  final recordedUses = iconTreeShaking['recorded_uses'] as String?;
  if (recordedUses != null) {
    return iconUsesFromRecordings(
      json.decode(File(recordedUses).readAsStringSync())
          as Map<String, dynamic>,
    );
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
    stderr.writeln('const_finder failed (exit ${constFinderResult.exitCode}):');
    stderr.writeln(constFinderResult.stderr);
    // Fall through without tree shaking rather than failing the build.
    return null;
  }
  return json.decode(constFinderResult.stdout as String)
      as Map<String, dynamic>;
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
          // A null index is an argument the compiler couldn't evaluate.
          if (positional.contains(null) || named.values.contains(null)) {
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

Future<void> main(List<String> args) async {
  String? configPath;
  String? outputDir;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (args[i] == '--output-dir' && i + 1 < args.length) {
      outputDir = args[++i];
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

  if (iconTreeShaking != null) {
    // Step 1: find the icon code points the app uses, in const_finder's
    // output shape. From Flutter 3.50 on, `icon_uses` is that output already,
    // written by //flutter/private/icon_uses from the uses the AOT compile
    // recorded; before 3.50, const_finder scans the kernel for them.
    final output = _iconUses(iconTreeShaking);
    if (output != null) {
      // Check for non-const IconData usage.
      final nonConst = output['nonConstantLocations'] as List<dynamic>? ?? [];
      if (nonConst.isNotEmpty) {
        stderr.writeln(
          'Warning: ${nonConst.length} non-const IconData instance(s) found. '
          'Icon tree shaking disabled.',
        );
      } else {
        // Build fontFamily → Set<codePoint> map.
        usedCodePoints = <String, Set<int>>{};
        for (final instance
            in output['constantInstances'] as List<dynamic>? ?? []) {
          final m = instance as Map<String, dynamic>;
          final family = m['fontFamily'] as String?;
          final pkg = m['fontPackage'] as String?;
          final codePoint = m['codePoint'] as int?;
          if (family != null && codePoint != null) {
            final key = pkg == null ? family : 'packages/$pkg/$family';
            usedCodePoints.putIfAbsent(key, () => <int>{}).add(codePoint);
          }
        }

        // Build fontFamily → asset key map from FontManifest.
        fontFamilyToAsset = <String, String>{};
        for (final entry in fonts) {
          final m = entry as Map<String, dynamic>;
          final family = m['family'] as String?;
          final fontList = m['fonts'] as List<dynamic>? ?? [];
          if (family != null && fontList.isNotEmpty) {
            final first = fontList.first as Map<String, dynamic>;
            final asset = first['asset'] as String?;
            if (asset != null) {
              fontFamilyToAsset[family] = asset;
            }
          }
        }
      }
    }
  }

  // -- Copy asset files (with optional font subsetting) ----------------------
  final copies = config['copies'] as Map<String, dynamic>? ?? {};
  for (final entry in copies.entries) {
    final dest = '$outputDir/${entry.key}';
    Directory(File(dest).parent.path).createSync(recursive: true);

    // Check if this asset should be subsetted.
    if (usedCodePoints != null &&
        fontFamilyToAsset != null &&
        iconTreeShaking != null) {
      final fontSubsetBin = iconTreeShaking['font_subset'] as String;
      String? matchedFamily;
      for (final famEntry in fontFamilyToAsset.entries) {
        if (famEntry.value == entry.key || entry.key.endsWith(famEntry.value)) {
          matchedFamily = famEntry.key;
          break;
        }
      }

      final codePoints = matchedFamily != null
          ? usedCodePoints[matchedFamily]
          : null;
      if (codePoints != null && codePoints.isNotEmpty) {
        // Run font-subset: code points are piped via stdin.
        final codePointStr = codePoints.map((cp) => cp.toString()).join(' ');
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
        // Fall through to normal copy on failure.
      }
    }

    File(entry.value as String).copySync(dest);
  }

  // -- NOTICES.Z -------------------------------------------------------------
  // Collect license text from inline string and/or license file paths.
  final noticesBuf = StringBuffer();
  final notices = config['notices'] as String? ?? '';
  if (notices.isNotEmpty) {
    noticesBuf.write(notices);
  }
  final licenseFiles = config['license_files'] as List<dynamic>? ?? [];
  for (final path in licenseFiles) {
    final file = File(path as String);
    if (file.existsSync()) {
      if (noticesBuf.isNotEmpty) noticesBuf.write('\n\n---\n\n');
      noticesBuf.write(file.readAsStringSync());
    }
  }
  File('$outputDir/NOTICES.Z').writeAsBytesSync(
    gzip.encode(utf8.encode(noticesBuf.toString())),
  );
}
