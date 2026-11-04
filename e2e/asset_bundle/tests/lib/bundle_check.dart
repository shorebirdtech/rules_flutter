/// Compares a built `flutter_assets/` tree with what `flutter build` would
/// have put there for the same declared assets.
///
/// The expectation is a list of asset keys, each with its variants, in the
/// shape `AssetManifest.bin` decodes to. Everything else follows from how
/// flutter_tools (`asset.dart`) writes a bundle:
///
///  * the manifest holds the decoded key and decoded variant paths, and
///    nothing else: no file the bundle merely contains (the Material shaders
///    and icon font are in a bundle and not in its manifest);
///  * each variant is a file at its URI-encoded path, the form the engine
///    asks for (`Uri.encodeFull(key)`), so a name with a space is stored with
///    `%20`;
///  * a variant in a `<scale>x/` directory carries that scale as `dpr`, the
///    main file carries none.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Files a bundle holds whatever the app declares: the manifests, the license
/// blob, and the Material shaders flutter_tools adds to every bundle. The
/// shaders are no entry of the manifest, so they are left out of the files
/// compared and the manifest is compared as it is.
const infrastructure = {
  'AssetManifest.bin',
  'AssetManifest.bin.json',
  'FontManifest.json',
  'NOTICES.Z',
  'shaders/ink_sparkle.frag',
  'shaders/stretch_effect.frag',
};

/// One file of an asset: its decoded path, and the scale it is a variant for.
typedef Variant = ({String asset, double? dpr});

/// The path a variant is stored at, as flutter_tools writes it.
String storedPath(String asset) => Uri(pathSegments: asset.split('/')).path;

/// The expectation in [file]: asset key to variants, restricted to the entries
/// declared for [platform] (an entry without `platforms` is for all), with
/// [prefix] in front of every key and path.
Map<String, List<Variant>> readExpectation(
  File file, {
  String prefix = '',
  String? platform,
}) {
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final out = <String, List<Variant>>{};
  for (final entry in (json['assets'] as Map<String, dynamic>).entries) {
    final value = entry.value as Map<String, dynamic>;
    final platforms = (value['platforms'] as List?)?.cast<String>();
    if (platforms != null && !platforms.contains(platform)) continue;
    out['$prefix${entry.key}'] = [
      for (final v in (value['variants'] as List).cast<Map<String, dynamic>>())
        (
          asset: '$prefix${v['asset']}',
          dpr: (v['dpr'] as num?)?.toDouble(),
        ),
    ];
  }
  return out;
}

/// What the bundle at [dir] says it holds: the manifest, and the files that
/// are not infrastructure.
({Map<String, List<Variant>> manifest, Set<String> files}) readBundle(
  Directory dir,
) {
  final bin = File('${dir.path}/AssetManifest.bin').readAsBytesSync();
  final wrapped = jsonDecode(
    File('${dir.path}/AssetManifest.bin.json').readAsStringSync(),
  ) as String;
  if (!_same(base64.decode(wrapped), bin)) {
    throw StateError('AssetManifest.bin.json is not AssetManifest.bin');
  }
  final decoded = _Reader(bin).read() as Map<Object?, Object?>;
  final manifest = <String, List<Variant>>{
    for (final entry in decoded.entries)
      entry.key! as String: [
        for (final v in (entry.value! as List).cast<Map<Object?, Object?>>())
          (asset: v['asset']! as String, dpr: v['dpr'] as double?),
      ],
  };
  final files = <String>{
    for (final f in dir.listSync(recursive: true).whereType<File>())
      f.path.substring(dir.path.length + 1),
  }..removeAll(infrastructure);
  return (manifest: manifest, files: files);
}

/// The ways the bundle at [dir] differs from [expected]; empty when it is
/// what `flutter build` would produce.
///
/// With [allowExtra] the bundle may also hold more than [expected] (extra keys
/// and files, not extra variants of a key it lists): the check that nothing
/// declared goes missing, for a bundle known to hold more than it should.
///
/// [unlisted] are files the bundle must hold without any manifest key, as
/// flutter_tools bundles the Material icon font.
List<String> compare(
  Directory dir,
  Map<String, List<Variant>> expected, {
  bool allowExtra = false,
  List<String> unlisted = const [],
}) {
  final bundle = readBundle(dir);
  final problems = <String>[];

  String show(Variant v) => v.dpr == null ? v.asset : '${v.asset} @${v.dpr}x';
  List<String> sorted(List<Variant> vs) =>
      [for (final v in vs) show(v)]..sort();

  for (final key in expected.keys.toList()..sort()) {
    final got = bundle.manifest[key];
    if (got == null) {
      problems.add('manifest has no key "$key"');
    } else if (sorted(got).join('\n') != sorted(expected[key]!).join('\n')) {
      problems.add(
        'manifest key "$key" lists ${sorted(got)}, '
        'want ${sorted(expected[key]!)}',
      );
    }
  }
  for (final key in bundle.manifest.keys.toList()..sort()) {
    if (!allowExtra && !expected.containsKey(key)) {
      problems.add('manifest has the unexpected key "$key"');
    }
  }

  final wantFiles = {
    for (final variants in expected.values)
      for (final v in variants) storedPath(v.asset),
    for (final f in unlisted) storedPath(f),
  };
  for (final f in wantFiles.toList()..sort()) {
    if (!bundle.files.contains(f)) problems.add('bundle has no file "$f"');
  }
  for (final f in bundle.files.toList()..sort()) {
    if (!allowExtra && !wantFiles.contains(f))
      problems.add('bundle has the unexpected file "$f"');
  }
  return problems;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Reads what Flutter's `StandardMessageCodec` wrote, for the types a manifest
/// uses.
class _Reader {
  _Reader(Uint8List bytes)
    : _data = ByteData.sublistView(bytes),
      _bytes = bytes;

  final ByteData _data;
  final Uint8List _bytes;
  var _at = 0;

  Object? read() {
    final tag = _bytes[_at++];
    switch (tag) {
      case 0:
        return null;
      case 1:
        return true;
      case 2:
        return false;
      case 3:
        final v = _data.getInt32(_at, Endian.host);
        _at += 4;
        return v;
      case 4:
        final v = _data.getInt64(_at, Endian.host);
        _at += 8;
        return v;
      case 6:
        _at += (8 - _at % 8) % 8;
        final v = _data.getFloat64(_at, Endian.host);
        _at += 8;
        return v;
      case 7:
        final n = _size();
        final s = utf8.decode(_bytes.sublist(_at, _at + n));
        _at += n;
        return s;
      case 12:
        return [for (var n = _size(); n > 0; n--) read()];
      case 13:
        final m = <Object?, Object?>{};
        for (var n = _size(); n > 0; n--) {
          final k = read();
          m[k] = read();
        }
        return m;
    }
    throw FormatException('unknown tag $tag at ${_at - 1}');
  }

  int _size() {
    final first = _bytes[_at++];
    if (first < 254) return first;
    if (first == 254) {
      final v = _data.getUint16(_at, Endian.host);
      _at += 2;
      return v;
    }
    final v = _data.getUint32(_at, Endian.host);
    _at += 4;
    return v;
  }
}
