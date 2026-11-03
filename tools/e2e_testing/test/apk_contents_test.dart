import 'dart:convert';
import 'dart:typed_data';

import 'package:rules_flutter_e2e_testing/apk_contents.dart';
import 'package:test/test.dart';

/// A dex file whose string table holds [descriptors], with a type for each;
/// only the first [defined] types have a class definition. The rest are
/// merely referenced, as `Ljava/lang/Object;` is.
Uint8List dex(List<String> descriptors, {required int defined}) {
  final n = descriptors.length;
  const header = 0x70;
  final stringIds = header;
  final typeIds = stringIds + 4 * n;
  final classDefs = typeIds + 4 * n;
  final stringData = classDefs + 32 * defined;
  final data = <int>[];
  final offsets = <int>[];
  for (final d in descriptors) {
    offsets.add(stringData + data.length);
    data
      ..add(d.length) // uleb128 UTF-16 length; every test string is < 128
      ..addAll(d.codeUnits)
      ..add(0);
  }
  final bytes = Uint8List(stringData + data.length);
  final view = ByteData.sublistView(bytes)
    ..setUint32(0x3c, stringIds, Endian.little)
    ..setUint32(0x44, typeIds, Endian.little)
    ..setUint32(0x60, defined, Endian.little)
    ..setUint32(0x64, classDefs, Endian.little);
  bytes.setRange(0, 4, [0x64, 0x65, 0x78, 0x0a]);
  for (var i = 0; i < n; i++) {
    view
      ..setUint32(stringIds + 4 * i, offsets[i], Endian.little)
      // Type i is described by string i.
      ..setUint32(typeIds + 4 * i, i, Endian.little);
  }
  for (var i = 0; i < defined; i++) {
    view.setUint32(classDefs + 32 * i, i, Endian.little);
  }
  bytes.setRange(stringData, stringData + data.length, data);
  return bytes;
}

/// A compiled manifest holding an element per entry of [elements]: its name,
/// then its attributes, each a local name and a string value.
Uint8List axml(
  List<(String, Map<String, String>)> elements, {
  bool utf8Pool = false,
}) {
  final pool = <String>[];
  int index(String s) {
    final at = pool.indexOf(s);
    if (at >= 0) return at;
    pool.add(s);
    return pool.length - 1;
  }

  final chunks = BytesBuilder();
  for (final (name, attributes) in elements) {
    final body = BytesBuilder()
      ..add(_u32(0xFFFFFFFF)) // namespace
      ..add(_u32(index(name)))
      ..add(_u16(20)) // attributeStart
      ..add(_u16(20)) // attributeSize
      ..add(_u16(attributes.length))
      ..add(_u16(0)) // idIndex
      ..add(_u16(0)) // classIndex
      ..add(_u16(0)); // styleIndex
    attributes.forEach((key, value) {
      body
        ..add(_u32(0xFFFFFFFF)) // namespace
        ..add(_u32(index(key)))
        ..add(_u32(index(value))) // rawValue
        ..add(_u16(8)) // typed value size
        ..addByte(0)
        ..addByte(0x03) // TYPE_STRING
        ..add(_u32(index(value)));
    });
    final b = body.toBytes();
    chunks
      ..add(_u16(0x0102))
      ..add(_u16(16))
      ..add(_u32(16 + b.length))
      ..add(_u32(1)) // line number
      ..add(_u32(0xFFFFFFFF)) // comment
      ..add(b);
  }

  final strings = BytesBuilder();
  final offsets = <int>[];
  for (final s in pool) {
    offsets.add(strings.length);
    if (utf8Pool) {
      final encoded = utf8.encode(s);
      strings
        ..addByte(s.length)
        ..addByte(encoded.length)
        ..add(encoded)
        ..addByte(0);
    } else {
      strings
        ..add(_u16(s.length))
        ..add([for (final u in s.codeUnits) ..._u16(u)])
        ..add(_u16(0));
    }
  }
  final stringBytes = strings.toBytes();
  final stringsStart = 28 + 4 * pool.length;
  final poolChunk = BytesBuilder()
    ..add(_u16(0x0001))
    ..add(_u16(28))
    ..add(_u32(stringsStart + stringBytes.length))
    ..add(_u32(pool.length))
    ..add(_u32(0)) // style count
    ..add(_u32(utf8Pool ? 0x100 : 0))
    ..add(_u32(stringsStart))
    ..add(_u32(0)); // styles start
  for (final o in offsets) {
    poolChunk.add(_u32(o));
  }
  poolChunk.add(stringBytes);

  final pc = poolChunk.toBytes();
  final cs = chunks.toBytes();
  return (BytesBuilder()
        ..add(_u16(0x0003))
        ..add(_u16(8))
        ..add(_u32(8 + pc.length + cs.length))
        ..add(pc)
        ..add(cs))
      .toBytes();
}

List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];

List<int> _u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];

void main() {
  group('dexClassDescriptors', () {
    test('lists defined classes, not merely referenced types', () {
      final bytes = dex([
        'Lcom/example/Main;',
        'Lcom/example/Other;',
        'Ljava/lang/Object;',
      ], defined: 2);
      expect(dexClassDescriptors(bytes), {
        'Lcom/example/Main;',
        'Lcom/example/Other;',
      });
    });

    test('is empty for a dex that defines nothing', () {
      expect(
        dexClassDescriptors(dex(['Ljava/lang/Object;'], defined: 0)),
        isEmpty,
      );
    });

    test('rejects bytes that are not a dex file', () {
      expect(() => dexClassDescriptors(Uint8List(0x80)), throwsFormatException);
      expect(() => dexClassDescriptors(Uint8List(4)), throwsFormatException);
    });
  });

  group('manifestElements', () {
    final manifest = axml([
      ('manifest', {'package': 'com.example.app'}),
      ('uses-permission', {'name': 'android.permission.INTERNET'}),
      ('uses-permission-sdk-23', {'name': 'android.permission.CAMERA'}),
      ('uses-feature', {'name': 'android.hardware.camera'}),
      ('activity', {'name': 'com.example.app.MainActivity'}),
    ]);

    test('reads elements in order with their string attributes', () {
      final elements = manifestElements(manifest);
      expect(elements.map((e) => e.name), [
        'manifest',
        'uses-permission',
        'uses-permission-sdk-23',
        'uses-feature',
        'activity',
      ]);
      expect(elements.first.attributes['package'], 'com.example.app');
      expect(
        elements.last.attributes['name'],
        'com.example.app.MainActivity',
      );
    });

    test('reads a UTF-8 string pool', () {
      final elements = manifestElements(
        axml([
          ('manifest', {'package': 'com.example.app'}),
        ], utf8Pool: true),
      );
      expect(elements.single.attributes['package'], 'com.example.app');
    });

    test('usesPermissions names the permissions and nothing else', () {
      expect(usesPermissions(manifest), {
        'android.permission.INTERNET',
        'android.permission.CAMERA',
      });
    });

    test('a permission without a name is an error', () {
      expect(
        () => usesPermissions(axml([('uses-permission', <String, String>{})])),
        throwsFormatException,
      );
    });

    test('rejects what is not AXML rather than finding nothing', () {
      expect(() => manifestElements(Uint8List(4)), throwsFormatException);
      final truncated = Uint8List.sublistView(manifest, 0, manifest.length - 4);
      expect(() => manifestElements(truncated), throwsFormatException);
    });
  });

  group('containsText', () {
    test('finds UTF-8 and UTF-16LE encodings', () {
      expect(
        containsText('xx android.permission.X yy'.codeUnits, 'permission'),
        isTrue,
      );
      expect(
        containsText([0, 0x70, 0, 0x65, 0, 0x72, 0], 'per'),
        isTrue,
      );
      expect(containsText('permission'.codeUnits, 'absent'), isFalse);
    });
  });
}
